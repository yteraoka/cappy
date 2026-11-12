import Foundation

public enum TrackID: String, Codable, Sendable, CaseIterable, Comparable {
    case mic
    case remote
    case mix

    public static func < (a: TrackID, b: TrackID) -> Bool {
        let order: [TrackID] = [.mic, .remote, .mix]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }

    /// 画面に出す表示名（表示言語に合わせる）
    public var displayName: String { label(L10n.current) }

    /// 言語を指定した表示名（transcript.md などは会議の言語で書く）
    public func label(_ lang: UILanguage) -> String {
        switch self {
        case .mic: return tr(lang, "Me", ja: "自分")
        case .remote: return tr(lang, "Remote", ja: "相手")
        case .mix: return tr(lang, "Speaker", ja: "話者")
        }
    }
}

public struct SessionTarget: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case app, pid, system }
    public var kind: Kind
    public var bundleID: String?
    public var pid: Int32?
    /// 録音開始時に一致したプロセスの PID
    public var matchedPIDs: [Int32]?

    public init(kind: Kind, bundleID: String? = nil, pid: Int32? = nil, matchedPIDs: [Int32]? = nil) {
        self.kind = kind
        self.bundleID = bundleID
        self.pid = pid
        self.matchedPIDs = matchedPIDs
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case bundleID = "bundle_id"
        case pid
        case matchedPIDs = "matched_pids"
    }
}

public struct SessionTrack: Codable, Sendable, Equatable {
    public var id: TrackID
    /// 録音中の原本（CAF）
    public var file: String
    public var sampleRate: Double
    public var channels: Int
    /// 録音開始からの先頭オフセット（ms）
    public var offsetMs: Int64
    public var frames: Int64?
    public var durationMs: Int64?
    /// 送信用ファイル（16 kHz・モノラル・16 bit）
    public var sendFile: String?
    public var deviceUID: String?
    public var deviceName: String?

    public init(id: TrackID, file: String, sampleRate: Double, channels: Int, offsetMs: Int64 = 0) {
        self.id = id
        self.file = file
        self.sampleRate = sampleRate
        self.channels = channels
        self.offsetMs = offsetMs
    }

    enum CodingKeys: String, CodingKey {
        case id, file, channels, frames
        case sampleRate = "sample_rate"
        case offsetMs = "offset_ms"
        case durationMs = "duration_ms"
        case sendFile = "send_file"
        case deviceUID = "device_uid"
        case deviceName = "device_name"
    }
}

public struct SessionGap: Codable, Sendable, Equatable {
    /// 録音開始からの位置（ms）
    public var startMs: Int64
    public var endMs: Int64
    public var reason: String

    public init(startMs: Int64, endMs: Int64, reason: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case startMs = "start_ms"
        case endMs = "end_ms"
        case reason
    }
}

public struct SessionMarker: Codable, Sendable, Equatable {
    public var atMs: Int64
    public var label: String?

    public init(atMs: Int64, label: String?) {
        self.atMs = atMs
        self.label = label
    }

    enum CodingKeys: String, CodingKey {
        case atMs = "at_ms"
        case label
    }
}

/// マイクをミュートした区間（録音開始からの ms。終了前は endMs が nil）
public struct SessionMute: Codable, Sendable, Equatable {
    public var startMs: Int64
    public var endMs: Int64?

    public init(startMs: Int64, endMs: Int64? = nil) {
        self.startMs = startMs
        self.endMs = endMs
    }

    enum CodingKeys: String, CodingKey {
        case startMs = "start_ms"
        case endMs = "end_ms"
    }

    /// ミュートの開始・解除を区間の一覧に反映する
    public static func apply(muted: Bool, atMs: Int64, to mutes: inout [SessionMute]) {
        if muted {
            if let last = mutes.last, last.endMs == nil { return }
            mutes.append(SessionMute(startMs: atMs))
        } else if let i = mutes.indices.last, mutes[i].endMs == nil {
            mutes[i].endMs = max(mutes[i].startMs, atMs)
        }
    }

