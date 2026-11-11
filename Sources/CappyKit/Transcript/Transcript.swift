import Foundation

/// transcript.json（プロバイダに依存しない形式）
public struct TranscriptDocument: Codable, Sendable, Equatable {
    public var sessionID: String
    public var name: String?
    public var startedAt: String?
    public var provider: String
    public var model: String?
    public var language: String
    public var mix: Bool
    /// トラックごとに話者分離が有効だったか
    public var diarization: [String: Bool]
    public var generatedAt: String
    public var toolVersion: String
    public var segments: [Segment]

    public init(sessionID: String, name: String?, startedAt: String?, provider: String, model: String?,
                language: String, mix: Bool, diarization: [String: Bool], segments: [Segment],
                generatedAt: String = TimeFormat.iso8601(Date())) {
        self.sessionID = sessionID
        self.name = name
        self.startedAt = startedAt
        self.provider = provider
        self.model = model
        self.language = language
        self.mix = mix
        self.diarization = diarization
        self.generatedAt = generatedAt
        self.toolVersion = CappyVersion.current
        self.segments = segments
    }

    enum CodingKeys: String, CodingKey {
        case name, provider, model, language, mix, diarization, segments
        case sessionID = "session_id"
        case startedAt = "started_at"
        case generatedAt = "generated_at"
        case toolVersion = "tool_version"
    }
}

public enum TranscriptFormat: String, CaseIterable, Sendable {
    case md, json, srt

    public var fileName: String { fileName(base: "transcript") }

    public func fileName(base: String) -> String { "\(base).\(rawValue)" }

    public static func parseList(_ s: String) throws -> [TranscriptFormat] {
        var out: [TranscriptFormat] = []
        for part in s.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !part.isEmpty {
            guard let f = TranscriptFormat(rawValue: part == "markdown" ? "md" : part) else {
                throw CappyError.usage(tr("Invalid output format: \(part) (md, json, srt)", ja: "出力形式が不正です: \(part)（md, json, srt）"))
            }
            if !out.contains(f) { out.append(f) }
        }
        guard !out.isEmpty else { throw CappyError.usage(tr("Specify at least one output format (md, json, srt)", ja: "出力形式を 1 つ以上指定してください（md, json, srt）")) }
        return out
    }
}

public enum TranscriptMerger {
    /// トラック単位の結果を時刻順にマージする
    public static func merge(_ perTrack: [[Segment]]) -> [Segment] {
        perTrack.flatMap { $0 }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { a, b in
                if a.startMs != b.startMs { return a.startMs < b.startMs }
                if a.track != b.track { return a.track < b.track }
                return a.endMs < b.endMs
            }
    }
}

/// 表示用の話者名（mic は「自分」、remote は「相手」／話者分離があれば「相手 1」「相手 2」）。
/// 英語では Me / Remote / Remote 1
public struct SpeakerNaming: Sendable {
    private var numbers: [TrackID: [String: Int]] = [:]
    public let language: UILanguage

    public init(segments: [Segment], language: UILanguage) {
        self.language = language
        for s in segments {
            guard let sp = s.speaker else { continue }
            var map = numbers[s.track] ?? [:]
            if map[sp] == nil { map[sp] = map.count + 1 }
            numbers[s.track] = map
        }
    }

    public func label(for s: Segment) -> String {
        let base = s.track.label(language)
        guard s.track != .mic, let sp = s.speaker, let map = numbers[s.track], map.count > 1, let n = map[sp] else {
            return base
        }
        return "\(base) \(n)"
    }
}

public enum TranscriptRenderer {
    public static func json(_ doc: TranscriptDocument) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(doc)
    }

    /// transcript.md。見出しや話者名は会議の言語（doc.language）で書く
    public static func markdown(_ doc: TranscriptDocument, timeZone: TimeZone = .current) -> String {
        let L = UILanguage.forDocument(doc.language)
        let naming = SpeakerNaming(segments: doc.segments, language: L)
        var lines: [String] = []
        lines.append("# \(doc.name?.isEmpty == false ? doc.name! : doc.sessionID)")
        lines.append("")
        if let s = doc.startedAt, let d = TimeFormat.parseISO8601(s) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = "yyyy-MM-dd HH:mm"
            lines.append(tr(L, "- Recording started: ", ja: "- 録音開始: ") + f.string(from: d))
        }
        if let last = doc.segments.map(\.endMs).max() {
            lines.append(tr(L, "- Length: ", ja: "- 長さ: ") + TimeFormat.hms(ms: last))
        }
        lines.append(tr(L, "- Transcription: ", ja: "- 文字起こし: ")
            + "\(doc.provider)\(doc.model.map { " / \($0)" } ?? "") / \(doc.language)"
            + (doc.mix ? tr(L, " (mixed)", ja: "（ミックス）") : ""))
        lines.append("")
        for s in doc.segments {
            lines.append("**[\(TimeFormat.hms(ms: s.startMs))] \(naming.label(for: s))**: \(s.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func srt(_ doc: TranscriptDocument) -> String {
        let naming = SpeakerNaming(segments: doc.segments, language: UILanguage.forDocument(doc.language))
        var out = ""
        for (i, s) in doc.segments.enumerated() {
            let end = max(s.endMs, s.startMs + 500)
            out += "\(i + 1)\n\(TimeFormat.srt(ms: s.startMs)) --> \(TimeFormat.srt(ms: end))\n"
            out += "\(naming.label(for: s)): \(s.text)\n\n"
        }
        return out
    }

    /// 指定形式でセッションディレクトリに書き出す
    @discardableResult
    public static func write(_ doc: TranscriptDocument, formats: [TranscriptFormat], to directory: URL,
                             baseName: String = "transcript") throws -> [URL] {
        var urls: [URL] = []
        for f in formats {
            let url = directory.appendingPathComponent(f.fileName(base: baseName))
            let data: Data
            switch f {
            case .json: data = try json(doc)
            case .md: data = Data(markdown(doc).utf8)
            case .srt: data = Data(srt(doc).utf8)
            }
            try FileSecurity.writeAtomically(data, to: url)
            urls.append(url)
        }
        return urls
    }
}
