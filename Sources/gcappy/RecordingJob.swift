import CappyKit
import Darwin
import Foundation

/// gcappy が起動した 1 回分の `cappy record`。
///
/// 子プロセスの出力はログファイルに直接書かせる（パイプにすると gcappy を終了したときに SIGPIPE で止まるため）。
/// 録音中かどうかは登録簿（RecordingRegistry）で判断する。cappy は録音を始めると登録し、
/// 録音を止めた時点（文字起こし・要約の前）で登録を消す。
@MainActor
final class RecordingJob {
    enum Phase: Equatable {
        /// 起動直後（権限の確認や録音対象の解決中）
        case starting
        case recording
        /// 録音を止めた後の変換・文字起こし・要約
        case processing
        case finished(status: Int32)
    }

    let target: LaunchTarget
    let name: String?
    let profileName: String
    let operation: LaunchOperation
    let logURL: URL
    let launchedAt: Date
    private let process = Process()

    private(set) var pid: Int32 = 0
    /// 登録簿の最新の内容（録音中だけある）
    private(set) var entry: RecordingRegistry.Entry?
    private(set) var recordingStartedAt: Date?
    private(set) var recordingEndedAt: Date?
    private(set) var sessionDirectory: URL?
    private(set) var exitStatus: Int32?
    private(set) var stopRequested = false
    private(set) var processingCancelled = false
    private var onExit: (@MainActor (RecordingJob) -> Void)?

    var phase: Phase {
        if let exitStatus { return .finished(status: exitStatus) }
        if entry != nil { return .recording }
        return recordingStartedAt == nil ? .starting : .processing
    }

    var isRunning: Bool { exitStatus == nil }

    /// 録音している時間
    var elapsed: TimeInterval {
        guard let start = recordingStartedAt else { return 0 }
        return (recordingEndedAt ?? Date()).timeIntervalSince(start)
    }

    init(executable: URL, arguments: [String], environment: [String: String], target: LaunchTarget, name: String?,
         profileName: String, operation: LaunchOperation, onExit: @escaping @MainActor (RecordingJob) -> Void) throws {
        self.target = target
        self.name = name
        self.profileName = profileName
        self.operation = operation
        self.onExit = onExit
        let now = Date()
        launchedAt = now

        let fm = FileManager.default
        try FileSecurity.createPrivateDirectory(AppEnvironment.logDirectory)
        let stamp = Self.stampFormatter.string(from: now)
        let logURL = AppEnvironment.logDirectory.appendingPathComponent("record-\(stamp).log")
        self.logURL = logURL
        let header = "$ \(([executable.path] + arguments).map(Self.shellQuote).joined(separator: " "))\n\n"
        guard fm.createFile(atPath: logURL.path, contents: Data(header.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CappyError.io(tr("Cannot create the log file: \(logURL.path)", ja: "ログファイルを作成できません: \(logURL.path)"))
        }
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        _ = try log.seekToEnd()

        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = fm.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [self] p in
            let status = p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
            Task { @MainActor in self.didExit(status: status) }
        }
        try process.run()
        pid = process.processIdentifier
    }

    /// 登録簿を読み直す（定期的に呼ぶ）
    func refresh() {
        guard exitStatus == nil else { return }
        let e = RecordingRegistry.entry(pid: pid)
        if let e {
            if recordingStartedAt == nil { recordingStartedAt = Date() }
            sessionDirectory = URL(fileURLWithPath: e.session, isDirectory: true)
        } else if entry != nil {
            recordingEndedAt = Date()
        }
        entry = e
    }

    private func didExit(status: Int32) {
        refresh()
        entry = nil
        if recordingStartedAt != nil && recordingEndedAt == nil { recordingEndedAt = Date() }
        exitStatus = status
        process.terminationHandler = nil
        if sessionDirectory == nil { sessionDirectory = Self.sessionDirectory(fromLog: logURL) }
        let handler = onExit
        onExit = nil
        handler?(self)
    }

    /// 録音を止める（Ctrl-C と同じ。続けて送信用ファイルの作成・文字起こし・要約に進む）
    func stop() {
        guard isRunning else { return }
        stopRequested = true
        kill(pid, SIGINT)
    }

    /// 録音後の処理を中断する（再開は `cappy transcribe <dir>`）
    func cancelProcessing() {
        guard isRunning else { return }
        processingCancelled = true
        kill(pid, SIGINT)
    }

    var canMute: Bool { entry?.hasMic ?? false }
    var isMuted: Bool { entry?.micMuted ?? false }

    func setMuted(_ muted: Bool) throws {
        guard let entry = RecordingRegistry.entry(pid: pid) else { return }
        try RecordingRegistry.request(muted: muted, of: entry)
    }

    func requestScreenshot() throws {
        guard let entry = RecordingRegistry.entry(pid: pid) else { return }
        try RecordingRegistry.requestScreenshot(of: entry)
    }

    /// ログの末尾（エラーの表示用。端末の制御文字は取り除く）
    func logTail(lines: Int = 12) -> String {
        Self.tail(of: logURL, lines: lines)
    }

    static func tail(of url: URL, lines: Int) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        let text = String(decoding: data.suffix(16 * 1024), as: UTF8.self)
        let cleaned = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "\n")
        let rows = cleaned.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return rows.suffix(lines).joined(separator: "\n")
    }

    /// 録音を始める前に終わった場合など、登録簿から分からなかったときは出力からセッションディレクトリを探す
    static func sessionDirectory(fromLog url: URL) -> URL? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            for prefix in ["Recording started: ", "録音を開始しました: "] {
                if let r = line.range(of: prefix) {
                    let path = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                        return URL(fileURLWithPath: path, isDirectory: true)
                    }
                }
            }
        }
        return nil
    }

    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:,+@%".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
