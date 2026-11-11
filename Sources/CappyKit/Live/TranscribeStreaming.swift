import Foundation

/// Amazon Transcribe Streaming（WebSocket）。
///
/// - `wss://transcribestreaming.<region>.amazonaws.com:8443/stream-transcription-websocket` に SigV4 の署名付き URL で接続する
/// - 音声は AudioEvent（イベントストリーム形式のバイナリ）で送り、空の AudioEvent で終わりを伝える
/// - 結果は TranscriptEvent（JSON）。IsPartial = false の結果を確定した発言にする
/// - 1 セッション 4 時間までのため、3 時間 50 分を過ぎたら話の切れ目で張り替える
public final class TranscribeStreamingBackend: LiveBackend, @unchecked Sendable {
    public static let softLimitMs: Int64 = (3 * 60 + 50) * 60_000
    public static let hardLimitMs: Int64 = (3 * 60 + 55) * 60_000

    public let region: String
    let settings: TranscribeSettings
    let credentials: AWSCredentialsSource
    let connector: LiveDataConnector
    private let lock = NSLock()
    /// 話者分離を拒否されたら、以降は付けない
    private var speakerLabelsRejected = false

    public init(region: String, settings: TranscribeSettings, credentials: AWSCredentialsSource,
                connector: LiveDataConnector = URLSessionDataConnector()) {
        self.region = region
        self.settings = settings
        self.credentials = credentials
        self.connector = connector
    }

    func speakerLabels(for track: TrackID) -> Bool {
        settings.diarization && track != .mic && !lock.withLock { speakerLabelsRejected }
    }

    func rejectSpeakerLabels() {
        lock.withLock { speakerLabelsRejected = true }
    }

    /// 署名前の URL
    public func url(language: String, speakerLabels: Bool) -> URL {
        var items = [
            URLQueryItem(name: "language-code", value: language),
            URLQueryItem(name: "media-encoding", value: "pcm"),
            URLQueryItem(name: "sample-rate", value: String(Int(LiveAudioSink.sampleRate))),
        ]
        if speakerLabels { items.append(URLQueryItem(name: "show-speaker-label", value: "true")) }
        if let v = settings.vocabularyName, !v.isEmpty { items.append(URLQueryItem(name: "vocabulary-name", value: v)) }
        if let m = settings.languageModelName, !m.isEmpty { items.append(URLQueryItem(name: "language-model-name", value: m)) }
        var comps = URLComponents(string: "wss://transcribestreaming.\(region).amazonaws.com:8443/stream-transcription-websocket")!
        comps.percentEncodedQueryItems = items.map { URLQueryItem(name: $0.name, value: SigV4Signer.uriEncode($0.value ?? "")) }
        return comps.url!
    }

    public func open(startMs: Int64, options: LiveTranscriber.Options,
                     onEvent: @escaping @Sendable (LiveTranscriber.Event) -> Void) async throws -> LiveSession {
        let speakers = speakerLabels(for: options.track)
        let creds = try await credentials.credentials()
        let signed = SigV4Signer(credentials: creds, region: region, service: "transcribe")
            .presign(url(language: options.language, speakerLabels: speakers), expires: 300)
        let socket = try await connector.connect(signed)
        let session = TranscribeStreamSession(socket: socket, startMs: startMs, track: options.track, language: options.language,
                                              speakerLabels: speakers, onEvent: onEvent) { [weak self] in
            self?.rejectSpeakerLabels()
        }
        session.startReceiving()
        return session
    }

    /// 音声を送る AudioEvent（空なら音声の終わり）
    public static func audioEvent(_ pcm: Data) -> Data {
        EventStreamMessage(headers: [
            ":content-type": .string("application/octet-stream"),
            ":event-type": .string("AudioEvent"),
            ":message-type": .string("event"),
        ], payload: pcm).encode()
    }
}

/// Transcribe Streaming の 1 セッション
final class TranscribeStreamSession: LiveSession, @unchecked Sendable {
    let socket: LiveDataSocket
    let startMs: Int64
    let track: TrackID
    let language: String
    let speakerLabels: Bool
    let onEvent: @Sendable (LiveTranscriber.Event) -> Void
    let onSpeakerLabelsRejected: @Sendable () -> Void
    private let lock = NSLock()
    private var sentMs: Int64 = 0
    /// 認識途中の発言があるか
    private var partialOpen = false
    private var lastActivityMs: Int64 = 0
    private var dead = false
    private var permanent = false
    private var _deathReason: String?
    private var receiver: Task<Void, Never>?
    private var ended = false
    private var receiverDone = false
    private var lastMessageAt = Date()

