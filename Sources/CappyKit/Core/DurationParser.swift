import Foundation

/// "90m", "1h30m", "45s", "1h", "3600"（秒）などの時間指定を秒数に変換する
public enum DurationParser {
    public static func parse(_ text: String) throws -> TimeInterval {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { throw CappyError.usage("時間指定が空です") }
        if let plain = Double(s) {
            guard plain > 0 else { throw CappyError.usage("時間指定は正の値にしてください: \(text)") }
            return plain
        }
        var total: Double = 0
        var number = ""
        var sawUnit = false
        for ch in s {
            if ch.isNumber || ch == "." {
                number.append(ch)
                continue
            }
            guard let value = Double(number) else {
                throw CappyError.usage("時間指定を解釈できません: \(text)（例: 90m, 1h30m, 45s）")
            }
            switch ch {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default:
                throw CappyError.usage("時間指定の単位が不正です: \(text)（h, m, s を使用）")
            }
            number = ""
            sawUnit = true
        }
        if !number.isEmpty {
            // 単位なしの末尾は秒とみなす（"1h30" → 1h + 30s ではなく誤りにする）
            throw CappyError.usage("時間指定の末尾に単位がありません: \(text)")
        }
        guard sawUnit, total > 0 else {
            throw CappyError.usage("時間指定を解釈できません: \(text)")
        }
        return total
    }
}

public enum TimeFormat {
    /// ミリ秒を HH:MM:SS に整形
    public static func hms(ms: Int64) -> String {
        let total = max(0, ms) / 1000
        return String(format: "%02lld:%02lld:%02lld", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// SRT 形式の時刻（HH:MM:SS,mmm）
    public static func srt(ms: Int64) -> String {
        let v = max(0, ms)
        let h = v / 3_600_000
        let m = (v % 3_600_000) / 60_000
        let s = (v % 60_000) / 1000
        let milli = v % 1000
        return String(format: "%02lld:%02lld:%02lld,%03lld", h, m, s, milli)
    }

    public static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    public static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// 経過秒を "1:02:03" / "02:03" 形式に
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let t = Int(seconds)
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) }
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}
