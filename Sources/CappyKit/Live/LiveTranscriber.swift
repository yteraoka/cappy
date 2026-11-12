import Foundation

/// リアルタイム文字起こしの 1 セッション（Gemini Live API / Amazon Transcribe Streaming）
public protocol LiveSession: AnyObject, Sendable {
    /// このセッションに最初に送った音声の、録音開始からの位置（ms）
    var startMs: Int64 { get }
    var isDead: Bool { get }
    var deathReason: String? { get }
    /// 再接続しても直らない理由で切れたか（設定・権限の誤りなど）
    var deathIsPermanent: Bool { get }
    func markDead(_ reason: String)
    func sendAudio(_ chunk: LiveTranscriber.Chunk) async throws
    func shouldRotate(at positionMs: Int64, options: LiveTranscriber.Options) -> Bool
    /// 音声の終わりを伝え、残りの結果を受け取ってから閉じる
    func endAndDrain(timeout: Double) async
}

/// セッションを開く（接続と準備まで）
public protocol LiveBackend: Sendable {
    func open(startMs: Int64, options: LiveTranscriber.Options,
              onEvent: @escaping @Sendable (LiveTranscriber.Event) -> Void) async throws -> LiveSession
}

/// Vertex AI の Gemini Live API
public struct GeminiLiveBackend: LiveBackend {
    let connector: LiveConnector

    public init(connector: LiveConnector) { self.connector = connector }

    public func open(startMs: Int64, options: LiveTranscriber.Options,
                     onEvent: @escaping @Sendable (LiveTranscriber.Event) -> Void) async throws -> LiveSession {
        let socket = try await connector.connect()
        let handle = LiveSessionHandle(socket: socket, startMs: startMs, track: options.track, language: options.language,
                                       targetUtteranceMs: options.targetUtteranceMs, quietUtteranceMs: options.quietUtteranceMs,
                                       maxUtteranceMs: options.maxUtteranceMs,
                                       onEvent: onEvent)
        do {
            try await handle.setup(model: options.model, timeout: options.setupTimeoutSeconds)
        } catch {
            socket.close()
            throw error
        }
        handle.startReceiving()
        return handle
    }
}

/// 1 トラック分のリアルタイム文字起こし。
/// 音声（16 kHz・モノラル・16 bit PCM）を Live API に送り、確定した発言を Segment として返す。
/// Live API は 1 セッションで約 10 分の音声までなので、話の切れ目でセッションを張り替える。
public final class LiveTranscriber: @unchecked Sendable {
    public struct Options: Sendable {
        /// projects/<p>/locations/<l>/publishers/google/models/<model>
        public var model: String
        public var language: String
        public var track: TrackID
        /// この長さを超えたら、話の切れ目でセッションを張り替える（ms）
        public var softLimitMs: Int64 = 9 * 60_000
        /// この長さを超えたら、話の途中でも張り替える（ms）
        public var hardLimitMs: Int64 = 9 * 60_000 + 45_000
        /// 話の切れ目とみなす無音（認識途中の文字がない時間, ms）
        public var quietMs: Int64 = 1_200
        /// 確定しない発言がこの長さを超えたら、文の終わり（認識途中の文字の末尾近くに「。」などが来たところ）で確定させる（ms。Gemini のみ）。
        /// 相手が話し続けるとサーバーが話の切れ目を見つけられず、止めるまで何も確定しないため
        public var targetUtteranceMs: Int64 = 20_000
        /// 文の終わりが来ないままこの長さを超えたら、音の小さいところで確定させる（ms。Gemini のみ）
        public var quietUtteranceMs: Int64 = 30_000
        /// 確定しない発言がこの長さを超えたら、音の大きさによらず確定させる（ms。Gemini のみ）
        public var maxUtteranceMs: Int64 = 40_000
        /// セッションの終了時に、残りの結果を待つ時間（秒）
        public var drainSeconds: Double = 8
        public var setupTimeoutSeconds: Double = 15
        public var maxBackoffSeconds: Double = 30

        public init(model: String, language: String, track: TrackID) {
            self.model = model
            self.language = language
            self.track = track
        }
    }

    public struct Chunk: Sendable {
        public var pcm: Data
        /// 録音開始からの位置（ms）
        public var startMs: Int64
        public var durationMs: Int64
    }

    public enum Event: Sendable {
        case segment(Segment)
        case interim(TrackID, String?)
        case connected(TrackID, sessions: Int)
        /// 一時的な切断（再接続を試みる）
        case disconnected(TrackID, String)
        /// 再接続しても直らない失敗（以降は送信しない）
        case failed(TrackID, String)
    }

