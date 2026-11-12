import ArgumentParser
import CappyKit
import Darwin
import Foundation

/// 全画面でプロファイル・操作・録音するアプリを選び、Enter で録音を始める。録音中もそのまま全画面で表示する
struct TUI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tui",
        abstract: tr("Choose the profile, operation and app on a full screen, then record on the same screen", ja: "全画面でプロファイル・操作・アプリを選び、そのまま同じ画面で録音する"),
        discussion: tr("""
        The upper part chooses the profile, what to do after recording (transcribe, summarize, live transcription),
        the summary model (when summarizing; the available models are fetched from Vertex AI / Bedrock),
        the microphone, auto stop and the session name (Enter opens the choices). The lower part lists the apps that
        use audio (helper processes of the same app are grouped; refreshed automatically). Choose an app and press
        Enter to start `cappy record` with those settings; the recording, transcription and summary are shown on
        the same screen.

        While recording: Space mutes / unmutes the mic, Enter adds a marker (type a label first if you like),
        Ctrl-C stops the recording and goes on to the conversion, transcription and summary that were chosen.
        Ctrl-C while stopping skips the conversion; Ctrl-C during the conversion, transcription or summary interrupts it
        (resume with `cappy recover` / `cappy transcribe` / `cappy summarize`) and quits.
        When everything is finished, the screen goes back to choosing the app (l shows the last log), so you can
        record again. q quits; the messages are written to the terminal.

        Tab switches to the past recordings: show the transcript (t), live transcript (l) or summary (s),
        play both tracks mixed (p), open each track in the default player, show the folder in Finder (f),
        create the summary of a session not summarized yet (from the menu; Ctrl-C interrupts it),
        or delete a session (d; asks first and moves the folder to the Trash).
        """, ja: """
        上の欄でプロファイル、録音後の操作（文字起こし・要約・リアルタイム文字起こし）、要約モデル（要約するとき。
        使えるモデルを Vertex AI / Bedrock から取得します）、マイク、自動停止、セッション名を選びます
        （Enter で選択肢を表示）。下の欄は音声を使うアプリの一覧です（同じアプリの
        ヘルパーは 1 行にまとめ、自動で更新します）。アプリを選んで Enter を押すと、その設定で `cappy record` を
        始め、録音・文字起こし・要約の様子を同じ画面に表示します。

        録音中: Space でマイクのミュート / 解除、Enter でマーカー（先に文字を入力するとラベル付き）、
        Ctrl-C で録音を停止し、選んだ変換・文字起こし・要約に進みます。
        停止処理中の Ctrl-C で変換を省いて終了、変換・文字起こし・要約中の Ctrl-C で中断します
        （`cappy recover` / `cappy transcribe` / `cappy summarize` で再開できます）して終了します。
        すべて終わるとアプリを選ぶ画面に戻り（l で前回のログ）、続けて録音できます。q で終了し、
        表示したメッセージは端末に残します。

        Tab で過去の録音のページに切り替えます。文字起こし（t）・リアルタイム文字起こし（l）・要約（s）の表示、
        相手と自分を合わせた再生（p）、各トラックを再生アプリで開く、フォルダを Finder で開く（f）、
        まだ要約していないセッションの要約の作成（メニューから。Ctrl-C で中断）、
        削除（d。確認してからフォルダをゴミ箱に移動）ができます。
        """)
    )

    @Flag(help: ArgumentHelp(tr("Draw the symbols (▶ ● ─ │ → …) with ASCII, for terminals that show ambiguous-width characters as wide (also CAPPY_TUI_ASCII=1)",
                                ja: "記号（▶ ● ─ │ → … など）を ASCII で描く。あいまい幅の文字を全角で表示する端末向け（CAPPY_TUI_ASCII=1 でも可）")))
    var ascii = false

    @OptionGroup var common: CommonOptions

    func run() async throws {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            throw CappyError.usage(tr("cappy tui needs a terminal; use `cappy record` in scripts", ja: "cappy tui はターミナルで実行してください（スクリプトからは `cappy record`）"))
        }
        let config = try CappyConfig.load()
        if let name = common.profile { _ = try config.profile(named: name) }
        var launcher = RecordLauncher(profiles: RecordLauncher.orderedProfiles(config), initialProfile: common.profile)
        launcher.verbose = common.verbose
        launcher.update(targets: Self.loadTargets())

        // 過去の録音は、どのプロファイルの保存先にあるものも一覧に出す
        var outputDirectories: [URL] = []
        for p in launcher.profiles where !outputDirectories.contains(p.outputDirectoryURL.standardizedFileURL) {
            outputDirectories.append(p.outputDirectoryURL.standardizedFileURL)
        }
        let env = ProcessInfo.processInfo.environment["CAPPY_TUI_ASCII"] ?? ""
        let app = TUIApp(launcher: launcher, outputDirectories: outputDirectories, refresh: Self.loadTargets,
                         ascii: ascii || !["", "0", "false", "no"].contains(env.lowercased()))
        try app.open()
        // 画面を出している間のメッセージは、録音中でなくても画面の外に直接書かせない（#21）
        Console.redirect(to: app)
        defer {
            Console.redirect(to: nil)
            app.close()
        }
        // 録音・文字起こし・要約が終わったら（エラーでも）選ぶ画面に戻り、続けて録音できる
        while let choice = await app.chooseTarget() {
            let arguments: [String], details: [(label: String, value: String)]
            switch choice {
            case .summarize(let entry):
                await Self.summarize(entry, app: app)
                continue
            case .record(let a, let d):
                (arguments, details) = (a, d)
            }
            let record: Record
            do {
                record = try Record.parse(arguments)
            } catch {
                app.finishSession(directory: nil, error: Self.describe(error))
                continue
            }
            app.beginSession(details: details,
                             command: "$ cappy record " + arguments.map(Self.shellQuote).joined(separator: " "))
            LiveCaptions.shared.reset()
            let directory = SessionDirectoryBox()
            var failure: Error?
            do {
                try await record.execute(keyInput: app, onSession: { directory.set($0) })
            } catch {
                failure = error
            }
            app.finishSession(directory: directory.get(), error: failure.map(Self.describe))
        }
    }

    /// 過去の録音のページから要約を作る（`cappy summarize` と同じ。プロファイルは録音したときのもの）。
    /// Ctrl-C で中断して一覧に戻る
    static func summarize(_ entry: SessionEntry, app: TUIApp) async {
        let task = Task { () throws -> Void in
            let store = try SessionStore.open(entry.directory)
            let profile = try CappyConfig.load().profile(named: store.metadata.profile)
            if profile.summaryProvider == "none" {
                throw CappyError.usage(tr("The summary provider of profile \(profile.name) is none", ja: "プロファイル \(profile.name) の要約プロバイダが none です"),
                                       hint: tr("Set provider in [profiles.\(profile.name).summary] to vertex or bedrock", ja: "[profiles.\(profile.name).summary] の provider を vertex か bedrock にしてください"))
            }
            let name = entry.title.isEmpty ? entry.directory.lastPathComponent : entry.title
            app.beginSession(details: [(tr("Session", ja: "セッション"), name),
                                       (tr("Profile", ja: "プロファイル"), profile.name),
                                       (tr("Model", ja: "モデル"), profile.summary.model)],
                             command: "$ cappy summarize " + shellQuote(entry.directory.path), job: .summarize)
            CappyLog.shared.attach(sessionDirectory: entry.directory)
            CappyLog.shared.info(tr("cappy \(CappyVersion.current) summarize started session=\(store.metadata.id)", ja: "cappy \(CappyVersion.current) summarize 開始 session=\(store.metadata.id)"))
            defer { CappyLog.shared.detach() }
            try await SummarizeRunner.run(store: store, profile: profile, request: .init(explicit: true))
        }
        app.setCancelJob { task.cancel() }
        let result = await task.result
        app.setCancelJob(nil)
        var error: String?
        if case .failure(let e) = result {
            error = task.isCancelled ? tr("Interrupted. Create the summary again from the menu, or with `cappy summarize \(entry.directory.path)`",
                                          ja: "中断しました。メニューか `cappy summarize \(entry.directory.path)` で作り直せます")
                : describe(e)
        }
        app.finishSummary(directory: entry.directory, error: error)
    }

    static func loadTargets() -> [LaunchTarget] {
        LaunchTarget.group((try? AudioProcesses.list()) ?? [], excludingPID: getpid())
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? CappyError { return e.message + (e.hint.map { "  — \($0)" } ?? "") }
        return Cappy.message(for: error)
    }

    /// record が作ったセッションディレクトリを受け取る
    final class SessionDirectoryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var url: URL?
        func set(_ u: URL) { lock.withLock { url = u } }
        func get() -> URL? { lock.withLock { url } }
    }

    static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@%+,"))
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) && $0.isASCII }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - 端末

