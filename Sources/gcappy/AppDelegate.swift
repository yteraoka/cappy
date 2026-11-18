import AppKit
import CappyKit
import ServiceManagement
import UserNotifications

/// メニューバーのアイコンとメニュー。メニューは開くたびに作り直す（音声プロセスや設定ファイルの変化を反映するため）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let prefs = Preferences()
    private var timer: Timer?

    /// 実行中（または最後に実行した）録音
    private var job: RecordingJob?
    /// 最後に終わった録音のセッションディレクトリとログ
    private var lastSession: URL?
    private var lastLog: URL?
    /// 終了の確認後、録音の停止を待っている
    private var quitPending = false
    private var quitDeadline: Date?

    // メニューの項目から参照する一覧（tag で添字を渡す）
    private var menuTargets: [LaunchTarget] = []
    private var menuProfiles: [Profile] = []
    private var menuOperations: [LaunchOperation] = []
    private var otherRecordings: [RecordingRegistry.Entry] = []

    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    // MARK: - 起動と終了

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.behavior = []
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateStatusButton()

        let t = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        // メニューを開いている間も経過時間を更新する
        RunLoop.main.add(t, forMode: .common)
        timer = t

        AppEnvironment.pruneLogs()
        if notificationsAvailable {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        if AppEnvironment.cappyExecutable == nil {
            showAlert(tr("The cappy command was not found", ja: "cappy コマンドが見つかりません"),
                      tr("gcappy runs the cappy bundled in gcappy.app. Reinstall gcappy (brew reinstall gcappy).",
                         ja: "gcappy は gcappy.app に同梱の cappy で録音します。gcappy を入れ直してください（brew reinstall gcappy）。"),
                      style: .critical)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let job, job.isRunning else { return .terminateNow }
        switch job.phase {
        case .starting, .recording:
            let ok = confirm(tr("Stop the recording and quit gcappy?", ja: "録音を停止して gcappy を終了しますか？"),
                             tr("The recording is saved. Converting, transcribing and summarizing continue in the background (log: \(job.logURL.path)).",
                                ja: "録音は保存されます。送信用ファイルの作成・文字起こし・要約はバックグラウンドで続きます（ログ: \(job.logURL.path)）。"),
                             ok: tr("Stop and Quit", ja: "停止して終了"))
            guard ok else { return .terminateCancel }
            job.stop()
            quitPending = true
            quitDeadline = Date().addingTimeInterval(60)
            updateStatusButton()
            return .terminateLater
        case .processing:
            let ok = confirm(tr("Quit gcappy?", ja: "gcappy を終了しますか？"),
                             tr("Transcription and summary continue in the background. You are not notified when they finish (log: \(job.logURL.path)).",
                                ja: "文字起こしと要約はバックグラウンドで続きますが、終わっても通知されません（ログ: \(job.logURL.path)）。"),
                             ok: tr("Quit", ja: "終了"))
            return ok ? .terminateNow : .terminateCancel
        case .finished:
            return .terminateNow
        }
    }

    @objc private func tick() {
        job?.refresh()
        if quitPending, let job {
            let stopped = !job.isRunning || job.phase == .processing
            if stopped || (quitDeadline.map { Date() > $0 } ?? false) {
                quitPending = false
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
        }
        updateStatusButton()
    }

    // MARK: - メニューバーのアイコン

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        var symbol = "waveform.circle"
        var title = ""
        var tint: NSColor?
        if let job, job.isRunning {
            switch job.phase {
            case .starting:
                symbol = "ellipsis.circle"
            case .recording:
                symbol = job.isMuted ? "mic.slash.circle.fill" : "record.circle.fill"
                tint = .systemRed
                title = " " + TimeFormat.elapsed(job.elapsed)
            case .processing:
                symbol = "hourglass.circle"
            case .finished:
                break
            }
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "gcappy")
        // テンプレート画像にしておけば、contentTintColor で録音中だけ赤くできる
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
        button.imagePosition = .imageLeading
        if title.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ])
        }
        button.toolTip = statusTooltip
    }

    private var statusTooltip: String {
        guard let job, job.isRunning else { return "gcappy" }
        switch job.phase {
        case .starting: return tr("gcappy: starting the recording…", ja: "gcappy: 録音を始めています…")
        case .recording: return tr("gcappy: recording \(job.target.name)", ja: "gcappy: \(job.target.name) を録音中")
        case .processing: return tr("gcappy: processing the recording…", ja: "gcappy: 録音を処理しています…")
        case .finished: return "gcappy"
        }
    }

    // MARK: - メニュー

    func menuNeedsUpdate(_ menu: NSMenu) {
        job?.refresh()
        menu.removeAllItems()
        let config = loadConfig()
        let profile = currentProfile(config.config)

        if let job, job.isRunning {
            buildRunningSection(job)
        } else {
            buildStartSection(profile: profile)
        }
        buildOtherRecordingsSection()

        menu.addItem(.separator())
        buildSettingsSection(config: config, profile: profile, running: job?.isRunning ?? false)

        menu.addItem(.separator())
        buildFilesSection(profile: profile)

        menu.addItem(.separator())
        let login = item(tr("Launch at Login", ja: "ログイン時に起動"), #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.isEnabled = notificationsAvailable
        menu.addItem(login)
        menu.addItem(item(tr("About gcappy", ja: "gcappy について"), #selector(showAbout)))
        menu.addItem(item(tr("Quit gcappy", ja: "gcappy を終了"), #selector(quit), key: "q"))
    }

    private func buildRunningSection(_ job: RecordingJob) {
        switch job.phase {
        case .starting:
            menu.addItem(disabled(tr("Starting the recording: \(job.target.name)…", ja: "録音を始めています: \(job.target.name)…")))
            menu.addItem(disabled(tr("  Allow System Audio Recording and Microphone if asked", ja: "  確認が出たらシステムオーディオ録音とマイクを許可してください")))
            menu.addItem(item(tr("Cancel", ja: "中止"), #selector(stopRecording)))
        case .recording:
            let head = tr("● Recording \(job.target.name)  \(TimeFormat.elapsed(job.elapsed))", ja: "● \(job.target.name) を録音中  \(TimeFormat.elapsed(job.elapsed))")
            menu.addItem(disabled(head))
            menu.addItem(disabled("  " + job.operation.label + (job.name.map { " · \($0)" } ?? "")))
            menu.addItem(.separator())
            menu.addItem(item(tr("Stop Recording", ja: "録音を停止"), #selector(stopRecording), key: "."))
            if job.canMute {
                let mute = item(tr("Mute Microphone", ja: "マイクをミュート"), #selector(toggleMute), key: "m")
                mute.state = job.isMuted ? .on : .off
                menu.addItem(mute)
            }
            menu.addItem(item(tr("Take Screenshot of the App Window", ja: "アプリのウインドウのスクリーンショット"), #selector(takeScreenshot), key: "s"))
            if let dir = job.sessionDirectory {
                menu.addItem(item(tr("Open Session Folder", ja: "セッションのフォルダを開く"), #selector(openURL(_:)), represented: dir))
            }
        case .processing:
            let what = job.stopRequested || job.operation != .record
                ? tr("Processing the recording (\(job.operation.label))…", ja: "録音を処理しています（\(job.operation.label)）…")
                : tr("Finishing the recording…", ja: "録音を終えています…")
            menu.addItem(disabled(what))
            if let dir = job.sessionDirectory {
                menu.addItem(item(tr("Open Session Folder", ja: "セッションのフォルダを開く"), #selector(openURL(_:)), represented: dir))
            }
            menu.addItem(item(tr("Show Log", ja: "ログを表示"), #selector(openURL(_:)), represented: job.logURL))
            menu.addItem(item(tr("Cancel Processing", ja: "処理を中断"), #selector(cancelProcessing)))
        case .finished:
            break
        }
    }

    private func buildStartSection(profile: Profile) {
        menuTargets = (try? LaunchTarget.group(AudioProcesses.list(), excludingPID: getpid())) ?? [LaunchTarget.system]
        if let last = prefs.lastTarget, let i = menuTargets.firstIndex(where: { $0.preferenceKey == last }) {
            let quick = item(tr("Record \(menuTargets[i].name)", ja: "\(menuTargets[i].name) を録音"), #selector(startRecording(_:)), key: "r")
            quick.tag = i
            quick.image = symbolImage("record.circle")
            menu.addItem(quick)
        }

        let start = NSMenuItem(title: tr("Start Recording", ja: "録音を開始"), action: nil, keyEquivalent: "")
        start.image = symbolImage("record.circle")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let others = NSMenu()
        others.autoenablesItems = false
        for (i, t) in menuTargets.enumerated() {
            let title: String
            switch t.kind {
            case .app(let id): title = t.processCount > 1 ? "\(t.name)  (\(id), \(t.processCount))" : "\(t.name)  (\(id))"
            case .pid(let pid): title = "\(t.name)  (PID \(pid))"
            case .system: title = t.name
            }
            let it = item(title, #selector(startRecording(_:)))
            it.tag = i
            if t.isPlaying { it.image = symbolImage("speaker.wave.2.fill") }
            switch t.kind {
            case .system:
                sub.addItem(.separator())
                sub.addItem(it)
            default:
                if t.isApp || t.isPlaying { sub.addItem(it) } else { others.addItem(it) }
            }
        }
        if !others.items.isEmpty {
            let o = NSMenuItem(title: tr("Other Processes", ja: "その他のプロセス"), action: nil, keyEquivalent: "")
            o.submenu = others
            // システム全体の前に置く
            let index = sub.items.firstIndex { $0.isSeparatorItem } ?? sub.items.count
            sub.insertItem(o, at: index)
        }
        let legend = disabled(tr("= playing audio now", ja: "= 音声を出力中"))
        legend.image = symbolImage("speaker.wave.2.fill")
        sub.insertItem(legend, at: 0)
        sub.insertItem(.separator(), at: 1)
        start.submenu = sub
        menu.addItem(start)

        let summary = tr("Profile: \(profile.name) · \(prefs.operation(for: profile).label)", ja: "プロファイル: \(profile.name) · \(prefs.operation(for: profile).label)")
        menu.addItem(disabled("  " + summary))
        if let lastSession {
            for (file, label) in [("summary.md", tr("Open Last Summary", ja: "前回の要約を開く")),
                                  ("transcript.md", tr("Open Last Transcript", ja: "前回の文字起こしを開く")),
                                  ("live-transcript.md", tr("Open Last Live Transcript", ja: "前回のリアルタイム文字起こしを開く"))] {
                let u = lastSession.appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: u.path) {
                    menu.addItem(item(label, #selector(openURL(_:)), represented: u))
                    break
                }
            }
            menu.addItem(item(tr("Open Last Session Folder", ja: "前回のセッションのフォルダを開く"), #selector(openURL(_:)), represented: lastSession))
        }
    }

    /// gcappy 以外（ターミナルの cappy record など）で録音しているもの
    private func buildOtherRecordingsSection() {
        otherRecordings = RecordingRegistry.list().filter { $0.pid != job?.pid }
        guard !otherRecordings.isEmpty else { return }
        menu.addItem(.separator())
        menu.addItem(disabled(tr("Other cappy recordings", ja: "ほかの cappy の録音")))
        for (i, e) in otherRecordings.enumerated() {
            let title = "PID \(e.pid)" + (e.name.map { ": \($0)" } ?? ": " + URL(fileURLWithPath: e.session).lastPathComponent)
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.image = symbolImage(e.micMuted ? "mic.slash" : "record.circle")
            let sub = NSMenu()
            sub.autoenablesItems = false
            if e.hasMic {
                let m = item(tr("Mute Microphone", ja: "マイクをミュート"), #selector(toggleOtherMute(_:)))
                m.tag = i
                m.state = e.micMuted ? .on : .off
                sub.addItem(m)
            }
            let s = item(tr("Take Screenshot", ja: "スクリーンショット"), #selector(otherScreenshot(_:)))
            s.tag = i
            sub.addItem(s)
            let st = item(tr("Stop Recording", ja: "録音を停止"), #selector(stopOther(_:)))
            st.tag = i
            sub.addItem(st)
            sub.addItem(item(tr("Open Session Folder", ja: "セッションのフォルダを開く"), #selector(openURL(_:)),
                             represented: URL(fileURLWithPath: e.session, isDirectory: true)))
            parent.submenu = sub
            menu.addItem(parent)
        }
    }

    private func buildSettingsSection(config: (config: CappyConfig?, error: String?), profile: Profile, running: Bool) {
        if let error = config.error {
            menu.addItem(disabled(tr("⚠️ Config file error", ja: "⚠️ 設定ファイルのエラー")))
            for line in error.split(separator: "\n").prefix(3) { menu.addItem(disabled("  " + String(line))) }
        } else if let c = config.config, !c.fileExists {
            menu.addItem(disabled(tr("⚠️ No config file yet", ja: "⚠️ 設定ファイルがまだありません")))
            menu.addItem(item(tr("Run cappy init in Terminal…", ja: "ターミナルで cappy init を実行…"), #selector(runInit)))
        }

        // プロファイル
        menuProfiles = config.config.map(RecordLauncher.orderedProfiles) ?? []
        if menuProfiles.isEmpty { menuProfiles = [profile] }
        let p = submenu(tr("Profile", ja: "プロファイル"), value: profile.name)
        for (i, pr) in menuProfiles.enumerated() {
            let it = item(pr.name, #selector(selectProfile(_:)))
            it.tag = i
            it.state = pr.name == profile.name ? .on : .off
            p.submenu?.addItem(it)
        }
        p.isEnabled = !running
        menu.addItem(p)

        // 録音の後
        let op = prefs.operation(for: profile)
        menuOperations = LaunchOperation.available(for: profile)
        let o = submenu(tr("After Recording", ja: "録音の後"), value: op.label)
        for (i, candidate) in menuOperations.enumerated() {
            let it = item(candidate.label, #selector(selectOperation(_:)))
            it.tag = i
            it.state = candidate == op ? .on : .off
            o.submenu?.addItem(it)
        }
        o.isEnabled = !running
        menu.addItem(o)

        // マイク
        let mic = prefs.mic
        let m = submenu(tr("Microphone", ja: "マイク"), value: mic.label)
        for (i, candidate) in LaunchMic.allCases.enumerated() {
            let it = item(candidate.label, #selector(selectMic(_:)))
            it.tag = i
            it.state = candidate == mic ? .on : .off
            m.submenu?.addItem(it)
        }
        m.isEnabled = !running
        menu.addItem(m)

        // 自動停止
        let d = submenu(tr("Stop Automatically", ja: "自動停止"), value: durationLabel(prefs.duration))
        for (i, candidate) in RecordLauncher.durations.enumerated() {
            let it = item(durationLabel(candidate), #selector(selectDuration(_:)))
            it.tag = i
            it.state = candidate == prefs.duration ? .on : .off
            d.submenu?.addItem(it)
        }
        d.isEnabled = !running
        menu.addItem(d)

        let ask = item(tr("Ask for a Session Name", ja: "開始時にセッション名を尋ねる"), #selector(toggleAskName))
        ask.state = prefs.askName ? .on : .off
        menu.addItem(ask)
    }

    private func buildFilesSection(profile: Profile) {
        menu.addItem(item(tr("Open Recordings Folder", ja: "録音のフォルダを開く"), #selector(openURL(_:)), represented: profile.outputDirectoryURL))
        let tools = submenu(tr("Tools", ja: "ツール"), value: nil)
        tools.submenu?.addItem(item(tr("Reveal Config File in Finder", ja: "設定ファイルを Finder で表示"), #selector(revealConfig)))
        tools.submenu?.addItem(item(tr("Run cappy init in Terminal…", ja: "ターミナルで cappy init を実行…"), #selector(runInit)))
        tools.submenu?.addItem(item(tr("Run cappy doctor in Terminal…", ja: "ターミナルで cappy doctor を実行…"), #selector(runDoctor)))
        tools.submenu?.addItem(.separator())
        if let log = job?.logURL ?? lastLog {
            tools.submenu?.addItem(item(tr("Show Last Log", ja: "最後のログを表示"), #selector(openURL(_:)), represented: log))
        }
        tools.submenu?.addItem(item(tr("Open Logs Folder", ja: "ログのフォルダを開く"), #selector(openURL(_:)), represented: AppEnvironment.logDirectory))
        tools.submenu?.addItem(item(tr("Open Privacy & Security Settings", ja: "プライバシーとセキュリティの設定を開く"), #selector(openPrivacySettings)))
        menu.addItem(tools)
    }

    // MARK: - 録音

    @objc private func startRecording(_ sender: NSMenuItem) {
        guard job?.isRunning != true, menuTargets.indices.contains(sender.tag) else { return }
        let target = menuTargets[sender.tag]
        guard let cappy = AppEnvironment.cappyExecutable else {
            showAlert(tr("The cappy command was not found", ja: "cappy コマンドが見つかりません"),
                      tr("Reinstall gcappy (brew reinstall gcappy).", ja: "gcappy を入れ直してください（brew reinstall gcappy）。"), style: .critical)
            return
        }
        let config = loadConfig()
        if let error = config.error {
            showAlert(tr("The config file has an error", ja: "設定ファイルにエラーがあります"), error, style: .warning)
            return
        }
        let profile = currentProfile(config.config)
        let operation = prefs.operation(for: profile)

        var name: String?
        if prefs.askName {
            guard let answer = askSessionName(target: target, profile: profile, operation: operation) else { return }
            name = answer.isEmpty ? nil : answer
        }

        var args = ["record"] + target.arguments + ["--profile", profile.name] + operation.arguments + prefs.mic.arguments
        if let duration = prefs.duration { args += ["--duration", duration] }
        if let name { args += ["--name", name] }
        // 録音の告知はセッション名のダイアログで表示する
        args.append("--quiet")

        do {
            job = try RecordingJob(executable: cappy, arguments: args, environment: AppEnvironment.childEnvironment,
                                   target: target, name: name, profileName: profile.name, operation: operation) { [weak self] job in
                self?.recordingFinished(job)
            }
            prefs.lastTarget = target.preferenceKey ?? prefs.lastTarget
        } catch {
            showAlert(tr("Cannot start cappy", ja: "cappy を起動できません"), "\(error)", style: .critical)
        }
        updateStatusButton()
    }

    /// セッション名を尋ねる（キャンセルなら nil）
    private func askSessionName(target: LaunchTarget, profile: Profile, operation: LaunchOperation) -> String? {
        let alert = NSAlert()
        alert.messageText = tr("Record \(target.name)", ja: "\(target.name) を録音")
        var info = tr("⚠️ Tell the participants and get their consent before recording.", ja: "⚠️ 録音は参加者への告知と同意を得たうえで行ってください。")
        info += "\n\n" + tr("Profile: \(profile.name)\nAfter recording: \(operation.label)\nMicrophone: \(prefs.mic.label)",
                            ja: "プロファイル: \(profile.name)\n録音の後: \(operation.label)\nマイク: \(prefs.mic.label)")
        if let d = prefs.duration { info += "\n" + tr("Stop automatically: \(d)", ja: "自動停止: \(d)") }
        info += "\n\n" + tr("Session name (optional):", ja: "セッション名（省略可）:")
        alert.informativeText = info
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = tr("e.g. weekly-sync", ja: "例: weekly-sync")
        alert.accessoryView = field
        alert.addButton(withTitle: tr("Start Recording", ja: "録音を開始"))
        alert.addButton(withTitle: tr("Cancel", ja: "キャンセル"))
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recordingFinished(_ job: RecordingJob) {
        lastLog = job.logURL
        if let dir = job.sessionDirectory, FileManager.default.fileExists(atPath: dir.path) { lastSession = dir }
        updateStatusButton()
        if quitPending { return }
        let status = job.exitStatus ?? 0
        if status == 0 {
            let what: String
            switch job.operation {
            case .record: what = tr("The recording was saved.", ja: "録音を保存しました。")
            case .transcribe, .live: what = tr("The recording and transcript were saved.", ja: "録音と文字起こしを保存しました。")
            case .summarize, .liveSummarize: what = tr("The recording, transcript and summary were saved.", ja: "録音・文字起こし・要約を保存しました。")
            }
            notify(title: tr("gcappy: done", ja: "gcappy: 完了しました"),
                   body: what + (job.sessionDirectory.map { "\n" + $0.lastPathComponent } ?? ""))
        } else if (job.recordingStartedAt == nil && job.stopRequested) || job.processingCancelled {
            // 録音を始める前に中止した、または録音後の処理を中断した
            return
        } else {
            let tail = job.logTail()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = tr("cappy ended with an error (exit code \(status))", ja: "cappy がエラーで終了しました（終了コード \(status)）")
            var info = tail
            if status == ExitStatus.permission.rawValue {
                info += "\n\n" + tr("Allow gcappy in System Settings > Privacy & Security > Microphone / Screen & System Audio Recording.",
                                    ja: "システム設定 > プライバシーとセキュリティ > マイク / 画面とシステムオーディオ録音 で gcappy を許可してください。")
            }
            if job.recordingStartedAt != nil, let dir = job.sessionDirectory {
                info += "\n\n" + tr("To resume the transcription: cappy transcribe \(dir.path)", ja: "文字起こしの再開: cappy transcribe \(dir.path)")
            }
            alert.informativeText = info
            alert.addButton(withTitle: tr("OK", ja: "OK"))
            alert.addButton(withTitle: tr("Show Log", ja: "ログを表示"))
            if status == ExitStatus.permission.rawValue {
                alert.addButton(withTitle: tr("Open Settings", ja: "設定を開く"))
            }
            NSApp.activate()
            switch alert.runModal() {
            case .alertSecondButtonReturn: _ = NSWorkspace.shared.open(job.logURL)
            case .alertThirdButtonReturn: openPrivacySettings()
            default: break
            }
        }
    }

    @objc private func stopRecording() {
        job?.stop()
        updateStatusButton()
    }

    @objc private func cancelProcessing() {
        guard let job else { return }
        let ok = confirm(tr("Cancel the processing?", ja: "処理を中断しますか？"),
                         tr("The recording is kept. Resume later with `cappy transcribe <session folder>`.",
                            ja: "録音は残ります。あとで `cappy transcribe <セッションのフォルダ>` で再開できます。"),
                         ok: tr("Cancel Processing", ja: "中断する"))
        if ok { job.cancelProcessing() }
    }

    @objc private func toggleMute() {
        guard let job else { return }
        do {
            try job.setMuted(!job.isMuted)
        } catch {
            showAlert(tr("Cannot change the mute", ja: "ミュートを切り替えられません"), "\(error)", style: .warning)
        }
        // 録音プロセスが登録簿を更新するのを少し待ってからアイコンを更新する
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            self.job?.refresh()
            self.updateStatusButton()
        }
    }

    @objc private func takeScreenshot() {
        do {
            try job?.requestScreenshot()
        } catch {
            showAlert(tr("Cannot take a screenshot", ja: "スクリーンショットを撮れません"), "\(error)", style: .warning)
        }
    }

    @objc private func toggleOtherMute(_ sender: NSMenuItem) {
        guard otherRecordings.indices.contains(sender.tag),
              let e = RecordingRegistry.entry(pid: otherRecordings[sender.tag].pid) else { return }
        do { try RecordingRegistry.request(muted: !e.micMuted, of: e) } catch {
            showAlert(tr("Cannot change the mute", ja: "ミュートを切り替えられません"), "\(error)", style: .warning)
        }
    }

    @objc private func otherScreenshot(_ sender: NSMenuItem) {
        guard otherRecordings.indices.contains(sender.tag),
              let e = RecordingRegistry.entry(pid: otherRecordings[sender.tag].pid) else { return }
        do { try RecordingRegistry.requestScreenshot(of: e) } catch {
            showAlert(tr("Cannot take a screenshot", ja: "スクリーンショットを撮れません"), "\(error)", style: .warning)
        }
    }

    @objc private func stopOther(_ sender: NSMenuItem) {
        // 登録簿で PID と開始時刻が一致することを確かめてから送る
        guard otherRecordings.indices.contains(sender.tag),
              let e = RecordingRegistry.entry(pid: otherRecordings[sender.tag].pid) else { return }
        kill(e.pid, SIGINT)
    }

    // MARK: - 設定

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard menuProfiles.indices.contains(sender.tag) else { return }
        prefs.profileName = menuProfiles[sender.tag].name
    }

    @objc private func selectOperation(_ sender: NSMenuItem) {
        guard menuOperations.indices.contains(sender.tag) else { return }
        prefs.setOperation(menuOperations[sender.tag])
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        guard LaunchMic.allCases.indices.contains(sender.tag) else { return }
        prefs.mic = LaunchMic.allCases[sender.tag]
    }

    @objc private func selectDuration(_ sender: NSMenuItem) {
        guard RecordLauncher.durations.indices.contains(sender.tag) else { return }
        prefs.duration = RecordLauncher.durations[sender.tag]
    }

    @objc private func toggleAskName() {
        prefs.askName.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            showAlert(tr("Cannot change the login item", ja: "ログイン項目を変更できません"), error.localizedDescription, style: .warning)
        }
    }

    private func loadConfig() -> (config: CappyConfig?, error: String?) {
        do {
            return (try CappyConfig.load(), nil)
        } catch let e as CappyError {
            return (nil, e.description)
        } catch {
            return (nil, "\(error)")
        }
    }

    /// 選んでいるプロファイル（設定ファイルから消えていれば default、なければ先頭）
    private func currentProfile(_ config: CappyConfig?) -> Profile {
        guard let config else { return Profile(name: "default") }
        if let name = prefs.profileName, let p = config.profiles[name] { return p }
        if let p = config.profiles["default"] { return p }
        return RecordLauncher.orderedProfiles(config).first ?? Profile(name: "default")
    }

    private func durationLabel(_ d: String?) -> String {
        d ?? tr("Off (stop manually)", ja: "なし（手動で停止）")
    }

    // MARK: - ファイルとツール

    @objc private func openURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        // まだない録音のフォルダ（初回の録音前など）は作ってから開く
        if url.hasDirectoryPath && !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealConfig() {
        let path = CappyConfig.defaultPath
        if FileManager.default.fileExists(atPath: path.path) {
            NSWorkspace.shared.activateFileViewerSelecting([path])
        } else {
            showAlert(tr("No config file yet", ja: "設定ファイルがまだありません"),
                      tr("Create \(path.path) with `cappy init`.", ja: "`cappy init` で \(path.path) を作成してください。"), style: .informational)
        }
    }

    @objc private func runInit() { runInTerminal(["init"]) }

    @objc private func runDoctor() { runInTerminal(["doctor"]) }

    /// 同梱の cappy をターミナルで実行する（対話が必要な init など）
    private func runInTerminal(_ args: [String]) {
        guard let cappy = AppEnvironment.cappyExecutable else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gcappy", isDirectory: true)
        let script = dir.appendingPathComponent("cappy-\(args.joined(separator: "-")).command")
        let command = ([cappy.path] + args).map(RecordingJob.shellQuote).joined(separator: " ")
        let body = """
        #!/bin/bash
        clear
        \(command)
        echo
        read -n 1 -s -r -p "\(tr("Press any key to close", ja: "何かキーを押すと閉じます"))"
        echo

        """
        do {
            try FileSecurity.createPrivateDirectory(dir)
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            showAlert(tr("Cannot open Terminal", ja: "ターミナルを開けません"), "\(error)", style: .warning)
        }
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "gcappy",
            .applicationVersion: CappyVersion.current,
            .version: "",
            .credits: NSAttributedString(string: tr("Menu bar app for cappy: records a meeting app's audio and your microphone as separate tracks, then transcribes and summarizes them.",
                                                    ja: "cappy のメニューバー版。会議アプリの音声とマイク音声を別トラックで録音し、文字起こし・要約します。")),
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 部品

    private func item(_ title: String, _ action: Selector, key: String = "", represented: Any? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        it.representedObject = represented
        return it
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    /// 現在の値を右に添えたサブメニュー
    private func submenu(_ title: String, value: String?) -> NSMenuItem {
        let it = NSMenuItem(title: value.map { "\(title): \($0)" } ?? title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        it.submenu = sub
        return it
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func showAlert(_ message: String, _ info: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = info
        NSApp.activate()
        alert.runModal()
    }

    private func confirm(_ message: String, _ info: String, ok: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: tr("Cancel", ja: "キャンセル"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func notify(title: String, body: String) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