    public let options: Options
    let backend: LiveBackend
    let onEvent: @Sendable (Event) -> Void
    private let stream: AsyncStream<Chunk>
    private let continuation: AsyncStream<Chunk>.Continuation
    private var worker: Task<Void, Never>?
    private let lock = NSLock()
    private var _sessions = 0
    private var _droppedMs: Int64 = 0
    private var _lastError: String?
    private var _failed = false
    private var closing: [Task<Void, Never>] = []

    public convenience init(options: Options, connector: LiveConnector, onEvent: @escaping @Sendable (Event) -> Void) {
        self.init(options: options, backend: GeminiLiveBackend(connector: connector), onEvent: onEvent)
    }

    public init(options: Options, backend: LiveBackend, onEvent: @escaping @Sendable (Event) -> Void) {
        self.options = options
        self.backend = backend
        self.onEvent = onEvent
        (stream, continuation) = AsyncStream<Chunk>.makeStream()
    }

    public var sessions: Int { lock.withLock { _sessions } }
    /// 送れなかった音声の長さ（接続できなかった間）
    public var droppedMs: Int64 { lock.withLock { _droppedMs } }
    public var lastError: String? { lock.withLock { _lastError } }
    public var failed: Bool { lock.withLock { _failed } }

    public func start() {
        worker = Task { [weak self] in await self?.run() }
    }

    /// 書き込みスレッドから呼ばれる（ブロックしない）
    public func enqueue(_ chunk: Chunk) {
        continuation.yield(chunk)
    }

    /// 音声の終わり。残りの結果を待ってから戻る
    public func finish() async {
        continuation.finish()
        await worker?.value
        let tasks = lock.withLock { closing }
        for t in tasks { await t.value }
    }

    // MARK: 送信ループ

    private func run() async {
        var current: LiveSession?
        var nextRetry = Date.distantPast
        var backoff = 1.0
        for await chunk in stream {
            if failed {
                addDropped(chunk.durationMs)
                continue
            }
            if let s = current, s.isDead {
                end(s)
                current = nil
                if s.deathIsPermanent {
                    handleConnectError(LiveConnectionError(message: s.deathReason ?? tr("Disconnected", ja: "切断されました"), permanent: true))
                    addDropped(chunk.durationMs)
                    continue
                }
                onEvent(.disconnected(options.track, s.deathReason ?? tr("Disconnected", ja: "切断されました")))
            }
            if current == nil {
                guard Date() >= nextRetry else {
                    addDropped(chunk.durationMs)
                    continue
                }
                do {
                    current = try await open(at: chunk.startMs)
                    backoff = 1
                } catch {
                    handleConnectError(error)
                    nextRetry = Date().addingTimeInterval(backoff)
                    backoff = min(options.maxBackoffSeconds, backoff * 2)
                    addDropped(chunk.durationMs)
                    continue
                }
            }
            guard var s: LiveSession = current else { continue }
            if s.shouldRotate(at: chunk.startMs, options: options) {
                // 新しいセッションを先に開き、古いほうは残りの結果を受け取ってから閉じる
                if let fresh = try? await open(at: chunk.startMs) {
                    end(s)
                    s = fresh
                    current = fresh
                } else if chunk.startMs - s.startMs >= options.hardLimitMs + 10_000 {
                    end(s)
                    current = nil
                    addDropped(chunk.durationMs)
                    continue
                }
            }
            do {
                try await s.sendAudio(chunk)
            } catch {
                s.markDead(String(describing: error))
            }
        }
        if let s = current { end(s) }
    }

    private func open(at startMs: Int64) async throws -> LiveSession {
        let handle = try await backend.open(startMs: startMs, options: options, onEvent: onEvent)
        let n = lock.withLock { _sessions += 1; return _sessions }
        onEvent(.connected(options.track, sessions: n))
        return handle
    }

    private func end(_ s: LiveSession) {
        let drain = options.drainSeconds
        let t = Task { await s.endAndDrain(timeout: drain) }
        lock.withLock { closing.append(t) }
    }

    private func handleConnectError(_ error: Error) {
        let message = String(describing: error)
        let permanent = (error as? LiveConnectionError)?.permanent ?? false
        lock.withLock {
            _lastError = message
            if permanent { _failed = true }
        }
        onEvent(permanent ? .failed(options.track, message) : .disconnected(options.track, message))
    }

    private func addDropped(_ ms: Int64) {
        lock.withLock { _droppedMs += ms }
    }
}