    init(socket: LiveDataSocket, startMs: Int64, track: TrackID, language: String, speakerLabels: Bool,
         onEvent: @escaping @Sendable (LiveTranscriber.Event) -> Void, onSpeakerLabelsRejected: @escaping @Sendable () -> Void) {
        self.socket = socket
        self.startMs = startMs
        self.track = track
        self.language = language
        self.speakerLabels = speakerLabels
        self.onEvent = onEvent
        self.onSpeakerLabelsRejected = onSpeakerLabelsRejected
    }

    var isDead: Bool { lock.withLock { dead } }
    var deathReason: String? { lock.withLock { _deathReason } }
    var deathIsPermanent: Bool { lock.withLock { permanent } }

    func markDead(_ reason: String) { markDead(reason, permanent: false) }

    func markDead(_ reason: String, permanent isPermanent: Bool) {
        lock.withLock {
            if !dead {
                _deathReason = reason
                permanent = isPermanent
            }
            dead = true
        }
    }

    func sendAudio(_ chunk: LiveTranscriber.Chunk) async throws {
        try await socket.send(TranscribeStreamingBackend.audioEvent(chunk.pcm))
        lock.withLock { sentMs = max(sentMs, chunk.startMs + chunk.durationMs - startMs) }
    }

    func shouldRotate(at positionMs: Int64, options: LiveTranscriber.Options) -> Bool {
        let elapsed = positionMs - startMs
        return lock.withLock {
            if elapsed >= options.hardLimitMs { return true }
            guard elapsed >= options.softLimitMs else { return false }
            return !partialOpen && sentMs - lastActivityMs >= options.quietMs
        }
    }

    func startReceiving() {
        receiver = Task { [weak self] in
            guard let self else { return }
            while true {
                let data: Data
                do {
                    data = try await self.socket.receive()
                } catch {
                    let wasEnded = self.lock.withLock { self.receiverDone = true; return self.ended }
                    if !wasEnded {
                        let permanent = (error as? LiveConnectionError)?.permanent ?? false
                        self.markDead(String(describing: error), permanent: permanent)
                    }
                    return
                }
                self.lock.withLock { self.lastMessageAt = Date() }
                self.handle(data)
            }
        }
    }