/// 端末の設定を戻すための保存先（atexit から参照するためグローバルに置く）
nonisolated(unsafe) private var tuiSavedTermios: termios?
/// 画面を閉じるときに、表示したメッセージを端末に残すため
nonisolated(unsafe) private weak var tuiActiveApp: TUIApp?
private let tuiLock = NSLock()

/// 代替スクリーンから戻り、端末の設定を戻して、メッセージを通常の画面に書き出す（何度呼んでもよい）
private func tuiRestoreTerminal() {
    let (restored, app): (Bool, TUIApp?) = tuiLock.withLock {
        guard var t = tuiSavedTermios else { return (false, nil) }
        tuiSavedTermios = nil
        // 折り返しを戻し、カーソルを表示して、代替スクリーンから戻る
        FileHandle.standardOutput.write(Data("\u{1B}[0m\u{1B}[?7h\u{1B}[?25h\u{1B}[?1049l".utf8))
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
        let app = tuiActiveApp
        tuiActiveApp = nil
        return (true, app)
    }
    guard restored, let app else { return }
    let log = app.logSnapshot()
    if !log.isEmpty {
        FileHandle.standardError.write(Data((log.joined(separator: "\n") + "\n").utf8))
    }
}

/// `cappy tui` の画面。アプリを選ぶ画面と、録音中の画面を切り替えて表示する。
///
/// キー入力と描画は専用のスレッドで行い、録音（Record.execute）は呼び出し側のタスクで動かす。
/// 録音中は Console の表示を受け取って画面に出し（ConsoleSink）、キー入力を record に渡す（RecordKeyInput）。
final class TUIApp: ConsoleSink, RecordKeyInput, @unchecked Sendable {
    enum Choice {
        /// アプリを選んで録音を始める
        case record(arguments: [String], details: [(label: String, value: String)])
        /// 過去の録音のページから要約を作る
        case summarize(SessionEntry)
    }