/// Gemini Live API の 1 セッション
final class LiveSessionHandle: LiveSession, @unchecked Sendable {
    let socket: LiveSocket
    /// このセッションに最初に送った音声の、録音開始からの位置（ms）
    let startMs: Int64
    let track: TrackID
    let language: String
    let targetUtteranceMs: Int64
    let quietUtteranceMs: Int64
    let maxUtteranceMs: Int64
    let onEvent: @Sendable (LiveTranscriber.Event) -> Void
    private let lock = NSLock()
    /// 送った音声の長さ（セッション内, ms）
    private var sentMs: Int64 = 0
    /// 認識途中の発言の開始位置（セッション内, ms）
    private var utteranceStartMs: Int64?
    /// 認識途中の文字（確定しないまま終わったときに残す）
    private var lastInterim: String?
    /// 直近の音声の大きさ（100 ms ごと、約 3 秒分）。区切る位置を選ぶのに使う
    private var recentLevels: [Float] = []
    /// 長い発言を確定させるために audioStreamEnd を送った位置（セッション内, ms）
    private var flushedAtMs: Int64?
    /// 区切って確定させた発言の、最後の文の終わりより後ろ（次の発言の頭に付ける）
    private var carry: String?
    /// carry を切り出した発言の終わり（セッション内, ms）。carry の発言の開始位置にする
    private var carryAtMs: Int64 = 0
    /// 最後に認識結果（途中・確定）を受け取った位置（セッション内, ms）
    private var lastActivityMs: Int64 = 0
    private var goAway = false
    private var dead = false
    private var _deathReason: String?
    private var receiver: Task<Void, Never>?
    private var ended = false
    private var receiverDone = false
    private var lastMessageAt = Date()

    init(socket: LiveSocket, startMs: Int64, track: TrackID, language: String,
         targetUtteranceMs: Int64 = 20_000, quietUtteranceMs: Int64 = 30_000, maxUtteranceMs: Int64 = 40_000,
         onEvent: @escaping @Sendable (LiveTranscriber.Event) -> Void) {
        self.socket = socket
        self.startMs = startMs
        self.track = track
        self.language = language
        self.targetUtteranceMs = targetUtteranceMs
        self.quietUtteranceMs = quietUtteranceMs
        self.maxUtteranceMs = maxUtteranceMs
        self.onEvent = onEvent
    }

    var isDead: Bool { lock.withLock { dead } }
    var deathReason: String? { lock.withLock { _deathReason } }
    var deathIsPermanent: Bool { false }

    func markDead(_ reason: String) {
        lock.withLock {
            if !dead { _deathReason = reason }
            dead = true
        }
    }

    static func setupMessage(model: String, language: String) -> String {
        let obj: [String: Any] = [
            "setup": [
                "model": model,
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": ["languageCodes": [language]],
            ],
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
    }

    static func audioMessage(_ pcm: Data) -> String {
        "{\"realtimeInput\":{\"audio\":{\"data\":\"\(pcm.base64EncodedString())\",\"mimeType\":\"audio/pcm;rate=16000\"}}}"
    }

    static let audioStreamEndMessage = "{\"realtimeInput\":{\"audioStreamEnd\":true}}"

    /// setup を送り、setupComplete を待つ
    func setup(model: String, timeout: Double) async throws {
        try await socket.send(Self.setupMessage(model: model, language: language))
        // receive は取り消しに応じないため、時間切れはソケットを閉じて知らせる
        let socket = self.socket
        let timedOut = Flag()
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            guard !Task.isCancelled else { return }
            timedOut.set()
            socket.close()
        }
        defer { timer.cancel() }
        let first: String
        do {
            first = try await socket.receive()
        } catch {
            if timedOut.value {
                throw LiveConnectionError(message: tr("The live API setup did not finish within \(Int(timeout)) seconds", ja: "Live API の準備が \(Int(timeout)) 秒以内に終わりませんでした"), permanent: false)
            }
            throw error
        }
        guard let obj = Self.json(first) else {
            throw LiveConnectionError(message: tr("Invalid live API response", ja: "Live API の応答が不正です"), permanent: false)
        }
        if obj["setupComplete"] != nil { return }
        if let err = obj["error"] as? [String: Any] {
            let code = err["code"] as? Int ?? 0
            throw LiveConnectionError(message: tr("Live API error: \(err["message"] as? String ?? "unknown")", ja: "Live API のエラー: \(err["message"] as? String ?? "不明")"),
                                      permanent: [400, 401, 403, 404].contains(code))
        }
        throw LiveConnectionError(message: tr("The live API did not return setupComplete", ja: "Live API が setupComplete を返しませんでした"), permanent: false)
    }