    /// ミュートしていた合計時間（閉じていない区間は untilMs まで）
    public static func totalMs(_ mutes: [SessionMute], untilMs: Int64) -> Int64 {
        mutes.reduce(0) { $0 + max(0, ($1.endMs ?? untilMs) - $1.startMs) }
    }
}

public struct RecordingState: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// 録音中（このまま残っていれば異常終了）
        case recording
        /// CAF の確定まで完了（送信用ファイル未作成）
        case finalized
        /// 送信用ファイルまで作成済み
        case converted
    }

    public var state: State
    /// 録音開始時のホストタイム（mach_absolute_time）
    public var hostTimeStart: UInt64?
    public var stopReason: String?
    public var droppedBuffers: Int?
    public var outputDeviceUID: String?
    public var sendFormat: String?
    public var recoveredAt: String?

    public init(state: State) { self.state = state }

    enum CodingKeys: String, CodingKey {
        case state
        case hostTimeStart = "host_time_start"
        case stopReason = "stop_reason"
        case droppedBuffers = "dropped_buffers"
        case outputDeviceUID = "output_device_uid"
        case sendFormat = "send_format"
        case recoveredAt = "recovered_at"
    }
}

public enum JobState: String, Codable, Sendable {
    case pending, running, done, failed
}

/// プロバイダに投入したジョブ（再開に必要な情報を保持する）
public struct JobHandle: Codable, Sendable, Equatable {
    public var provider: String
    public var track: TrackID
    /// プロバイダ側のジョブ ID（Google ならオペレーション名）
    public var id: String
    /// プロバイダ固有の情報（アップロード先 URI、分割オフセットなど）
    public var info: [String: String]

    public init(provider: String, track: TrackID, id: String, info: [String: String] = [:]) {
        self.provider = provider
        self.track = track
        self.id = id
        self.info = info
    }
}

public struct TranscriptionJobRecord: Codable, Sendable, Equatable {
    public var track: TrackID
    public var state: JobState
    public var handle: JobHandle?
    public var diarization: Bool?
    public var note: String?
    public var error: String?
    public var submittedAt: String?
    public var completedAt: String?

    public init(track: TrackID, state: JobState) {
        self.track = track
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case track, state, handle, diarization, note, error
        case submittedAt = "submitted_at"
        case completedAt = "completed_at"
    }
}

public struct TranscriptionState: Codable, Sendable, Equatable {
    public var provider: String
    public var model: String?
    public var language: String
    public var location: String?
    public var mix: Bool
    public var state: JobState
    public var jobs: [TranscriptionJobRecord]
    public var error: String?
    public var updatedAt: String?
    public var cleanedUp: Bool?

    public init(provider: String, model: String?, language: String, location: String?, mix: Bool) {
        self.provider = provider
        self.model = model
        self.language = language
        self.location = location
        self.mix = mix
        self.state = .pending
        self.jobs = []
    }

    enum CodingKeys: String, CodingKey {
        case provider, model, language, location, mix, state, jobs, error
        case updatedAt = "updated_at"
        case cleanedUp = "cleaned_up"
    }
}

/// 要約の状態
public struct SummaryState: Codable, Sendable, Equatable {
    public var provider: String
    public var model: String
    public var region: String?
    public var state: JobState
    /// 要約ファイル（セッションディレクトリからの相対パス）
    public var file: String?
    /// 要約の元にした transcript.json の SHA-256（文字起こしをやり直したら要約も作り直す）
    public var transcriptDigest: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var stopReason: String?
    public var note: String?
    public var error: String?
    public var updatedAt: String?

    public init(provider: String, model: String, region: String?) {
        self.provider = provider
        self.model = model
        self.region = region
        self.state = .pending
    }

    enum CodingKeys: String, CodingKey {
        case provider, model, region, state, file, note, error
        case transcriptDigest = "transcript_digest"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case stopReason = "stop_reason"
        case updatedAt = "updated_at"
    }
}

