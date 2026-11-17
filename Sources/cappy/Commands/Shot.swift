import ArgumentParser
import CappyKit
import Foundation

/// 録音中の `cappy record` に、録音対象のウインドウのスクリーンショットを撮らせる
struct Shot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("Take a screenshot of the recording target's window during `cappy record`", ja: "録音中の `cappy record` に、録音対象のウインドウのスクリーンショットを撮らせる"),
        discussion: tr("""
        The screenshot is saved in screenshots/ of the session directory, and its time from the start of the recording
        is written to session.json. The largest visible window of the recording target app is captured
        (with --system, the whole main display). Screen recording permission is needed for the terminal app.
        In the terminal running `cappy record`, pressing s (with nothing typed) also takes a screenshot.
        Bind `cappy shot` to a hotkey (Shortcuts, Raycast, Hammerspoon, …) to take one without switching to the terminal.

        Examples:
          cappy shot
          cappy shot --pid 12345
        """, ja: """
        スクリーンショットはセッションディレクトリの screenshots/ に保存し、録音開始からの時刻を session.json に記録します。
        録音対象のアプリの、画面に表示中で一番大きいウインドウを撮ります（--system のときはメインディスプレイ全体）。
        実行元のターミナルアプリに画面収録の許可が必要です。
        `cappy record` を実行しているターミナルで、何も入力していないときに s を押しても撮れます。
        `cappy shot` をホットキー（ショートカット.app・Raycast・Hammerspoon など）に割り当てると、ターミナルに切り替えずに撮れます。

        例:
          cappy shot
          cappy shot --pid 12345
        """)
    )

    @Option(help: ArgumentHelp(tr("PID of the `cappy record` (required when several recordings are running)", ja: "対象の `cappy record` の PID（複数録音中は必須）")),
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
        guard entries.count == 1, let e = entries.first else {
            let pids = entries.map { String($0.pid) }.joined(separator: ", ")
            throw CappyError.usage(tr("Several recordings are running (PID \(pids)). Specify one with --pid", ja: "複数の録音が実行中です（PID \(pids)）。--pid で指定してください"))
        }
        guard let before = e.screenshotAttempts else {
            throw CappyError.usage(tr("The recording (PID \(e.pid)) was started by a version of cappy without screenshots", ja: "録音（PID \(e.pid)）はスクリーンショットに対応していない版の cappy で始めたものです"))
        }
        try RecordingRegistry.requestScreenshot(of: e)
        // 録音プロセスが撮り終えて登録簿を更新するのを待つ（最大 15 秒。初回は許可のダイアログが出ることがある）
        for _ in 0..<150 {
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let cur = RecordingRegistry.entry(pid: e.pid) else {
                throw CappyError.targetNotFound(tr("The recording (PID \(e.pid)) has ended", ja: "録音（PID \(e.pid)）は終了しました"))
            }
            guard let n = cur.screenshotAttempts, n > before else { continue }
            if let path = cur.lastScreenshot, cur.lastScreenshotError == nil {
                Console.print(tr("📸 Saved: \(path)", ja: "📸 保存しました: \(path)"))
                return
            }
            throw CappyError.io(cur.lastScreenshotError ?? tr("Failed to take the screenshot", ja: "スクリーンショットを撮れませんでした"))
        }
        throw CappyError.io(tr("The recording (PID \(e.pid)) did not answer. Check its terminal", ja: "録音（PID \(e.pid)）から応答がありません。録音中のターミナルを確認してください"))
    }
}

/// `cappy record` 側のスクリーンショット（キー入力・シグナルから撮り、session.json と登録簿に記録する）
final class ScreenshotController: @unchecked Sendable {
    private let recorder: Recorder
    private let registry: MicMuteController
    private let lock = NSLock()
    private var source: DispatchSourceSignal?
    private var busy = false
    /// 撮影中に来た要求の数（撮り終えてから順に撮る）
    private var pending = 0
    private var stopped = false
    private var attempts = 0

    init(recorder: Recorder, registry: MicMuteController) {
        self.recorder = recorder
        self.registry = registry
    }

    /// シグナルの受け口を用意する（登録簿に載せる前に呼ぶ）
    func start() {
        signal(RecordingRegistry.screenshotSignal, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: RecordingRegistry.screenshotSignal, queue: .global())
        src.setEventHandler { [weak self] in self?.request() }
        src.resume()
        lock.withLock { source = src }
    }

    /// 撮る（撮影中なら撮り終えてから）
    func request() {
        let run: Bool = lock.withLock {
            guard !stopped else { return false }
            if busy {
                pending += 1
                return false
            }
            busy = true
            return true
        }
        guard run else { return }
        Task.detached { [self] in
            while true {
                await captureOnce()
                let more: Bool = lock.withLock {
                    if pending > 0 && !stopped {
                        pending -= 1
                        return true
                    }
                    busy = false
                    return false
                }
                if !more { return }
            }
        }
    }

    private func captureOnce() async {
        let atMs = recorder.elapsedMs
        let store = recorder.session
        let number = (store.metadata.screenshots?.count ?? 0) + 1
        let rel = WindowScreenshot.relativePath(number: number, atMs: atMs)
        let url = store.directory.appendingPathComponent(rel)
        let at = TimeFormat.hms(ms: atMs)
        // 録音対象のプロセスは録音中に増えることがある（ヘルパーの起動など）ので、撮るたびに作り直す
        let target = ScreenshotTarget(targets: store.metadata.targets)
        do {
            let r = try await WindowScreenshot.capture(target: target, to: url)
            _ = try? store.update { m in
                m.screenshots = (m.screenshots ?? []) + [SessionScreenshot(atMs: atMs, file: rel, bundleID: r.bundleID, title: r.title)]
            }
            let what = r.wholeDisplay ? tr("display", ja: "画面全体") : [r.appName, r.title].compactMap { $0 }.joined(separator: " — ")
            CappyLog.shared.info(tr("Screenshot saved at=\(atMs)ms file=\(rel) bundle=\(r.bundleID ?? "-")", ja: "スクリーンショットを保存しました at=\(atMs)ms file=\(rel) bundle=\(r.bundleID ?? "-")"))
            Console.print(tr("📸 Screenshot \(number) (\(at)): \(rel)", ja: "📸 スクリーンショット \(number)（\(at)）: \(rel)") + (what.isEmpty ? "" : "  [\(what)]"))
            finish(path: url.path, error: nil)
        } catch {
            let message: String
            if let e = error as? CappyError {
                message = e.message + (e.hint.map { "\n" + $0 } ?? "")
            } else {
                message = "\(error)"
            }
            CappyLog.shared.warning(tr("Screenshot failed: \(message)", ja: "スクリーンショットを撮れませんでした: \(message)"))
            Console.print(tr("⚠️  Screenshot failed: \(message)", ja: "⚠️  スクリーンショットを撮れませんでした: \(message)"))
            finish(path: nil, error: message)
        }
    }

    private func finish(path: String?, error: String?) {
        let n: Int = lock.withLock {
            attempts += 1
            return attempts
        }
        registry.updateRegistry { e in
            e.screenshotAttempts = n
            e.lastScreenshot = path
            e.lastScreenshotError = error
        }
    }

    /// 以後の要求を無視する
    func cancel() {
        lock.withLock {
            stopped = true
            pending = 0
            source?.cancel()
            source = nil
        }
    }

    /// 録音の停止時に呼ぶ。以後の要求は無視し、撮影中のものは終わるまで待つ（最大 5 秒）
    func stop() async {
        cancel()
        var waited = 0
        while lock.withLock({ busy }) && waited < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
    }
}