    private enum Mode { case launcher, sessions, pager, session, viewingLog }
    /// .session の画面で動かしているもの
    enum Job { case record, summarize }

    private let lock = NSLock()
    private var launcher: RecordLauncher
    private let refresh: @Sendable () -> [LaunchTarget]
    private var mode = Mode.launcher
    private var job = Job.record
    private var running = false
    private var dirty = true
    private let loopDone = DispatchSemaphore(value: 0)
    private var termSource: DispatchSourceSignal?

    // アプリを選ぶ画面・過去の録音・テキストの表示で使うキーの解釈
    private var launcherParser = TUIKeyParser()
    private var browser: SessionBrowser
    private var pager: TextPager?
    private var screenSize = (80, 24)
    private var chooseContinuation: CheckedContinuation<Choice?, Never>?
    private var pendingChoice: Choice??

    // 録音中の画面（終わった後は l で見直せる）
    private var details: [(label: String, value: String)] = []
    private var log: [String] = []
    /// これまでの録音すべてのメッセージ（閉じるときに端末に書き出す）
    private var allLog: [String] = []
    private var status: String?
    private var lastResult: String?
    private var lastFailed = false
    private var keyHandler: (@Sendable (KeyInputParser.Event, String) -> Void)?
    /// 録音以外の処理（要約）を Ctrl-C で中断する
    private var cancelJob: (@Sendable () -> Void)?
    private var keyParser = KeyInputParser()

