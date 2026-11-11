import Foundation

/// 送信する 1 本の音声
public struct AudioTrack: Sendable, Equatable {
    public var id: TrackID
    public var url: URL
    /// 録音開始からの先頭オフセット（ms）
    public var offsetMs: Int64
    public var durationMs: Int64?
    public var sessionID: String

    public init(id: TrackID, url: URL, offsetMs: Int64, durationMs: Int64?, sessionID: String) {
        self.id = id
        self.url = url
        self.offsetMs = offsetMs
        self.durationMs = durationMs
        self.sessionID = sessionID
    }
}

public struct TranscriptionOptions: Sendable, Equatable {
    public var language: String
    /// 話者分離を試みるか（remote / mix トラック）
    public var diarization: Bool
    public var wordTimestamps: Bool
    public var minSpeakers: Int?
    public var maxSpeakers: Int?

    public init(language: String, diarization: Bool, wordTimestamps: Bool = true,
                minSpeakers: Int? = nil, maxSpeakers: Int? = nil) {
        self.language = language
        self.diarization = diarization
        self.wordTimestamps = wordTimestamps
        self.minSpeakers = minSpeakers
        self.maxSpeakers = maxSpeakers
    }
}

public enum JobStatus: Sendable, Equatable {
    case pending
    case running(progress: Int?)
    case done
    case failed(String)
}

/// プロバイダに依存しない文字起こし結果の 1 区間
public struct Segment: Codable, Sendable, Equatable {
    public var track: TrackID
    /// 話者分離のラベル（なければ nil）
    public var speaker: String?
    public var startMs: Int64
    public var endMs: Int64
    public var text: String
    public var confidence: Double?

    public init(track: TrackID, speaker: String?, startMs: Int64, endMs: Int64, text: String, confidence: Double?) {
        self.track = track
        self.speaker = speaker
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case track, speaker, text, confidence
        case startMs = "start_ms"
        case endMs = "end_ms"
    }
}

/// 文字起こしプロバイダ。Google 以外（Gemini API、他社の音声認識など）はこれを実装して差し替える
public protocol TranscriptionProvider: Sendable {
    var name: String { get }
    var model: String? { get }
    func submit(_ track: AudioTrack, options: TranscriptionOptions) async throws -> JobHandle
    func status(of job: JobHandle) async throws -> JobStatus
    func result(of job: JobHandle) async throws -> [Segment]
    func cleanup(_ job: JobHandle) async throws
}
