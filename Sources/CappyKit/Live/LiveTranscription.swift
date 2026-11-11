import AVFoundation
import Foundation

/// リアルタイム文字起こしの状態（session.json の live）
public struct LiveTranscriptionState: Codable, Sendable, Equatable {
    public var provider: String
    public var model: String
    public var location: String
    public var language: String
    public var state: JobState
    /// 張ったセッションの数（トラックの合計）
    public var sessions: Int
    public var segments: Int
    /// 接続できず送れなかった音声の長さ（ms, トラックの合計）
    public var droppedMs: Int64
    public var file: String?
    public var error: String?
    public var updatedAt: String?

    public init(provider: String, model: String, location: String, language: String) {
        self.provider = provider
        self.model = model
        self.location = location
        self.language = language
        self.state = .running
        self.sessions = 0
        self.segments = 0
        self.droppedMs = 0
    }

    enum CodingKeys: String, CodingKey {
        case provider, model, location, language, state, sessions, segments, file, error
        case droppedMs = "dropped_ms"
        case updatedAt = "updated_at"
    }
}

/// 録音中の音声を 16 kHz・モノラル・16 bit PCM に変換し、100 ms ごとに LiveTranscriber に渡すシンク
public final class LiveAudioSink: AudioSink, @unchecked Sendable {
    public static let sampleRate: Double = 16_000
    /// 1 回に送る長さ（ms）
    static let chunkMs: Int64 = 100

    let transcriber: LiveTranscriber
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: LiveAudioSink.sampleRate,
                                          channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var pending = Data()
    /// これまでに出力したフレーム数（16 kHz）
    private var framesOut: Int64 = 0
    private var pendingStartFrame: Int64 = 0

    public init(transcriber: LiveTranscriber) { self.transcriber = transcriber }

    public var failure: Error? { nil }

    public func start(format: AVAudioFormat, track: TrackID) throws {
        transcriber.start()
    }

    public func consume(_ buffer: AVAudioPCMBuffer, at hostTime: UInt64) {
        guard buffer.frameLength > 0 else { return }
        if converterInput == nil || !(converterInput!.isEqual(buffer.format)) {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
            converter?.downmix = true
            converterInput = buffer.format
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outFormat.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let p = out.int16ChannelData?[0] else { return }
        append(Data(bytes: p, count: Int(out.frameLength) * 2), frames: Int64(out.frameLength))
    }

    /// 変換済みの PCM をためて、100 ms ごとに送る
    func append(_ data: Data, frames: Int64) {
        if pending.isEmpty { pendingStartFrame = framesOut }
        pending.append(data)
        framesOut += frames
        let chunkBytes = Int(Self.sampleRate) * Int(Self.chunkMs) / 1000 * 2
        while pending.count >= chunkBytes {
            let piece = pending.prefix(chunkBytes)
            transcriber.enqueue(.init(pcm: Data(piece), startMs: pendingStartFrame * 1000 / Int64(Self.sampleRate),
                                      durationMs: Self.chunkMs))
            pending.removeFirst(chunkBytes)
            pendingStartFrame += Int64(chunkBytes / 2)
        }
    }

    public func finish() async throws {
        if !pending.isEmpty {
            let frames = Int64(pending.count / 2)
            transcriber.enqueue(.init(pcm: pending, startMs: pendingStartFrame * 1000 / Int64(Self.sampleRate),
                                      durationMs: frames * 1000 / Int64(Self.sampleRate)))
            pending.removeAll()
        }
        await transcriber.finish()
    }
}

/// 録音 1 回分のリアルタイム文字起こし（トラックごとの LiveTranscriber と結果の保存）
public final class LiveTranscription: @unchecked Sendable {
    public static let baseName = "live-transcript"
    public static let journalName = "live-transcript.jsonl"

    let store: SessionStore
    let settings: GeminiSettings
    let projectID: String
    let language: String
    let connector: LiveConnector
    private let lock = NSLock()
    private var transcribers: [TrackID: LiveTranscriber] = [:]
    private var segments: [Segment] = []
    private var journal: FileHandle?

    /// 確定した発言
    public var onSegment: (@Sendable (Segment) -> Void)?
    /// 認識途中の文字（nil で消す）
    public var onInterim: (@Sendable (TrackID, String?) -> Void)?
    /// 接続・切断などの知らせ
    public var onNotice: (@Sendable (String) -> Void)?

    public init(store: SessionStore, settings: GeminiSettings, projectID: String, language: String, connector: LiveConnector) {
        self.store = store
        self.settings = settings
        self.projectID = projectID
        self.language = language
        self.connector = connector
    }

    public var modelResource: String {
        "projects/\(projectID)/locations/\(settings.location)/publishers/google/models/\(settings.liveModel)"
    }