    private static let maxLog = 5000

    /// 前回の画面との差分を作る（描画のスレッドだけが使う）
    private var frameWriter: TUIFrameWriter

    init(launcher: RecordLauncher, outputDirectories: [URL], refresh: @escaping @Sendable () -> [LaunchTarget], ascii: Bool = false) {
        self.launcher = launcher
        frameWriter = TUIFrameWriter(ascii: ascii)
        browser = SessionBrowser(directories: outputDirectories)
        self.refresh = refresh
    }

    // MARK: 開く・閉じる

    func open() throws {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw CappyError.usage(tr("Cannot configure the terminal", ja: "端末を設定できません"))
        }
        var raw = original
        // 行単位の入力・エコー・Ctrl-C のシグナルをやめる（Ctrl-C はキーとして読み、録音の停止などに使う）
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        tuiLock.withLock {
            tuiSavedTermios = original
            tuiActiveApp = self
        }
        atexit { tuiRestoreTerminal() }
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            tuiRestoreTerminal()
            throw CappyError.usage(tr("Cannot configure the terminal", ja: "端末を設定できません"))
        }
        // 代替スクリーンに切り替え、カーソルを隠し、行末での折り返しを止める（幅がずれても画面がずれないように）
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?7l")

        // 録音の割り込み処理がない間（選ぶ画面・録音の準備中・終了後）の SIGTERM は、端末を戻して終了する
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        src.setEventHandler {
            guard InterruptController.current == nil else { return } // 録音中は record が止める
            tuiRestoreTerminal()
            Foundation.exit(143)
        }
        src.resume()
        termSource = src

        lock.withLock { running = true }
        let t = Thread { [weak self] in self?.loop() }
        t.name = "dev.cappy.tui"
        t.start()
    }

    func close() {
        let wasRunning = lock.withLock { () -> Bool in
            defer { running = false }
            return running
        }
        if wasRunning { _ = loopDone.wait(timeout: .now() + 1) }
        termSource?.cancel()
        termSource = nil
        tuiRestoreTerminal()
    }

    func logSnapshot() -> [String] { lock.withLock { allLog } }

    // MARK: 呼び出し側から

    /// アプリを選んで Enter を押すまで待つ。やめたら nil
    func chooseTarget() async -> Choice? {
        await withCheckedContinuation { (c: CheckedContinuation<Choice?, Never>) in
            let ready: Choice?? = lock.withLock {
                if let p = pendingChoice {
                    pendingChoice = nil
                    return p
                }
                chooseContinuation = c
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }

    func beginSession(details: [(label: String, value: String)], command: String, job: Job = .record) {
        lock.withLock {
            self.job = job
            self.details = details
            log = []
            status = nil
            if !allLog.isEmpty { allLog.append("") }
            mode = .session
            dirty = true
        }
        consolePrint(command)
    }

    /// 録音・文字起こし・要約が終わった（または失敗した）。結果を上に出して、選ぶ画面に戻る
    func finishSession(directory: URL?, error: String?) {
        lock.withLock {
            let text: String
            if let error {
                text = error
            } else if let directory {
                text = tr("Finished: \(directory.path)", ja: "終わりました: \(directory.path)")
            } else {
                text = tr("Finished", ja: "終わりました")
            }
            lastResult = text
            lastFailed = error != nil
            if let error { allLog.append(tr("Error: \(error)", ja: "エラー: \(error)")) }
            launcher.notice = RecordLauncher.Notice(text: text, isError: error != nil)
            status = nil
            keyHandler = nil
            launcherParser = TUIKeyParser()
            mode = .launcher
            dirty = true
        }
    }

    func setCancelJob(_ cancel: (@Sendable () -> Void)?) {
        lock.withLock { cancelJob = cancel }
    }

    /// 過去の録音のページから始めた要約が終わった（または失敗した）。結果を一覧の上に出して、一覧に戻る
    func finishSummary(directory: URL, error: String?) {
        let entries = SessionCatalog.scan(lock.withLock { browser.directories })
        lock.withLock {
            let text: String
            if let error {
                text = "✗ " + error
                allLog.append(tr("Error: \(error)", ja: "エラー: \(error)"))
            } else {
                text = tr("Summary created: \(directory.path)", ja: "要約を作成しました: \(directory.path)")
            }
            browser.update(entries: entries)
            browser.notice = text
            status = nil
            cancelJob = nil
            launcherParser = TUIKeyParser()
            mode = .sessions
            dirty = true
        }
    }

    // MARK: ConsoleSink

    func consolePrint(_ message: String) {
        lock.withLock {
            log.append(message)
            if log.count > Self.maxLog { log.removeFirst(log.count - Self.maxLog) }
            allLog.append(message)
            if allLog.count > Self.maxLog { allLog.removeFirst(allLog.count - Self.maxLog) }
            dirty = true
        }
    }

    func consoleStatus(_ message: String) {
        lock.withLock {
            status = message
            dirty = true
        }
    }

    func consoleClearStatus() {
        lock.withLock {
            status = nil
            dirty = true
        }
    }

    // MARK: RecordKeyInput

    func start(onEvent: @escaping @Sendable (KeyInputParser.Event, String) -> Void) -> Bool {
        lock.withLock {
            keyParser = KeyInputParser()
            keyHandler = onEvent
        }
        return true
    }

    func stop() {
        lock.withLock { keyHandler = nil }
    }

    // MARK: 画面のスレッド

    private func loop() {
        defer { loopDone.signal() }
        var lastRefresh = Date()
        var lastSize = (0, 0)
        var lastPhase: InterruptController.Phase?
        var buffer = [UInt8](repeating: 0, count: 256)
        while lock.withLock({ running }) {
            if lock.withLock({ mode == .launcher }), Date().timeIntervalSince(lastRefresh) >= 1.5 {
                let targets = refresh()
                lock.withLock {
                    let before = launcher.targets
                    launcher.update(targets: targets)
                    if launcher.targets != before { dirty = true }
                }
                lastRefresh = Date()
            }
            let size = Self.terminalSize()
            let phase = InterruptController.current?.currentPhase
            let redraw = lock.withLock { () -> Bool in
                screenSize = size
                if size != lastSize || phase != lastPhase { dirty = true }
                defer { dirty = false }
                return dirty
            }
            lastSize = size
            lastPhase = phase
            if redraw { draw(width: size.0, height: size.1, phase: phase) }

            var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fds, 1, 50)
            if ready > 0 {
                let n = read(STDIN_FILENO, &buffer, buffer.count)
                if n <= 0 { // 端末が閉じられた
                    handleClosedInput()
                    return
                }
                for b in buffer[0..<n] { handle(byte: b) }
            } else if ready == 0 {
                let key: TUIKey? = lock.withLock { usesTUIKeys ? launcherParser.timeout() : nil }
                if let key { dispatch(key) }
            }
        }
    }

    private func handleClosedInput() {
        let c: CheckedContinuation<Choice?, Never>? = lock.withLock {
            defer { chooseContinuation = nil }
            if chooseContinuation == nil { pendingChoice = .some(nil) }
            return chooseContinuation
        }
        c?.resume(returning: nil)
    }

    private func handle(byte: UInt8) {
        let m = lock.withLock { mode }
        switch m {
        case .launcher, .sessions, .pager:
            let key: TUIKey? = lock.withLock { launcherParser.feed(byte) }
            if let key { dispatch(key) }
        case .session:
            if byte == 0x03 {
                interrupt()
                return
            }
            let call: ((@Sendable (KeyInputParser.Event, String) -> Void), KeyInputParser.Event, String)? = lock.withLock {
                guard let h = keyHandler, let e = keyParser.feed(byte) else { return nil }
                return (h, e, keyParser.text)
            }
            if let (h, e, text) = call { h(e, text) }
        case .viewingLog:
            // Enter・q・Esc・l・Ctrl-C で選ぶ画面に戻る（矢印キーの ESC [ A なども戻る扱いでよい）
            guard [0x0D, 0x0A, 0x03, 0x1B, UInt8(ascii: "q"), UInt8(ascii: "Q"), UInt8(ascii: "l"), UInt8(ascii: "L")].contains(byte) else { return }
            lock.withLock {
                launcherParser = TUIKeyParser()
                mode = .launcher
                dirty = true
            }
        }
    }

    /// TUIKey で操作する画面か（録音中の画面は KeyInputParser で読む）
    private var usesTUIKeys: Bool { mode == .launcher || mode == .sessions || mode == .pager }

    private func dispatch(_ key: TUIKey) {
        switch lock.withLock({ mode }) {
        case .launcher: handleLauncher(key)
        case .sessions: handleSessions(key)
        case .pager: handlePager(key)
        case .session, .viewingLog: break
        }
    }

    /// アプリを選ぶ画面か過去の録音の画面で q を押した（cappy tui を終える）
    private func resolveChoice(_ choice: Choice?) {
        let c: CheckedContinuation<Choice?, Never>? = lock.withLock {
            defer { chooseContinuation = nil }
            if chooseContinuation == nil { pendingChoice = .some(choice) }
            return chooseContinuation
        }
        c?.resume(returning: choice)
    }

    // MARK: 過去の録音

    private func showSessions() {
        let entries = SessionCatalog.scan(lock.withLock { browser.directories })
        lock.withLock {
            browser.update(entries: entries)
            mode = .sessions
            dirty = true
        }
    }

    private func handleSessions(_ key: TUIKey) {
        let action: SessionBrowser.Action? = lock.withLock {
            dirty = true
            return browser.handle(key)
        }
        guard let action else { return }
        switch action {
        case .quit:
            resolveChoice(nil)
        case .switchPage:
            lock.withLock {
                mode = .launcher
                dirty = true
            }
        case .refresh:
            showSessions()
        case .view(let title, let url):
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                lock.withLock {
                    pager = TextPager(title: title, text: text)
                    mode = .pager
                    dirty = true
                }
            } catch {
                setSessionsNotice(tr("Cannot read \(url.lastPathComponent): \(error.localizedDescription)", ja: "\(url.lastPathComponent) を読めません: \(error.localizedDescription)"))
            }
        case .open(let url):
            openExternally(url)
        case .trash(let entry):
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                do {
                    try SessionCatalog.moveToTrash(entry)
                    let entries = SessionCatalog.scan(self.lock.withLock { self.browser.directories })
                    self.lock.withLock { self.browser.update(entries: entries) }
                    self.setSessionsNotice(tr("Moved to the Trash: \(entry.directory.path)", ja: "ゴミ箱に移動しました: \(entry.directory.path)"))
                } catch {
                    self.setSessionsNotice("✗ " + TUI.describe(error))
                }
            }
        case .summarize(let entry):
            lock.withLock {
                browser.notice = nil
                details = []
                log = []
                status = nil
                job = .summarize
                mode = .session // 入力の扱いを処理中のものに切り替える（Ctrl-C で中断）
                dirty = true
            }
            resolveChoice(.summarize(entry))
        case .playMix(let entry):
            setSessionsNotice(tr("Mixing the two tracks…", ja: "2 トラックをミックスしています…"))
            DispatchQueue.global().async { [weak self] in
                do {
                    let url = try SessionPlayback.mixedFile(for: entry)
                    self?.openExternally(url)
                } catch {
                    self?.setSessionsNotice("✗ " + TUI.describe(error))
                }
            }
        }
    }

    private func handlePager(_ key: TUIKey) {
        let result: TextPager.Result? = lock.withLock {
            dirty = true
            let (w, h) = screenSize
            return pager?.handle(key, width: w, height: h)
        }
        switch result {
        case .close?:
            lock.withLock {
                pager = nil
                mode = .sessions
            }
        case .quit?:
            resolveChoice(nil)
        case nil:
            break
        }
    }

    private func setSessionsNotice(_ text: String?) {
        lock.withLock {
            browser.notice = text
            dirty = true
        }
    }

    /// 既定のアプリで開く（音声は再生アプリ、フォルダは Finder）
    private func openExternally(_ url: URL) {
        DispatchQueue.global().async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = [url.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()
                self?.setSessionsNotice(p.terminationStatus == 0
                    ? tr("Opened: \(url.path)", ja: "開きました: \(url.path)")
                    : tr("✗ Could not open: \(url.path)", ja: "✗ 開けませんでした: \(url.path)"))
            } catch {
                self?.setSessionsNotice(tr("✗ Could not open: \(url.path) (\(error.localizedDescription))", ja: "✗ 開けませんでした: \(url.path)（\(error.localizedDescription)）"))
            }
        }
    }

    /// Ctrl-C。録音の割り込み処理があればそこへ渡し（停止・変換の省略・中断）、なければ準備中なので中止する
    private func interrupt() {
        if let cancel = lock.withLock({ cancelJob }) {
            consoleClearStatus()
            consolePrint(tr("Ctrl-C: interrupting…", ja: "Ctrl-C: 中断しています…"))
            cancel()
            return
        }
        if let controller = InterruptController.current {
            controller.trigger(SIGINT)
            return
        }
        consolePrint(tr("Ctrl-C: cancelled", ja: "Ctrl-C: 中止しました"))
        tuiRestoreTerminal()
        Foundation.exit(130)
    }

    private func handleLauncher(_ key: TUIKey) {
        var choice: Choice??
        var switchToSessions = false
        var modelLoad: RecordLauncher.Action?
        let wantsRefresh: Bool = lock.withLock {
            dirty = true
            defer { if modelLoad == nil && mode == .launcher { modelLoad = launcher.pendingModelLoad() } }
            let action = launcher.handle(key)
            switch action {
            case .quit?:
                choice = .some(nil)
            case .start(let args)?:
                let details = launcher.selectedTarget.map { launcher.summary(for: $0) } ?? []
                choice = .some(.record(arguments: args, details: details))
                job = .record
                mode = .session // 入力の扱いを録音中のものに切り替える
            case .refresh?:
                return true
            case .showLog?:
                mode = .viewingLog
            case .switchPage?:
                switchToSessions = true
            case .loadModels?:
                modelLoad = action
            case nil:
                break
            }
            return false
        }
        if case .loadModels(let key, let profile)? = modelLoad { loadModels(key: key, profile: profile) }
        if wantsRefresh {
            let targets = refresh()
            lock.withLock { launcher.update(targets: targets) }
        }
        if switchToSessions { showSessions() }
        guard let choice else { return }
        resolveChoice(choice)
    }

    /// 要約モデルの一覧を API で取得し、終わったら画面に反映する（取得中も操作できる）
    private func loadModels(key: String, profile: Profile) {
        Task.detached { [weak self] in
            let result: Result<[SummaryModelOption], Error>
            do {
                result = .success(try await SummaryModelCatalog.list(profile: profile))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.lock.withLock {
                self.launcher.setModelList(key: key, result)
                self.dirty = true
            }
        }
    }

    // MARK: 描画

    private func draw(width terminalWidth: Int, height: Int, phase: InterruptController.Phase?) {
        // 右端の 1 桁は空けておく（TUIFrameWriter を参照）
        let width = TUIFrameWriter.contentWidth(terminalWidth)
        let (lines, cursor): ([RecordLauncher.Line], (row: Int, column: Int)?) = lock.withLock {
            switch mode {
            case .launcher:
                var (lines, cursor) = launcher.render(width: width, height: height)
                if !lines.isEmpty { lines[0] = Self.tabBar(active: 0, width: width) }
                return (lines, cursor)
            case .sessions:
                var lines = browser.render(width: width, height: height)
                if !lines.isEmpty { lines[0] = Self.tabBar(active: 1, width: width) }
                return (lines, nil)
            case .pager:
                return (pager?.render(width: width, height: height) ?? [], nil)
            case .session, .viewingLog:
                let (title, help) = Self.titleAndHelp(mode: mode, job: job, phase: phase)
                var shownStatus = status
                if mode == .viewingLog {
                    shownStatus = lastResult.map { (lastFailed ? "✗ " : "✓ ") + $0 }
                }
                let screen = RecordingScreen(title: title, details: details, status: shownStatus, log: log, help: help)
                return (screen.render(width: width, height: height), nil)
            }
        }
        let frame = frameWriter.frame(lines, cursor: cursor.map { TUIFrameWriter.Cursor(row: $0.row, column: $0.column) },
                                      width: terminalWidth, height: height)
        if let frame { write(frame) }
    }

    /// 一番上の行: 「録音」と「過去の録音」のタブ
    private static func tabBar(active: Int, width: Int) -> RecordLauncher.Line {
        typealias Segment = RecordLauncher.Line.Segment
        let names = [tr("Record", ja: "録音"), tr("Past recordings", ja: "過去の録音")]
        var segments = [Segment(text: " cappy  ", style: .title)]
        for (i, n) in names.enumerated() {
            segments.append(Segment(text: " \(n) ", style: i == active ? .selected : .dim))
            segments.append(Segment(text: " ", style: .normal))
        }
        let used = segments.reduce(0) { $0 + DisplayWidth.of($1.text) }
        segments.append(Segment(text: DisplayWidth.fit(tr("  Tab: switch", ja: "  Tab: 切り替え"), max(0, width - used)), style: .dim))
        var line = RecordLauncher.Line(text: "", style: .title)
        line.segments = segments
        return line
    }

    private static func titleAndHelp(mode: Mode, job: Job, phase: InterruptController.Phase?) -> (String, String) {
        if mode == .viewingLog {
            return (tr("Log of the last recording", ja: "前回の録音のログ"),
                    tr("Enter / q / l: back to the list", ja: "Enter / q / l: 一覧に戻る"))
        }
        if job == .summarize {
            return (tr("Summarizing…", ja: "要約を作成しています…"),
                    tr("Ctrl-C: interrupt and go back to the past recordings", ja: "Ctrl-C: 中断して過去の録音に戻る"))
        }
        switch phase {
        case nil:
            return (tr("Preparing…", ja: "準備中…"), tr("Ctrl-C: cancel", ja: "Ctrl-C: 中止"))
        case .recording?:
            return (tr("● Recording", ja: "● 録音中"),
                    tr("Space: mute / unmute the mic   Enter: marker (type a label first)   Ctrl-C: stop and save",
                       ja: "Space: マイクのミュート / 解除   Enter: マーカー（先に文字でラベル）   Ctrl-C: 停止して保存"))
        case .finalizing?:
            return (tr("Stopping the recording…", ja: "録音を停止しています…"),
                    tr("Ctrl-C: skip the conversion and finish", ja: "Ctrl-C: 変換を省いて終える"))
        case .converting?:
            return (tr("Creating the files to send…", ja: "送信用ファイルを作成しています…"),
                    tr("Ctrl-C: interrupt (the recording is saved; redo with `cappy recover`)", ja: "Ctrl-C: 中断（録音は保存済み。`cappy recover` でやり直せます）"))
        case .transcribing?:
            return (tr("Transcribing…", ja: "文字起こし中…"),
                    tr("Ctrl-C: interrupt (resume with `cappy transcribe`)", ja: "Ctrl-C: 中断（`cappy transcribe` で再開できます）"))
        case .summarizing?:
            return (tr("Summarizing…", ja: "要約を作成しています…"),
                    tr("Ctrl-C: interrupt (redo with `cappy summarize`)", ja: "Ctrl-C: 中断（`cappy summarize` で作り直せます）"))
        case .done?:
            return (tr("Finishing…", ja: "終了処理中…"), "")
        }
    }

    private static func terminalSize() -> (Int, Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (80, 24)
    }

    private func write(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }
}