    /// 空の AudioEvent で終わりを伝え、サーバーが残りの結果を送って閉じるのを待つ
    func endAndDrain(timeout: Double) async {
        lock.withLock {
            ended = true
            lastMessageAt = Date()
        }
        try? await socket.send(TranscribeStreamingBackend.audioEvent(Data()))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (quiet, finished) = lock.withLock {
                (Date().timeIntervalSince(lastMessageAt) >= 3 && !partialOpen, receiverDone)
            }
            if quiet || finished { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        socket.close()
        await receiver?.value
        onEvent(.interim(track, nil))
    }

    func handle(_ data: Data) {
        guard let msg = try? EventStreamMessage.decode(data) else {
            CappyLog.shared.warning(tr("live \(track.rawValue): cannot parse a Transcribe Streaming message (\(data.count) bytes)", ja: "live \(track.rawValue): Transcribe Streaming のメッセージを解釈できません（\(data.count) バイト）"))
            return
        }
        if msg.string(":message-type") == "exception" {
            handleException(type: msg.string(":exception-type") ?? "Exception", payload: msg.payload)
            return
        }
        guard msg.string(":event-type") == "TranscriptEvent" else { return }
        let results = TranscribeStreamParser.results(msg.payload, language: language)
        for r in results {
            if r.isPartial {
                lock.withLock {
                    partialOpen = true
                    lastActivityMs = sentMs
                }
                onEvent(.interim(track, r.text))
            } else {
                lock.withLock {
                    partialOpen = false
                    lastActivityMs = sentMs
                }
                for part in r.parts where !part.text.isEmpty {
                    onEvent(.segment(Segment(track: track, speaker: part.speaker, startMs: startMs + part.startMs,
                                             endMs: startMs + max(part.startMs, part.endMs), text: part.text,
                                             confidence: part.confidence)))
                }
                onEvent(.interim(track, nil))
            }
        }
    }

    func handleException(type: String, payload: Data) {
        let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let message = (obj?["Message"] as? String) ?? (obj?["message"] as? String) ?? String(decoding: payload, as: UTF8.self)
        let lower = message.lowercased()
        if speakerLabels && (lower.contains("speaker") || lower.contains("partition")) {
            // 話者分離に対応していない場合は、話者分離なしで張り直す
            onSpeakerLabelsRejected()
            CappyLog.shared.warning(tr("live \(track.rawValue): speaker diarization is not available; reconnecting without it: \(message)", ja: "live \(track.rawValue): 話者分離を使えないため、話者分離なしで再接続します: \(message)"))
            markDead(tr("Speaker diarization is not available; reconnecting without it (\(message))", ja: "話者分離を使えないため、話者分離なしで再接続します（\(message)）"), permanent: false)
            return
        }
        // 設定の誤り（言語・語彙など）は再接続しても直らない。無音が続いた時間切れなどは再接続する
        let permanent = type == "BadRequestException" && !lower.contains("timed out")
        markDead(tr("Amazon Transcribe Streaming error (\(type)): \(message)", ja: "Amazon Transcribe Streaming のエラー（\(type)）: \(message)"), permanent: permanent)
    }
}

/// TranscriptEvent の JSON を解釈する
public enum TranscribeStreamParser {
    public struct Part: Sendable, Equatable {
        public var speaker: String?
        public var startMs: Int64
        public var endMs: Int64
        public var text: String
        public var confidence: Double?
    }

    public struct Result: Sendable, Equatable {
        public var isPartial: Bool
        public var text: String
        /// 確定した結果を話者ごとに分けたもの
        public var parts: [Part]
    }

    public static func results(_ payload: Data, language: String) -> [Result] {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let rs = (obj["Transcript"] as? [String: Any])?["Results"] as? [[String: Any]] else { return [] }
        let sep = GoogleResultParser.joiner(for: language)
        return rs.compactMap { r in
            guard let alt = (r["Alternatives"] as? [[String: Any]])?.first else { return nil }
            let isPartial = r["IsPartial"] as? Bool ?? false
            let start = ms(r["StartTime"]) ?? 0
            let end = ms(r["EndTime"]) ?? start
            let items = alt["Items"] as? [[String: Any]] ?? []
            let transcript = (alt["Transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            // 単語と句読点から、話者ごとのまとまりを作る
            var parts: [Part] = []
            var confs: [[Double]] = []
            for item in items {
                let content = item["Content"] as? String ?? ""
                if item["Type"] as? String == "punctuation" {
                    if !parts.isEmpty { parts[parts.count - 1].text += content }
                    continue
                }
                guard !content.isEmpty else { continue }
                let speaker = (item["Speaker"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let s = ms(item["StartTime"]) ?? start
                let e = ms(item["EndTime"]) ?? s
                let c = (item["Confidence"] as? NSNumber)?.doubleValue
                if let last = parts.last, last.speaker == speaker {
                    parts[parts.count - 1].text += sep + content
                    parts[parts.count - 1].endMs = max(last.endMs, e)
                    if let c { confs[confs.count - 1].append(c) }
                } else {
                    parts.append(Part(speaker: speaker, startMs: s, endMs: e, text: content, confidence: nil))
                    confs.append(c.map { [$0] } ?? [])
                }
            }
            for i in parts.indices where !confs[i].isEmpty {
                parts[i].confidence = confs[i].reduce(0, +) / Double(confs[i].count)
            }
            if parts.isEmpty && !transcript.isEmpty {
                parts = [Part(speaker: nil, startMs: start, endMs: end, text: transcript, confidence: nil)]
            }
            let text = parts.isEmpty ? transcript : parts.map(\.text).joined(separator: sep)
            return Result(isPartial: isPartial, text: text.isEmpty ? transcript : text, parts: parts)
        }
    }

    static func ms(_ v: Any?) -> Int64? {
        guard let d = (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) else { return nil }
        return Int64((d * 1000).rounded())
    }
}