    func startReceiving() {
        receiver = Task { [weak self] in
            guard let self else { return }
            while true {
                let text: String
                do {
                    text = try await self.socket.receive()
                } catch {
                    let wasEnded = self.lock.withLock { self.receiverDone = true; return self.ended }
                    if !wasEnded { self.markDead(String(describing: error)) }
                    return
                }
                self.lock.withLock { self.lastMessageAt = Date() }
                self.handle(text)
            }
        }
    }

    func sendAudio(_ chunk: LiveTranscriber.Chunk) async throws {
        if let open = shouldFlush(level: Self.level(chunk.pcm)) {
            // 音声の終わりを伝えると、サーバーは認識途中の発言を確定する。続けて音声を送れば同じセッションで認識を続ける
            CappyLog.shared.debug("live \(track.rawValue): flushing an utterance of \(open / 1000)s")
            try await socket.send(Self.audioStreamEndMessage)
        }
        try await socket.send(Self.audioMessage(chunk.pcm))
        lock.withLock { sentMs = max(sentMs, chunk.startMs + chunk.durationMs - startMs) }
    }

    /// 確定しない発言が長く続いているなら、その長さ（ms）を返す（ここで区切る）。
    /// targetUtteranceMs を超えたら文の終わりで、quietUtteranceMs を超えたら直近 3 秒で特に音の小さいところで、
    /// maxUtteranceMs を超えたらすぐに区切る
    func shouldFlush(level: Float) -> Int64? {
        lock.withLock {
            recentLevels.append(level)
            if recentLevels.count > 30 { recentLevels.removeFirst(recentLevels.count - 30) }
            guard let start = utteranceStartMs else { return nil }
            // 前に区切ってから確定が届くまでは待つ（届かなければ 10 秒後にもう一度）
            if let f = flushedAtMs, sentMs - f < 10_000 { return nil }
            let open = sentMs - start
            var flush = open >= maxUtteranceMs
            if !flush, open >= targetUtteranceMs, let text = lastInterim, let after = Self.splitAtSentenceEnd(text)?.tail {
                // 認識途中の文字は音声より少し遅れて届き、文の終わりの後ろに次の言葉が付いていることが多い
                flush = after.count <= Self.sentenceTailAllowance
            }
            if !flush, open >= quietUtteranceMs, recentLevels.count >= 10 {
                let sorted = recentLevels.sorted()
                flush = level <= sorted[sorted.count / 10]
            }
            guard flush else { return nil }
            flushedAtMs = sentMs
            return open
        }
    }

    /// 文の終わりの後ろに付いていてもよい文字数（これより短ければ、文の終わりとみなして区切る）
    static let sentenceTailAllowance = 12

