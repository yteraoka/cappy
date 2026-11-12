import ArgumentParser
import CappyKit
import Foundation

/// 録音中の `cappy record` のマイクを別のターミナルやショートカットから on / off する
struct Mic: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("Mute or unmute the microphone of a running `cappy record`", ja: "録音中の `cappy record` のマイクをミュート / 解除する"),
        discussion: tr("""
        While muted, the mic track is recorded as silence (the timeline is kept), so it is neither saved nor transcribed.
        Use this to follow the mute state of the meeting app, e.g. bind `cappy mic toggle` to a hotkey
        (Shortcuts, Raycast, Hammerspoon, …) together with the meeting app's mute shortcut.
        In the terminal running `cappy record`, pressing Space (with nothing typed) also toggles the mute.

        Examples:
          cappy mic            # show the state
          cappy mic off        # mute
          cappy mic on         # unmute
          cappy mic toggle
        """, ja: """
        ミュート中はマイクのトラックを無音で記録します（時刻はずれません）。その間の音声は保存も文字起こしもされません。
        会議アプリのミュートに合わせるために使います。たとえば `cappy mic toggle` を会議アプリのミュートのショートカットと一緒に
        ホットキー（ショートカット.app・Raycast・Hammerspoon など）に割り当てます。
        `cappy record` を実行しているターミナルで、何も入力していないときに Space を押しても切り替えられます。

        例:
          cappy mic            # 状態を表示
          cappy mic off        # ミュート
          cappy mic on         # ミュートを解除
          cappy mic toggle
        """)
    )

    enum Action: String, ExpressibleByArgument, CaseIterable {
        case status, on, off, toggle
    }

    @Argument(help: ArgumentHelp(tr("status (default) / on (unmute) / off (mute) / toggle", ja: "status（既定）/ on（解除）/ off（ミュート）/ toggle")))
    var action: Action = .status

    @Option(help: ArgumentHelp(tr("PID of the `cappy record` to control (required for toggle when several recordings are running)", ja: "操作する `cappy record` の PID（複数録音中の toggle では必須）")),
            completion: .custom { _, _, _ in RecordingRegistry.list().map { String($0.pid) } })
    var pid: Int32?

    func run() async throws {
        var entries = RecordingRegistry.list()
        if let pid { entries = entries.filter { $0.pid == pid } }
        guard !entries.isEmpty else {
            throw CappyError.targetNotFound(
                pid.map { tr("No recording with PID \($0) is running", ja: "PID \($0) の録音は実行されていません") }
                    ?? tr("No recording is running", ja: "録音中の cappy record がありません"),
                hint: tr("Start recording with `cappy record`", ja: "`cappy record` で録音を始めてください"))
        }
        if action == .status {
            for e in entries { Console.print(Self.describe(e)) }
            return
        }
        if action == .toggle && entries.count > 1 {
            let pids = entries.map { String($0.pid) }.joined(separator: ", ")
            throw CappyError.usage(tr("Several recordings are running (PID \(pids)). Specify one with --pid", ja: "複数の録音が実行中です（PID \(pids)）。--pid で指定してください"))
        }
        var failed = false
        for e in entries {
            guard e.hasMic else {
                Console.print(tr("PID \(e.pid): the microphone is not being recorded", ja: "PID \(e.pid): マイクを録音していません"))
                failed = true
                continue
            }
            let muted: Bool
            switch action {
            case .off: muted = true
            case .on: muted = false
            default: muted = !e.micMuted
            }
            try RecordingRegistry.request(muted: muted, of: e)
            // 録音プロセスが登録簿を更新するのを待って、反映後の状態を表示する
            var latest = e
            for _ in 0..<30 {
                if let cur = RecordingRegistry.entry(pid: e.pid) {
                    latest = cur
                    if cur.micMuted == muted { break }
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            Console.print(Self.describe(latest))
            if latest.micMuted != muted { failed = true }
        }
        if failed { throw ExitCode(ExitStatus.io.rawValue) }
    }

    static func describe(_ e: RecordingRegistry.Entry) -> String {
        let state = !e.hasMic ? tr("not recorded", ja: "録音していません")
            : e.micMuted ? tr("🔇 muted", ja: "🔇 ミュート中") : tr("🎙 on", ja: "🎙 オン")
        return tr("PID \(e.pid)  mic: \(state)  \(e.session)", ja: "PID \(e.pid)  マイク: \(state)  \(e.session)")
    }
}

/// `cappy record` 側のマイクのミュート操作（キー入力・シグナル・登録簿をまとめる）
final class MicMuteController: @unchecked Sendable {
    private let recorder: Recorder
    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []
    private var entry: RecordingRegistry.Entry?
    private var stopped = false

    init(recorder: Recorder) {
        self.recorder = recorder
    }

    var hasMic: Bool { recorder.hasMicTrack }

    /// シグナルの受け口を用意してから登録簿に載せる（順序が逆だと既定の動作でプロセスが終了しうる）
    func start(session: URL, name: String?) {
        for sig in [RecordingRegistry.muteSignal, RecordingRegistry.unmuteSignal] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { [weak self] in self?.set(sig == RecordingRegistry.muteSignal, announceUnchanged: false) }
            src.resume()
            sources.append(src)
        }
        let e = RecordingRegistry.Entry(pid: getpid(), processStart: RecordingRegistry.processStartMicros(getpid()) ?? 0,
                                        session: session.path, name: name, hasMic: hasMic, micMuted: recorder.isMicMuted)
        lock.withLock { entry = e }
        publish()
    }

    func toggle() {
        set(!recorder.isMicMuted, announceUnchanged: true)
    }

    func set(_ muted: Bool, announceUnchanged: Bool) {
        let changed: Bool = lock.withLock {
            guard !stopped else { return false }
            guard hasMic else { return false }
            let before = recorder.isMicMuted
            recorder.setMicMuted(muted)
            return before != muted
        }
        guard hasMic else {
            Console.print(tr("The microphone is not being recorded", ja: "マイクを録音していません"))
            return
        }
        guard changed || announceUnchanged else { return }
        let at = TimeFormat.elapsed(recorder.status().elapsed)
        Console.print(muted ? tr("🔇 Mic muted (\(at))", ja: "🔇 マイクをミュートしました（\(at)）")
                            : tr("🎙 Mic unmuted (\(at))", ja: "🎙 マイクのミュートを解除しました（\(at)）"))
        if changed { publish() }
    }

    private func publish() {
        lock.withLock {
            guard !stopped, var e = entry else { return }
            e.micMuted = recorder.isMicMuted
            e.updatedAt = TimeFormat.iso8601(Date())
            entry = e
            do {
                try RecordingRegistry.write(e)
            } catch {
                CappyLog.shared.warning(tr("Cannot write the recording registry (`cappy mic` will not find this recording): \(error)", ja: "録音の登録簿を書けません（`cappy mic` から操作できません）: \(error)"))
            }
        }
    }

    /// 録音の停止後に呼ぶ。以後のシグナルは無視する
    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            sources.forEach { $0.cancel() }
            sources.removeAll()
            RecordingRegistry.remove()
        }
    }
}
