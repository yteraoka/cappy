import CappyKit
import Darwin
import Foundation

/// GUI アプリとして起動したときの環境の調整。
///
/// Finder や Dock、ログイン項目から起動したアプリには、シェルで設定した PATH や AWS_PROFILE、
/// GOOGLE_APPLICATION_CREDENTIALS などが渡らない。cappy は `aws` コマンドや認証情報の環境変数を使うため、
/// 起動時にログインシェルの環境を一度だけ読み、子プロセスの cappy に渡す。
enum AppEnvironment {
    /// 子プロセス（cappy）に渡す環境変数
    nonisolated(unsafe) private(set) static var childEnvironment: [String: String] = ProcessInfo.processInfo.environment

    /// 自分自身にも反映する環境変数（設定ファイルや登録簿の場所を子の cappy と揃える）
    static let sharedKeys: Set<String> = ["CAPPY_CONFIG", "CAPPY_RUNTIME_DIR", "CAPPY_LANG", "XDG_CONFIG_HOME"]

    static func prepare() {
        var env = ProcessInfo.processInfo.environment
        // ターミナルから実行ファイルを直接起動した場合（開発中の swift run gcappy など）は、すでにシェルの環境を持っている
        let fromTerminal = env["TERM_PROGRAM"] != nil && env["SHLVL"] != nil
        if !fromTerminal, let login = LoginShell.environment() {
            for (k, v) in login where !ignoredKeys.contains(k) && !k.hasPrefix("__CF") && !k.hasPrefix("XPC_") {
                env[k] = v
            }
            for k in sharedKeys {
                if let v = login[k], !v.isEmpty { setenv(k, v, 1) }
            }
        }
        env["PATH"] = augmentedPath(env["PATH"])

        // GUI では LANG などが渡らないことが多いので、CAPPY_LANG がなければ macOS の優先言語に合わせる
        // （子の cappy にも同じ言語を渡す。作るファイルの言語はプロファイルの language で決まる）
        if (ProcessInfo.processInfo.environment["CAPPY_LANG"] ?? "").isEmpty {
            let preferred = Locale.preferredLanguages.first ?? "en"
            setenv("CAPPY_LANG", preferred.lowercased().hasPrefix("ja") ? "ja" : "en", 1)
        }
        env["CAPPY_LANG"] = ProcessInfo.processInfo.environment["CAPPY_LANG"]
        childEnvironment = env
    }

    /// ログインシェルの値で上書きしないもの（このプロセスやシェル自身に固有の値）
    private static let ignoredKeys: Set<String> = ["_", "PWD", "OLDPWD", "SHLVL", "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
                                                   "TERM_SESSION_ID", "COLUMNS", "LINES", "TMPDIR"]

    /// PATH の後ろに Homebrew などの場所を足す（`aws` コマンドを見つけられるように）
    static func augmentedPath(_ path: String?) -> String {
        var parts = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for extra in ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                      home + "/.local/bin"] where !parts.contains(extra) {
            parts.append(extra)
        }
        return parts.joined(separator: ":")
    }

    /// 同梱の cappy（gcappy.app/Contents/MacOS/cappy）。開発中（swift run gcappy）は同じディレクトリの cappy、
    /// それもなければ CAPPY_BIN か PATH の cappy を使う
    static var cappyExecutable: URL? {
        let fm = FileManager.default
        if let u = Bundle.main.url(forAuxiliaryExecutable: "cappy"), fm.isExecutableFile(atPath: u.path) { return u }
        if let exe = Bundle.main.executableURL {
            let sibling = exe.deletingLastPathComponent().appendingPathComponent("cappy")
            if fm.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        if let bin = childEnvironment["CAPPY_BIN"], !bin.isEmpty, fm.isExecutableFile(atPath: FileSecurity.expandTilde(bin)) {
            return URL(fileURLWithPath: FileSecurity.expandTilde(bin))
        }
        for dir in (childEnvironment["PATH"] ?? "").split(separator: ":") {
            let p = URL(fileURLWithPath: String(dir)).appendingPathComponent("cappy")
            if fm.isExecutableFile(atPath: p.path) { return p }
        }
        return nil
    }

    /// 子プロセスのログを置くディレクトリ（~/Library/Logs/gcappy）
    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/gcappy", isDirectory: true)
    }

    /// 古いログ（30 日より前）を消す
    static func pruneLogs(olderThan days: Int = 30) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let limit = Date().addingTimeInterval(-TimeInterval(days) * 86400)
        for f in files where f.pathExtension == "log" {
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < limit {
                try? fm.removeItem(at: f)
            }
        }
    }
}

/// ログインシェル（$SHELL -l -i）の環境変数を読む
enum LoginShell {
    static let marker = "__GCAPPY_ENV_BEGIN__"

    static func environment(timeout: TimeInterval = 5) -> [String: String]? {
        let shell = userShell()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        // .zshrc などが標準出力に何か書いても区別できるように、目印の後ろの env -0 の出力だけを使う
        p.arguments = ["-l", "-i", "-c", "printf '%s\\0' \(marker); /usr/bin/env -0"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return nil
        }
        let pid = p.processIdentifier
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            // 終わらないシェル（入力待ちなど）は止める
            if RecordingRegistry.processStartMicros(pid) != nil { kill(pid, SIGKILL) }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(data)
    }

    static func parse(_ data: Data) -> [String: String]? {
        let entries = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard let start = entries.lastIndex(where: { $0.hasSuffix(marker) }) else { return nil }
        var env: [String: String] = [:]
        for e in entries[(start + 1)...] {
            guard let eq = e.firstIndex(of: "="), eq != e.startIndex else { continue }
            env[String(e[..<eq])] = String(e[e.index(after: eq)...])
        }
        return env.isEmpty ? nil : env
    }

    /// ユーザーのログインシェル（$SHELL、なければ passwd の値、それもなければ zsh）
    static func userShell() -> String {
        if let s = ProcessInfo.processInfo.environment["SHELL"], !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) { return s }
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        return "/bin/zsh"
    }
}
