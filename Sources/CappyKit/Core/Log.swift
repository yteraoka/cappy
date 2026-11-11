import Foundation
import os

/// 統合ログ（サブシステム dev.cappy）と cappy.log の両方に出すロガー。
/// 文字起こし本文や音声の内容は出さない（イベント・時刻・エラーのみ）。
public final class CappyLog: @unchecked Sendable {
    public enum Level: String, Sendable { case debug = "DEBUG", info = "INFO", warning = "WARN", error = "ERROR" }

    public static let shared = CappyLog()

    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private let osLog = Logger(subsystem: "dev.cappy", category: "cli")
    private var _verbose = false

    public var verbose: Bool {
        get { lock.withLock { _verbose } }
        set { lock.withLock { _verbose = newValue } }
    }

    private init() {}

    /// セッションディレクトリの cappy.log に追記を開始する
    public func attach(sessionDirectory: URL) {
        let url = sessionDirectory.appendingPathComponent("cappy.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        lock.withLock {
            try? fileHandle?.close()
            fileHandle = try? FileHandle(forWritingTo: url)
            _ = try? fileHandle?.seekToEnd()
        }
    }

    public func detach() {
        lock.withLock {
            try? fileHandle?.close()
            fileHandle = nil
        }
    }

    public func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        write(.debug, message())
    }

    public func info(_ message: @autoclosure () -> String) { write(.info, message()) }
    public func warning(_ message: @autoclosure () -> String) { write(.warning, message()) }
    public func error(_ message: @autoclosure () -> String) { write(.error, message()) }

    private func write(_ level: Level, _ message: String) {
        switch level {
        case .debug: osLog.debug("\(message, privacy: .public)")
        case .info: osLog.info("\(message, privacy: .public)")
        case .warning: osLog.warning("\(message, privacy: .public)")
        case .error: osLog.error("\(message, privacy: .public)")
        }
        let line = "\(TimeFormat.iso8601(Date())) [\(level.rawValue)] \(message)\n"
        lock.withLock {
            if let fh = fileHandle, let data = line.data(using: .utf8) {
                try? fh.write(contentsOf: data)
            }
        }
    }
}

/// ターミナルへの表示（stderr）
public enum Console {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var statusLineActive = false

    public static var isTTY: Bool { isatty(STDERR_FILENO) != 0 }

    public static func print(_ message: String) {
        lock.withLock {
            if statusLineActive {
                FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
                statusLineActive = false
            }
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    }

    /// 同じ行を上書きするステータス表示（TTY のみ）
    public static func status(_ message: String) {
        guard isTTY else { return }
        lock.withLock {
            FileHandle.standardError.write(Data("\r\u{1B}[2K\(message)".utf8))
            statusLineActive = true
        }
    }

    public static func clearStatus() {
        lock.withLock {
            if statusLineActive {
                FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
                statusLineActive = false
            }
        }
    }
}
