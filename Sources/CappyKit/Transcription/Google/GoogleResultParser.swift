import Foundation

/// Speech-to-Text v2 の BatchRecognizeResults（JSON）を共通形式の Segment に変換する
public enum GoogleResultParser {
    /// "1.500s" / {"seconds": "1", "nanos": 500000000} を ms に
    public static func durationMs(_ value: Any?) -> Int64? {
        if let s = value as? String {
            let trimmed = s.hasSuffix("s") ? String(s.dropLast()) : s
            guard let d = Double(trimmed) else { return nil }
            return Int64((d * 1000).rounded())
        }
        if let d = value as? [String: Any] {
            let secs: Double
            if let s = d["seconds"] as? String { secs = Double(s) ?? 0 } else { secs = (d["seconds"] as? NSNumber)?.doubleValue ?? 0 }
            let nanos = (d["nanos"] as? NSNumber)?.doubleValue ?? 0
            return Int64((secs * 1000 + nanos / 1e6).rounded())
        }
        if let n = value as? NSNumber { return Int64((n.doubleValue * 1000).rounded()) }
        return nil
    }

    /// camelCase と snake_case のどちらでも取り出す
    static func field(_ obj: [String: Any], _ camel: String) -> Any? {
        if let v = obj[camel] { return v }
        var snake = ""
        for ch in camel {
            if ch.isUppercase { snake += "_" + ch.lowercased() } else { snake.append(ch) }
        }
        return obj[snake]
    }

    /// 単語を区切りなしで連結する言語（日本語・中国語・タイ語など）
    static func joiner(for language: String) -> String {
        let l = language.lowercased()
        for p in ["ja", "zh", "cmn", "yue", "th", "lo", "my", "km"] where l == p || l.hasPrefix(p + "-") {
            return ""
        }
        return " "
    }

    public static func segments(fromJSON data: Data, track: TrackID, offsetMs: Int64, language: String) throws -> [Segment] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CappyError.transcription(tr("Invalid recognition result JSON", ja: "認識結果の JSON が不正です"))
        }
        let results = field(root, "results") as? [[String: Any]] ?? []
        return segments(fromResults: results, track: track, offsetMs: offsetMs, language: language)
    }

    public static func segments(fromResults results: [[String: Any]], track: TrackID, offsetMs: Int64, language: String) -> [Segment] {
        let sep = joiner(for: language)
        var out: [Segment] = []
        var prevEnd: Int64 = 0
        for r in results {
            guard let alt = (field(r, "alternatives") as? [[String: Any]])?.first else { continue }
            let transcript = (field(alt, "transcript") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let altConf = (field(alt, "confidence") as? NSNumber)?.doubleValue
            let words = field(alt, "words") as? [[String: Any]] ?? []
            let resultEnd = durationMs(field(r, "resultEndOffset"))

            struct W { var text: String; var start: Int64?; var end: Int64?; var speaker: String?; var conf: Double? }
            let ws: [W] = words.map { w in
                let label = (field(w, "speakerLabel") as? String) ?? (field(w, "speakerTag") as? NSNumber)?.stringValue
                return W(text: field(w, "word") as? String ?? "",
                         start: durationMs(field(w, "startOffset")),
                         end: durationMs(field(w, "endOffset")),
                         speaker: (label?.isEmpty ?? true) ? nil : label,
                         conf: (field(w, "confidence") as? NSNumber)?.doubleValue)
            }
            let start0 = ws.first?.start ?? prevEnd
            let end0 = resultEnd ?? ws.last?.end ?? start0
            defer { prevEnd = max(prevEnd, end0) }
            guard !transcript.isEmpty || !ws.isEmpty else { continue }

            let hasSpeakers = ws.contains { $0.speaker != nil }
            let hasOffsets = ws.contains { $0.start != nil }
            if hasSpeakers && hasOffsets {
                // 話者が変わるところで区切る
                var group: [W] = []
                func flush() {
                    guard !group.isEmpty else { return }
                    let text = group.map(\.text).joined(separator: sep).trimmingCharacters(in: .whitespaces)
                    let confs = group.compactMap(\.conf)
                    if !text.isEmpty {
                        out.append(Segment(track: track, speaker: group[0].speaker,
                                           startMs: offsetMs + (group.first?.start ?? start0),
                                           endMs: offsetMs + (group.last?.end ?? group.last?.start ?? end0),
                                           text: text,
                                           confidence: confs.isEmpty ? altConf : confs.reduce(0, +) / Double(confs.count)))
                    }
                    group = []
                }
                for w in ws {
                    if let last = group.last, last.speaker != w.speaker { flush() }
                    group.append(w)
                }
                flush()
                continue
            }
            var speaker: String?
            if hasSpeakers {
                // 時刻がない場合は最も多い話者に寄せる
                let counts = Dictionary(grouping: ws.compactMap(\.speaker), by: { $0 }).mapValues(\.count)
                speaker = counts.max { $0.value < $1.value }?.key
            }
            let text = transcript.isEmpty ? ws.map(\.text).joined(separator: sep) : transcript
            let start = hasOffsets ? (ws.first?.start ?? start0) : prevEnd
            let end = hasOffsets ? max(ws.last?.end ?? end0, start) : max(end0, start)
            out.append(Segment(track: track, speaker: speaker, startMs: offsetMs + start, endMs: offsetMs + end,
                               text: text, confidence: altConf))
        }
        return out
    }
}
