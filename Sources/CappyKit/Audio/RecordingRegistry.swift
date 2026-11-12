import Darwin
import Foundation

/// 録音中の `cappy record` を別のプロセス（`cappy mic`）から見つけて操作するための登録簿。
///
/// 録音プロセスは一時ディレクトリに `record-<pid>.json` を置き、マイクのミュート状態を書き込む。
/// 操作する側は SIGUSR1（ミュート）/ SIGUSR2（解除）を送る。
/// PID の再利用で無関係なプロセスにシグナルを送らないよう、プロセスの開始時刻も記録して照合する。
public enum RecordingRegistry {
    /// ミュートを要求するシグナル
    public static let muteSignal = SIGUSR1
    /// ミュートの解除を要求するシグナル
    public static let unmuteSignal = SIGUSR2

    public struct Entry: Codable, Sendable, Equatable {
        public var pid: Int32
        /// プロセスの開始時刻（µs）。PID の再利用を見分けるのに使う
        public var processStart: UInt64
        public var session: String
        public var name: String?
        public var hasMic: Bool
        public var micMuted: Bool
        public var updatedAt: String

        public init(pid: Int32, processStart: UInt64, session: String, name: String?, hasMic: Bool, micMuted: Bool) {
            self.pid = pid
            self.processStart = processStart
            self.session = session
            self.name = name
            self.hasMic = hasMic
            self.micMuted = micMuted
            self.updatedAt = TimeFormat.iso8601(Date())
        }

        enum CodingKeys: String, CodingKey {
            case pid, session, name
            case processStart = "process_start"
            case hasMic = "has_mic"
            case micMuted = "mic_muted"
            case updatedAt = "updated_at"
        }
    }

    /// 登録簿のディレクトリ（ユーザーごとの一時ディレクトリの下。CAPPY_RUNTIME_DIR で変更可）
    public static var directory: URL {
        if let d = ProcessInfo.processInfo.environment["CAPPY_RUNTIME_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: FileSecurity.expandTilde(d), isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("cappy", isDirectory: true)
    }

    static func url(pid: Int32, in dir: URL) -> URL { dir.appendingPathComponent("record-\(pid).json") }

    /// 自分自身を登録する（状態が変わるたびに呼んで上書きする）
    public static func write(_ entry: Entry, in dir: URL = directory) throws {
        try FileSecurity.createPrivateDirectory(dir)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileSecurity.writeAtomically(try enc.encode(entry), to: url(pid: entry.pid, in: dir))
    }

    public static func remove(pid: Int32 = getpid(), in dir: URL = directory) {
        try? FileManager.default.removeItem(at: url(pid: pid, in: dir))
    }

    /// 録音中のプロセスの一覧（終了済みのものは消す）
    public static func list(in dir: URL = directory) -> [Entry] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var entries: [Entry] = []
        for f in files where f.lastPathComponent.hasPrefix("record-") && f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f), let e = try? JSONDecoder().decode(Entry.self, from: data) else { continue }
            if isAlive(e) {
                entries.append(e)
            } else {
                try? FileManager.default.removeItem(at: f)
            }
        }
        return entries.sorted { $0.pid < $1.pid }
    }

    public static func entry(pid: Int32, in dir: URL = directory) -> Entry? {
        list(in: dir).first { $0.pid == pid }
    }

    /// 登録したプロセスがまだ動いているか（PID と開始時刻の両方が一致するか）
    static func isAlive(_ e: Entry) -> Bool {
        guard e.pid > 0, let start = processStartMicros(e.pid) else { return false }
        return start == e.processStart
    }

    /// ミュート / 解除を要求する
    public static func request(muted: Bool, of e: Entry) throws {
        guard isAlive(e) else {
            throw CappyError.targetNotFound(tr("The recording (PID \(e.pid)) has already ended", ja: "録音（PID \(e.pid)）はすでに終了しています"))
        }
        guard kill(e.pid, muted ? muteSignal : unmuteSignal) == 0 else {
            throw CappyError.io(tr("Cannot send a signal to PID \(e.pid): \(String(cString: strerror(errno)))", ja: "PID \(e.pid) にシグナルを送れません: \(String(cString: strerror(errno)))"))
        }
    }

    /// プロセスの開始時刻（µs）
    public static func processStartMicros(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }
}