public struct SessionMetadata: Codable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var startedAt: String?
    public var endedAt: String?
    public var targets: [SessionTarget]
    public var tracks: [SessionTrack]
    public var gaps: [SessionGap]
    public var markers: [SessionMarker]
    /// マイクをミュートした区間（record 中の Space キーや `cappy mic off` で切り替えたもの）
    public var micMutes: [SessionMute]?
    public var recording: RecordingState
    public var transcription: TranscriptionState?
    public var summary: SummaryState?
    /// リアルタイム文字起こし（record --live）
    public var live: LiveTranscriptionState?
    public var profile: String?
    public var toolVersion: String

    public init(id: String, name: String?) {
        self.id = id
        self.name = name
        self.targets = []
        self.tracks = []
        self.gaps = []
        self.markers = []
        self.recording = RecordingState(state: .recording)
        self.toolVersion = CappyVersion.current
    }

    enum CodingKeys: String, CodingKey {
        case id, name, targets, tracks, gaps, markers, recording, transcription, summary, live, profile
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case micMutes = "mic_mutes"
        case toolVersion = "tool_version"
    }

    public func track(_ id: TrackID) -> SessionTrack? { tracks.first { $0.id == id } }

    public mutating func updateTrack(_ id: TrackID, _ body: (inout SessionTrack) -> Void) {
        if let i = tracks.firstIndex(where: { $0.id == id }) { body(&tracks[i]) }
    }
}

/// セッションディレクトリと session.json の読み書き
public final class SessionStore: @unchecked Sendable {
    public static let fileName = "session.json"

    public let directory: URL
    private let lock = NSLock()
    private var _metadata: SessionMetadata

    public var metadata: SessionMetadata { lock.withLock { _metadata } }
    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    public init(directory: URL, metadata: SessionMetadata) {
        self.directory = directory
        self._metadata = metadata
    }

    public static func open(_ directory: URL) throws -> SessionStore {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CappyError.usage(tr("session.json not found: \(directory.path)", ja: "session.json がありません: \(directory.path)"),
                                   hint: tr("If the session ended abnormally, run `cappy recover \(directory.path)`", ja: "異常終了したセッションなら `cappy recover \(directory.path)` を実行してください"))
        }
        let data = try Data(contentsOf: url)
        do {
            let meta = try decode(data)
            return SessionStore(directory: directory, metadata: meta)
        } catch {
            throw CappyError.usage(tr("Cannot read session.json: \(url.path): \(error)", ja: "session.json を読めません: \(url.path): \(error)"),
                                   hint: tr("Recreate it with `cappy recover \(directory.path)`", ja: "`cappy recover \(directory.path)` で再生成できます"))
        }
    }

    public static func decode(_ data: Data) throws -> SessionMetadata {
        try JSONDecoder().decode(SessionMetadata.self, from: data)
    }

    public static func encode(_ meta: SessionMetadata) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(meta)
    }

    @discardableResult
    public func update(_ body: (inout SessionMetadata) -> Void) throws -> SessionMetadata {
        try lock.withLock {
            body(&_metadata)
            try FileSecurity.writeAtomically(try Self.encode(_metadata), to: fileURL)
            return _metadata
        }
    }

    public func save() throws {
        try update { _ in }
    }

    public func url(for file: String) -> URL { directory.appendingPathComponent(file) }

    /// "2026-11-11T1000_weekly-sync" 形式のディレクトリ名
    public static func directoryName(start: Date, name: String?) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HHmm"
        var base = f.string(from: start)
        if let name, !name.isEmpty {
            base += "_" + sanitize(name)
        }
        return base
    }

    static func sanitize(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "." {
                out.unicodeScalars.append(scalar)
            } else if scalar == " " || scalar == "/" || scalar == ":" {
                out.append("-")
            }
        }
        while out.hasPrefix(".") { out.removeFirst() }
        return out.isEmpty ? "session" : String(out.prefix(80))
    }

    /// 出力先にセッションディレクトリを作る（同名があれば -2, -3 を付ける）
    public static func createDirectory(in parent: URL, start: Date, name: String?) throws -> URL {
        try FileSecurity.createPrivateDirectory(parent)
        let base = directoryName(start: start, name: name)
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileSecurity.createPrivateDirectory(candidate)
        return candidate
    }
}
