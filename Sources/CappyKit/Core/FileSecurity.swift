import Foundation

/// セッションディレクトリは 0700、ファイルは 0600 で作成する
public enum FileSecurity {
    /// プロセス全体の umask を 077 にする（AVAudioFile などが作るファイルも 0600 になる）
    public static func restrictUmask() {
        umask(0o077)
    }

    public static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public static func makePrivate(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 一時ファイルに書いて rename することで、途中で落ちても壊れたファイルを残さない
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try data.write(to: tmp)
        if rename(tmp.path, url.path) != 0 {
            let err = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: tmp)
            throw CappyError.io(tr("Cannot write the file: \(url.path): \(err)", ja: "ファイルを書き込めません: \(url.path): \(err)"))
        }
        makePrivate(url)
    }

    public static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// 空き容量（バイト）
    public static func availableBytes(at url: URL) -> Int64? {
        var st = statfs()
        guard statfs(url.path, &st) == 0 else { return nil }
        return Int64(st.f_bavail) * Int64(st.f_bsize)
    }
}