    /// 最後の文の終わり（「。」「？」「！」など。直後の閉じかっこを含む）で分ける。文の終わりがなければ nil。
    /// 半角の . ? ! は、直後が空白か末尾のときだけ文の終わりとみなす（3.5 などで分けない）
    static func splitAtSentenceEnd(_ text: String) -> (head: String, tail: String)? {
        let chars = Array(text)
        let closing: Set<Character> = ["」", "』", "）", ")", "\"", "'", "”", "’"]
        var i = chars.count - 1
        while i >= 0 {
            let c = chars[i]
            let isEnd: Bool
            if "。？！．".contains(c) {
                isEnd = true
            } else if ".?!".contains(c) {
                isEnd = i + 1 == chars.count || chars[i + 1].isWhitespace
            } else {
                isEnd = false
            }
            if isEnd {
                var j = i + 1
                while j < chars.count, closing.contains(chars[j]) { j += 1 }
                let head = String(chars[..<j]).trimmingCharacters(in: .whitespacesAndNewlines)
                let tail = String(chars[j...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (head, tail)
            }
            i -= 1
        }
        return nil
    }

    /// 2 つの文字列をつなぐ（英数字どうしの間だけ空白を入れる）
    static func join(_ a: String, _ b: String) -> String {
        guard let x = a.last, let y = b.first else { return a + b }
        let wordy: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return wordy(x) && wordy(y) ? a + " " + b : a + b
    }

    /// 16 bit PCM の大きさ（RMS）
    static func level(_ pcm: Data) -> Float {
        pcm.withUnsafeBytes { raw -> Float in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            var sum: Float = 0
            for v in samples {
                let f = Float(Int16(littleEndian: v))
                sum += f * f
            }
            return (sum / Float(samples.count)).squareRoot()
        }
    }

    func shouldRotate(at positionMs: Int64, options: LiveTranscriber.Options) -> Bool {
        let elapsed = positionMs - startMs
        return lock.withLock {
            if goAway || elapsed >= options.hardLimitMs { return true }
            guard elapsed >= options.softLimitMs else { return false }
            return utteranceStartMs == nil && sentMs - lastActivityMs >= options.quietMs
        }
    }

    /// 音声の終わりを伝え、残りの結果を受け取ってから閉じる。
    /// サーバーが閉じない場合に備え、結果が 2 秒途切れるか timeout 秒たったら閉じる
    func endAndDrain(timeout: Double) async {
        lock.withLock {
            ended = true
            lastMessageAt = Date()
        }
        try? await socket.send(Self.audioStreamEndMessage)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (quiet, finished) = lock.withLock {
                (Date().timeIntervalSince(lastMessageAt) >= 2 && utteranceStartMs == nil, receiverDone)
            }
            if quiet || finished { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        socket.close()
        await receiver?.value
        // 確定しないまま終わった発言は、途中の文字を捨てずに残す（張り替えや停止で失わないように）
        let (pending, unconfirmed): (Segment?, Bool) = lock.withLock {
            defer {
                utteranceStartMs = nil
                lastInterim = nil
                carry = nil
            }
            let interim = lastInterim?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var start = utteranceStartMs ?? sentMs
            if carry != nil { start = min(start, carryAtMs) }
            if interim.isEmpty || utteranceStartMs == nil {
                // 区切った発言の残り（文の途中）だけが残っている
                guard let c = carry, !c.isEmpty else { return (nil, false) }
                return (Segment(track: track, speaker: nil, startMs: startMs + start, endMs: startMs + max(start, sentMs), text: c, confidence: nil), false)
            }
            let text = carry.map { Self.join($0, interim) } ?? interim
            return (Segment(track: track, speaker: nil, startMs: startMs + start, endMs: startMs + max(start, sentMs), text: text, confidence: nil), true)
        }
        if unconfirmed, let pending {
            CappyLog.shared.warning(tr("live \(track.rawValue): kept an unconfirmed utterance as it is (\(pending.text.count) characters)",
                                       ja: "live \(track.rawValue): 確定しなかった発言を認識途中の文字のまま残しました（\(pending.text.count) 文字）"))
        }
        if let pending { onEvent(.segment(pending)) }
        onEvent(.interim(track, nil))
    }

    static func json(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    func handle(_ text: String) {
        guard let obj = Self.json(text) else { return }
        if obj["goAway"] != nil {
            lock.withLock { goAway = true }
            CappyLog.shared.info(tr("live \(track.rawValue): received goAway from the server", ja: "live \(track.rawValue): サーバーから goAway を受け取りました"))
        }
        guard let content = obj["serverContent"] as? [String: Any] else { return }
        if let interim = GoogleResultParser.field(content, "interimInputTranscription") as? [String: Any],
           let t = interim["text"] as? String, !t.isEmpty {
            lock.withLock {
                if utteranceStartMs == nil { utteranceStartMs = max(0, sentMs - 1_500) }
                lastInterim = t
                lastActivityMs = sentMs
            }
            onEvent(.interim(track, t))
        }
        if let final = GoogleResultParser.field(content, "inputTranscription") as? [String: Any],
           let t = (final["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            let startOffset = GoogleResultParser.durationMs(GoogleResultParser.field(final, "startOffset"))
            let endOffset = GoogleResultParser.durationMs(GoogleResultParser.field(final, "endOffset"))
            let (start, end, text): (Int64, Int64, String?) = lock.withLock {
                var e = endOffset ?? sentMs
                var s = startOffset ?? utteranceStartMs ?? max(0, e - 2_000)
                // 前に区切った発言の文の途中の部分を頭に付ける
                var text = t
                if let c = carry {
                    text = Self.join(c, t)
                    s = min(s, carryAtMs)
                }
                carry = nil
                // こちらから区切った発言は、最後の文の終わりより後ろを次の発言に回す（文の途中で切れないように）
                if flushedAtMs != nil, let (head, tail) = Self.splitAtSentenceEnd(text), !head.isEmpty, !tail.isEmpty {
                    // 分けた位置の時刻は、文字数の割合で見積もる
                    let split = s + (max(s, e) - s) * Int64(head.count) / Int64(head.count + tail.count)
                    text = head
                    carry = tail
                    carryAtMs = split
                    e = split
                }
                utteranceStartMs = nil
                lastInterim = nil
                flushedAtMs = nil
                lastActivityMs = sentMs
                return (s, max(s, e), text.isEmpty ? nil : text)
            }
            let speaker = (GoogleResultParser.field(final, "speakerLabel") as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let text {
                onEvent(.segment(Segment(track: track, speaker: speaker, startMs: startMs + start, endMs: startMs + end,
                                         text: text, confidence: nil)))
            }
            onEvent(.interim(track, nil))
        }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}
