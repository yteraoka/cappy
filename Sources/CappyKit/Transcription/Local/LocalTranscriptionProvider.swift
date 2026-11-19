import Foundation

/// 端末内の音声認識が返す 1 区間（ファイルの先頭からの ms）
public struct RecognizedPiece: Sendable, Equatable {
    public var startMs: Int64
    public var endMs: Int64
    public var text: String
    public var confidence: Double?

    public init(startMs: Int64, endMs: Int64, text: String, confidence: Double? = nil) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.confidence = confidence
    }
}

/// 話者分離が返す 1 区間（ファイルの先頭からの ms）
public struct SpeakerTurn: Sendable, Equatable {
    public var speaker: String
    public var startMs: Int64
    public var endMs: Int64

    public init(speaker: String, startMs: Int64, endMs: Int64) {
        self.speaker = speaker
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// 端末内の音声認識（WhisperKit / Apple SpeechTranscriber）
public protocol LocalRecognizer: Sendable {
    /// session.json の transcription.provider に記録する名前
    var name: String { get }
    var model: String? { get }
    func recognize(_ audio: URL, language: String, vocabulary: [String]) async throws -> [RecognizedPiece]
}

/// 端末内の話者分離（SpeakerKit）
public protocol LocalDiarizer: Sendable {
    func diarize(_ audio: URL, numSpeakers: Int?) async throws -> [SpeakerTurn]
}

/// 端末内で文字起こしする。外部には何も送らない。
/// submit の中で認識（と remote トラックの話者分離）まで終え、結果をセッションディレクトリの
/// local-<track>.json に置く。status はそのファイルがあれば完了、result はそれを読む
public struct LocalTranscriptionProvider: TranscriptionProvider {
    let recognizer: LocalRecognizer
    let diarizer: LocalDiarizer?
    let settings: LocalTranscribeSettings

    public var name: String { recognizer.name }
    public var model: String? { recognizer.model }

    public init(recognizer: LocalRecognizer, diarizer: LocalDiarizer?, settings: LocalTranscribeSettings) {
        self.recognizer = recognizer
        self.diarizer = diarizer
        self.settings = settings
    }

    static func resultURL(for track: AudioTrack) -> URL {
        track.url.deletingLastPathComponent().appendingPathComponent("local-\(track.id.rawValue).json")
    }

    public func submit(_ track: AudioTrack, options: TranscriptionOptions) async throws -> JobHandle {
        let started = Date()
        Console.status(tr("Recognizing \(track.id.displayName) on this Mac (\(recognizer.name))…", ja: "\(track.id.displayName) をこの Mac で認識しています（\(recognizer.name)）…"))
        let pieces = try await recognizer.recognize(track.url, language: options.language, vocabulary: settings.customVocabulary)
        CappyLog.shared.info(tr("Local recognition finished track=\(track.id.rawValue) pieces=\(pieces.count) elapsed=\(Int(Date().timeIntervalSince(started)))s",
                                ja: "端末内の認識が完了しました track=\(track.id.rawValue) pieces=\(pieces.count) elapsed=\(Int(Date().timeIntervalSince(started)))s"))
        var info: [String: String] = ["engine": recognizer.name]
        var turns: [SpeakerTurn] = []
        var diarized = false
        if options.diarization, let diarizer, !pieces.isEmpty {
            Console.status(tr("Telling the speakers apart in \(track.id.displayName) (SpeakerKit)…", ja: "\(track.id.displayName) の話者を分けています（SpeakerKit）…"))
            do {
                turns = try await diarizer.diarize(track.url, numSpeakers: settings.numSpeakers)
                diarized = true
            } catch {
                if Task.isCancelled { throw error }
                CappyLog.shared.warning(tr("Speaker diarization failed; continuing without it: \(error)", ja: "話者分離に失敗したため、話者分離なしで続けます: \(error)"))
                info["diarization_note"] = tr("Ran without speaker diarization because SpeakerKit failed: \(error)", ja: "SpeakerKit が失敗したため、話者分離なしで実行しました: \(error)")
            }
        }
        info["diarization"] = diarized ? "true" : "false"
        let segments = Self.assemble(pieces, turns: turns, track: track.id, offsetMs: track.offsetMs)
        let url = Self.resultURL(for: track)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try FileSecurity.writeAtomically(try enc.encode(segments), to: url)
        info["file"] = url.path
        Console.clearStatus()
        return JobHandle(provider: name, track: track.id, id: url.lastPathComponent, info: info)
    }

    public func status(of job: JobHandle) async throws -> JobStatus {
        guard let path = job.info["file"], FileManager.default.fileExists(atPath: path) else {
            return .failed(tr("The local recognition result is missing; run again with --force", ja: "端末内の認識結果が見つかりません。--force でやり直してください"))
        }
        return .done
    }

    public func result(of job: JobHandle) async throws -> [Segment] {
        guard let path = job.info["file"] else {
            throw CappyError.transcription(tr("The local recognition result is missing", ja: "端末内の認識結果が見つかりません"))
        }
        return try JSONDecoder().decode([Segment].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    public func cleanup(_ job: JobHandle) async throws {
        if let path = job.info["file"] { try? FileManager.default.removeItem(atPath: path) }
    }

    /// 認識の区間に話者を割り当てて Segment にする。重なりが最も長い話者、重ならなければ 1 秒以内で最も近い話者にする
    public static func assemble(_ pieces: [RecognizedPiece], turns: [SpeakerTurn], track: TrackID, offsetMs: Int64) -> [Segment] {
        pieces.compactMap { p in
            let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let end = max(p.endMs, p.startMs)
            return Segment(track: track, speaker: speaker(for: p.startMs, end, turns: turns),
                           startMs: offsetMs + p.startMs, endMs: offsetMs + end, text: text, confidence: p.confidence)
        }
    }

    static func speaker(for start: Int64, _ end: Int64, turns: [SpeakerTurn]) -> String? {
        guard !turns.isEmpty else { return nil }
        var overlap: [String: Int64] = [:]
        for t in turns {
            let o = min(end, t.endMs) - max(start, t.startMs)
            if o > 0 { overlap[t.speaker, default: 0] += o }
        }
        if let best = overlap.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) { return best.key }
        let mid = (start + end) / 2
        let nearest = turns.min { distance(mid, $0) < distance(mid, $1) }
        guard let n = nearest, distance(mid, n) <= 1000 else { return nil }
        return n.speaker
    }

    private static func distance(_ t: Int64, _ turn: SpeakerTurn) -> Int64 {
        if t < turn.startMs { return turn.startMs - t }
        if t > turn.endMs { return t - turn.endMs }
        return 0
    }
}
