import Foundation

/// 作り直す前のファイルを、作った日時を入れた名前でセッションディレクトリに残す
/// 例: summary.md → summary-20261116-103000.md、transcript.md / .json / .srt → transcript-20261116-103000.md / .json / .srt
public enum FileBackup {
    /// 名前に入れる日時（yyyyMMdd-HHmmss）
    public static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// 同じディレクトリにある、組になったファイル（同じ名前で拡張子だけ違うもの）をまとめてコピーする。
    /// 日時は、最初にある既存のファイルの更新日時（そのファイルを作った日時）を使い、組の中では揃える。
    /// 同じ名前がすでにあれば -2, -3 … を付ける。既存のファイルがなければ何もせず [] を返す
    @discardableResult
    public static func backup(_ urls: [URL], timeZone: TimeZone = .current) throws -> [URL] {
        let fm = FileManager.default
        let existing = urls.filter { fm.fileExists(atPath: $0.path) }
        guard let first = existing.first else { return [] }
        let date = (try? fm.attributesOfItem(atPath: first.path)[.modificationDate] as? Date) ?? Date()
        let suffix = stamp(date, timeZone: timeZone)
        func destination(_ url: URL, _ n: Int) -> URL {
            let stem = url.deletingPathExtension().lastPathComponent + "-" + suffix + (n > 1 ? "-\(n)" : "")
            let dest = url.deletingLastPathComponent().appendingPathComponent(stem)
            return url.pathExtension.isEmpty ? dest : dest.appendingPathExtension(url.pathExtension)
        }
        // 組のどれか 1 つでも名前が重なれば、組ごと次の番号にする
        var n = 1
        while existing.contains(where: { fm.fileExists(atPath: destination($0, n).path) }) { n += 1 }
        var out: [URL] = []
        for url in existing {
            let dest = destination(url, n)
            do {
                try fm.copyItem(at: url, to: dest)
            } catch {
                throw CappyError.io(tr("Cannot back up \(url.lastPathComponent): \(dest.path): \(error.localizedDescription)",
                                       ja: "\(url.lastPathComponent) を退避できません: \(dest.path): \(error.localizedDescription)"))
            }
            FileSecurity.makePrivate(dest)
            out.append(dest)
        }
        return out
    }
}