    /// Recorder に渡すシンクを作る
    public func sink(for track: TrackID) -> AudioSink {
        let t = LiveTranscriber(options: .init(model: modelResource, language: language, track: track),
                                connector: connector) { [weak self] event in self?.handle(event) }
        lock.withLock { transcribers[track] = t }
        if journal == nil { openJournal() }
        return LiveAudioSink(transcriber: t)
    }

    /// 開始時の状態を書く
    public func begin() throws {
        try store.update { m in
            m.live = LiveTranscriptionState(provider: "gemini", model: settings.liveModel, location: settings.location,
                                            language: language)
            m.live?.updatedAt = TimeFormat.iso8601(Date())
        }
    }

    private func openJournal() {
        let url = store.url(for: Self.journalName)
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        journal = try? FileHandle(forWritingTo: url)
        _ = try? journal?.seekToEnd()
    }

    private func handle(_ event: LiveTranscriber.Event) {
        switch event {
        case .segment(let s):
            lock.withLock {
                segments.append(s)
                if let data = try? JSONEncoder().encode(s) {
                    try? journal?.write(contentsOf: data + Data("\n".utf8))
                }
            }
            onSegment?(s)
        case .interim(let track, let text):
            onInterim?(track, text)
        case .connected(let track, let n):
            CappyLog.shared.info("live \(track.rawValue): セッション \(n) を開始しました")
            if n == 1 { onNotice?("\(track.displayName)（\(track.rawValue)）のリアルタイム文字起こしを開始しました") }
        case .disconnected(let track, let reason):
            CappyLog.shared.warning("live \(track.rawValue): \(reason)（再接続します）")
            onNotice?("\(track.displayName)（\(track.rawValue)）のリアルタイム文字起こしが切断されました。再接続します: \(reason)")
        case .failed(let track, let reason):
            CappyLog.shared.error("live \(track.rawValue): \(reason)")
            onNotice?("\(track.displayName)（\(track.rawValue)）のリアルタイム文字起こしを中止しました（録音は続けます）: \(reason)")
        }
    }

    /// 録音の停止後に呼ぶ（シンクの finish の後）。live-transcript.{md,json,srt} を書く
    @discardableResult
    public func finish(formats: [TranscriptFormat] = TranscriptFormat.allCases) throws -> [URL] {
        let (all, ts) = lock.withLock { (segments, transcribers) }
        try? journal?.close()
        journal = nil
        let failed = ts.values.contains { $0.failed }
        let errors = ts.values.compactMap(\.lastError)
        let meta = store.metadata
        let doc = TranscriptDocument(sessionID: meta.id, name: meta.name, startedAt: meta.startedAt, provider: "gemini-live",
                                     model: settings.liveModel, language: language, mix: false, diarization: [:],
                                     segments: TranscriptMerger.merge([all]))
        var urls: [URL] = []
        if !doc.segments.isEmpty {
            urls = try TranscriptRenderer.write(doc, formats: formats.contains(.json) ? formats : formats + [.json],
                                                to: store.directory, baseName: Self.baseName)
            try? FileManager.default.removeItem(at: store.url(for: Self.journalName))
        }
        try store.update { m in
            m.live?.state = failed && doc.segments.isEmpty ? .failed : .done
            m.live?.sessions = ts.values.reduce(0) { $0 + $1.sessions }
            m.live?.segments = doc.segments.count
            m.live?.droppedMs = ts.values.reduce(0) { $0 + $1.droppedMs }
            m.live?.file = doc.segments.isEmpty ? nil : "\(Self.baseName).json"
            m.live?.error = errors.first
            m.live?.updatedAt = TimeFormat.iso8601(Date())
        }
        return urls.filter { u in formats.contains { $0.fileName(base: Self.baseName) == u.lastPathComponent } }
    }

    /// 異常終了したセッションの live-transcript.jsonl から live-transcript.* を作る
    public static func recoverJournal(_ store: SessionStore) throws -> [URL] {
        let journal = store.url(for: journalName)
        guard let data = try? Data(contentsOf: journal) else { return [] }
        let segments = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
            try? JSONDecoder().decode(Segment.self, from: Data($0.utf8))
        }
        guard !segments.isEmpty else { return [] }
        let meta = store.metadata
        let doc = TranscriptDocument(sessionID: meta.id, name: meta.name, startedAt: meta.startedAt, provider: "gemini-live",
                                     model: meta.live?.model, language: meta.live?.language ?? "ja-JP", mix: false,
                                     diarization: [:], segments: TranscriptMerger.merge([segments]))
        let urls = try TranscriptRenderer.write(doc, formats: TranscriptFormat.allCases, to: store.directory, baseName: baseName)
        try store.update { m in
            m.live?.state = .done
            m.live?.segments = doc.segments.count
            m.live?.file = "\(baseName).json"
        }
        try? FileManager.default.removeItem(at: journal)
        return urls
    }
}
