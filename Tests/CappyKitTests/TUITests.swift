import CoreAudio
import Foundation
import Testing
@testable import CappyKit

@Suite struct TUIKeyParserTests {
    private func keys(_ bytes: [UInt8]) -> [TUIKey] {
        var p = TUIKeyParser()
        return bytes.compactMap { p.feed($0) }
    }

    @Test func arrowsAndControlKeys() {
        #expect(keys(Array("\u{1B}[A\u{1B}[B\u{1B}[C\u{1B}[D".utf8)) == [.up, .down, .right, .left])
        #expect(keys(Array("\u{1B}OA\u{1B}OB".utf8)) == [.up, .down])
        #expect(keys(Array("\u{1B}[1;5A".utf8)) == [.up]) // Ctrl+↑ も ↑
        #expect(keys(Array("\u{1B}[Z".utf8)) == [.backTab])
        #expect(keys([0x0D, 0x0A, 0x09, 0x7F, 0x15, 0x03]) == [.enter, .enter, .tab, .backspace, .clearLine, .interrupt])
    }

    @Test func utf8Characters() {
        #expect(keys(Array("aあ🎤".utf8)) == [.char("a"), .char("あ"), .char("🎤")])
    }

    @Test func loneEscapeNeedsTimeout() {
        var p = TUIKeyParser()
        #expect(p.feed(0x1B) == nil)
        #expect(p.awaitingEscape)
        #expect(p.timeout() == .escape)
        #expect(!p.awaitingEscape)
        #expect(p.timeout() == nil)
        // Alt+x は無視して、次のキーは普通に読む
        #expect(p.feed(0x1B) == nil)
        #expect(p.feed(UInt8(ascii: "x")) == nil)
        #expect(p.feed(UInt8(ascii: "q")) == .char("q"))
    }

    @Test func displayWidthSlice() {
        #expect(DisplayWidth.slice("abcdef", from: 1, to: 4) == "bcd")
        #expect(DisplayWidth.slice("日本語", from: 1, to: 5) == " 本 ") // 境界にかかった全角は空白に
        #expect(DisplayWidth.slice("ab", from: 0, to: 4) == "ab  ")
    }

    @Test func displayWidthFit() {
        #expect(DisplayWidth.of("abc") == 3)
        #expect(DisplayWidth.of("日本") == 4)
        #expect(DisplayWidth.fit("abc", 5) == "abc  ")
        #expect(DisplayWidth.fit("abcdef", 4) == "abc…")
        #expect(DisplayWidth.fit("日本語です", 6) == "日本… ")
    }
}

@Suite struct RecordLauncherTests {
    private func process(_ pid: Int32, _ bundle: String, _ name: String, playing: Bool = false, app: Bool = true) -> AudioProcessInfo {
        AudioProcessInfo(objectID: AudioObjectID(pid), pid: pid, bundleID: bundle, name: name,
                         isRunningOutput: playing, isRunningInput: false, isUserApp: app)
    }

    @Test func appsComeBeforeDaemons() {
        let list = LaunchTarget.group([
            process(1, "com.apple.assistantd", "assistantd", app: false),
            process(2, "com.apple.corespeechd", "corespeechd", playing: true, app: false),
            process(3, "us.zoom.xos", "zoom.us"),
        ])
        #expect(list.map(\.kind) == [.app("com.apple.corespeechd"), .app("us.zoom.xos"), .app("com.apple.assistantd"), .system])
        #expect(!list[2].isApp)
    }

    @Test func userAppPaths() {
        #expect(AudioProcesses.isUserAppPath("/Applications/zoom.us.app/Contents/MacOS/zoom.us"))
        #expect(AudioProcesses.isUserAppPath("/System/Applications/Music.app/Contents/MacOS/Music"))
        #expect(!AudioProcesses.isUserAppPath("/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"))
        #expect(!AudioProcesses.isUserAppPath("/usr/libexec/audiomxd"))
    }

    private func profile(_ name: String, provider: String = "google", summary: String? = nil, auto: Bool = false) -> Profile {
        var p = Profile(name: name)
        p.provider = provider
        p.summary.provider = summary
        p.summary.auto = auto
        return p
    }

    @Test func groupsHelpersUnderTheApp() {
        let list = LaunchTarget.group([
            process(10, "com.google.Chrome", "Google Chrome"),
            process(11, "com.google.Chrome.helper", "Google Chrome (Google Chrome Helper)", playing: true),
            process(12, "com.google.Chrome.helper.renderer", "Google Chrome (Google Chrome Helper (Renderer))"),
            process(20, "us.zoom.xos", "zoom.us"),
            process(30, "", "afplay", playing: true),
            process(99, "dev.cappy", "cappy"),
        ], excludingPID: 99)
        // 出力中が先、あとは名前順（大文字小文字は区別しない）、最後にシステム全体
        #expect(list.map(\.kind) == [.pid(30), .app("com.google.Chrome"), .app("us.zoom.xos"), .system])
        #expect(list[1].name == "Google Chrome")
        #expect(list[1].isPlaying)
        #expect(list[1].processCount == 3)
        #expect(list[1].arguments == ["--app", "com.google.Chrome"])
        #expect(list[0].arguments == ["--pid", "30"])
        #expect(list[3].arguments == ["--system"])
    }

    @Test func helperOnlyAppKeepsItsBundleID() {
        let list = LaunchTarget.group([process(11, "com.google.Chrome.helper", "Google Chrome (Google Chrome Helper)")])
        #expect(list.first?.kind == .app("com.google.Chrome.helper"))
        #expect(list.first?.name == "Google Chrome")
    }

    @Test func operationsFollowTheProfile() {
        #expect(LaunchOperation.available(for: profile("a", provider: "none")) == [.record])
        #expect(LaunchOperation.available(for: profile("a", summary: "none")) == [.record, .transcribe, .live])
        #expect(LaunchOperation.available(for: profile("a")) == LaunchOperation.allCases)
        #expect(LaunchOperation.preferred(for: profile("a")) == .transcribe)
        #expect(LaunchOperation.preferred(for: profile("a", auto: true)) == .summarize)
        #expect(LaunchOperation.preferred(for: profile("a", provider: "none")) == .record)
    }

    @Test func startsRecordingWithTheChosenSettings() {
        var l = RecordLauncher(profiles: [profile("default"), profile("aws", provider: "none")])
        l.update(targets: LaunchTarget.group([process(20, "us.zoom.xos", "zoom.us", playing: true)]))
        // 初期位置は一覧の先頭なので、そのまま Enter で始められる
        #expect(l.handle(.enter) == .start(["--app", "us.zoom.xos", "--profile", "default", "--transcribe", "--no-summarize"]))

        // 設定の行へ上がって変更する
        for _ in 0..<5 { _ = l.handle(.up) }
        #expect(l.row == .field(.profile))
        _ = l.handle(.right) // プロファイル → aws（provider none なので録音のみ）
        #expect(l.profile.name == "aws")
        #expect(l.operation == .record)
        _ = l.handle(.down)  // 操作
        _ = l.handle(.right) // 操作は 1 つだけなので変わらない
        #expect(l.operation == .record)
        _ = l.handle(.down)  // マイク
        _ = l.handle(.right)
        #expect(l.mic == .muted)
        _ = l.handle(.down)  // 自動停止
        _ = l.handle(.left)  // 先頭から左で末尾へ
        #expect(l.duration == "3h")
        _ = l.handle(.down)  // セッション名
        #expect(l.handle(.char("x")) == nil) // Enter を押すまでは入力にならない
        #expect(l.name == "")
        #expect(!l.editingName)
        _ = l.handle(.enter) // 編集を始める
        #expect(l.editingName)
        for c in ["週", "次", " ", "q"] { #expect(l.handle(.char(c)) == nil) } // 編集中の q は終了しない
        _ = l.handle(.backspace)
        #expect(l.name == "週次 ")
        _ = l.handle(.enter) // 確定（行はそのまま）
        #expect(!l.editingName)
        #expect(l.row == .field(.name))
        _ = l.handle(.enter) // もう一度編集して Esc で取り消す
        _ = l.handle(.clearLine)
        _ = l.handle(.char("x"))
        _ = l.handle(.escape)
        #expect(!l.editingName)
        #expect(l.name == "週次 ")
        _ = l.handle(.down)  // 一覧へ
        #expect(l.handle(.enter) == .start(["--app", "us.zoom.xos", "--profile", "aws", "--muted", "--duration", "3h", "--name", "週次"]))
    }

    @Test func keepsTheSelectionWhenTheListChanges() {
        var l = RecordLauncher(profiles: [])
        #expect(l.profile.name == "default")
        l.update(targets: LaunchTarget.group([process(20, "us.zoom.xos", "zoom.us"), process(30, "com.apple.Music", "Music")]))
        _ = l.handle(.down) // Music → zoom.us
        #expect(l.selectedTarget?.kind == .app("us.zoom.xos"))
        // zoom が音を出し始めて先頭に来ても、選択は zoom のまま
        l.update(targets: LaunchTarget.group([process(20, "us.zoom.xos", "zoom.us", playing: true), process(30, "com.apple.Music", "Music")]))
        #expect(l.selectedTarget?.kind == .app("us.zoom.xos"))
        #expect(l.handle(.char("q")) == .quit)
        #expect(l.handle(.interrupt) == .quit)
        #expect(l.handle(.char("r")) == .refresh)
    }

    @Test func enterOpensTheListOfChoices() {
        var l = RecordLauncher(profiles: [profile("default"), profile("aws"), profile("rec", provider: "none")])
        for _ in 0..<5 { _ = l.handle(.up) }
        #expect(l.row == .field(.profile))
        _ = l.handle(.enter)
        #expect(l.picker == .init(field: .profile, index: 0))
        #expect(l.options(for: .profile).count == 3)
        _ = l.handle(.down)
        _ = l.handle(.down)
        _ = l.handle(.down) // 末尾で止まる
        #expect(l.picker?.index == 2)
        #expect(l.profile.name == "default") // 決めるまでは変わらない
        #expect(l.handle(.char("q")) == nil) // リストを開いている間の q は閉じるだけ
        #expect(l.picker == nil)
        #expect(l.profile.name == "default")

        _ = l.handle(.enter)
        _ = l.handle(.down)
        _ = l.handle(.down)
        _ = l.handle(.enter) // rec に決める
        #expect(l.picker == nil)
        #expect(l.profile.name == "rec")
        #expect(l.operation == .record)
        #expect(l.row == .field(.profile))

        _ = l.handle(.down) // 操作（rec は録音のみ）
        _ = l.handle(.enter)
        #expect(l.options(for: .operation).count == 1)
        _ = l.handle(.escape)
        #expect(l.picker == nil)

        _ = l.handle(.down) // マイク
        _ = l.handle(.enter)
        _ = l.handle(.down)
        _ = l.handle(.down)
        _ = l.handle(.enter)
        #expect(l.mic == .off)

        _ = l.handle(.down) // 自動停止
        _ = l.handle(.enter)
        _ = l.handle(.down)
        _ = l.handle(.down)
        let (lines, _) = l.render(width: 80, height: 40)
        // ウィンドウを重ねても行数と幅は変わらない
        #expect(lines.count == 40)
        #expect(lines.allSatisfy { DisplayWidth.of($0.text) == 80 })
        #expect(lines.contains { $0.segments.contains { $0.style == .selected && $0.text.contains("1h") } })
        #expect(lines.contains { $0.text.contains("│ ✓ " + RecordLauncher.describeDuration(nil)) })
        #expect(lines.contains { $0.text.contains("┌") })
        _ = l.handle(.enter)
        #expect(l.duration == "1h")
        _ = l.handle(.enter)
        #expect(l.handle(.interrupt) == .quit) // リストを開いていても Ctrl-C は終了
    }

    @Test func editingShowsTheTextCursorAndArrowsFinishEditing() {
        var l = RecordLauncher(profiles: [profile("default")])
        _ = l.handle(.up) // セッション名
        #expect(l.render(width: 80, height: 24).cursor == nil)
        #expect(l.handle(.char("q")) == .quit) // 編集中でなければ q は終了
        _ = l.handle(.enter)
        _ = l.handle(.char("a"))
        #expect(l.render(width: 80, height: 24).cursor != nil)
        #expect(l.handle(.up) == nil) // 確定して上の行へ
        #expect(!l.editingName)
        #expect(l.name == "a")
        #expect(l.row == .field(.duration))
    }

    @Test func renderFitsTheScreen() {
        var l = RecordLauncher(profiles: [profile("default")])
        let many = (0..<50).map { process(Int32(100 + $0), "com.example.app\($0)", "App \($0)") }
        l.update(targets: LaunchTarget.group(many))
        for _ in 0..<30 { _ = l.handle(.down) }
        let (lines, cursor) = l.render(width: 60, height: 20)
        #expect(lines.count == 20)
        #expect(lines.allSatisfy { DisplayWidth.of($0.text) == 60 })
        #expect(lines.contains { $0.style == .selected && $0.text.contains("App ") })
        #expect(cursor == nil)
    }
}

@Suite struct RecordingScreenTests {
    @Test func wrapSplitsByWidthAndNewlines() {
        #expect(DisplayWidth.wrap("abcdef", 4) == ["abcd", "ef"])
        #expect(DisplayWidth.wrap("あいう", 4) == ["あい", "う"])
        #expect(DisplayWidth.wrap("a\nb", 4) == ["a", "b"])
        #expect(DisplayWidth.wrap("", 4) == [""])
    }

    @Test func keepsTheNewestMessagesThatFit() {
        let log = (1...50).map { "message \($0)" }
        let screen = RecordingScreen(title: "● 録音中", details: [("録音対象", "zoom.us  (us.zoom.xos)"), ("操作", "録音のみ")],
                                     status: "● 録音中 00:00:05  相手 ▮▮▯▯▯", log: log, help: "Ctrl-C: 停止して保存")
        let lines = screen.render(width: 60, height: 20)
        #expect(lines.count == 20)
        #expect(lines.allSatisfy { DisplayWidth.of($0.text) == 60 })
        #expect(lines[0].text.contains("● 録音中"))
        #expect(lines.contains { $0.text.contains("録音対象  zoom.us") })
        #expect(lines.contains { $0.style == .heading && $0.text.contains("00:00:05") })
        #expect(lines.contains { $0.text.contains("message 50") })
        #expect(!lines.contains { $0.text.contains("message 1 ") })
        #expect(lines.last?.text.contains("Ctrl-C") == true)
    }

    @Test func noticeOfTheLastRecording() {
        var l = RecordLauncher(profiles: [Profile(name: "default")])
        #expect(l.handle(.char("l")) == nil) // 前回の録音がなければ何もしない
        l.notice = .init(text: "終わりました: /tmp/rec/2026-11-12T1400", isError: false)
        #expect(l.handle(.char("l")) == .showLog)
        let (lines, _) = l.render(width: 80, height: 24)
        #expect(lines[1].text.contains("✓ 終わりました: /tmp/rec/2026-11-12T1400"))
        #expect(lines[1].style == .heading)
        l.notice = .init(text: "project_id が設定されていません", isError: true)
        let (errorLines, _) = l.render(width: 80, height: 24)
        #expect(errorLines[1].text.contains("✗ project_id"))
        #expect(errorLines.count == 24)
    }

    @Test func summaryListsTheChoices() {
        var p = Profile(name: "default")
        p.provider = "none"
        var l = RecordLauncher(profiles: [p])
        l.update(targets: [LaunchTarget(kind: .app("us.zoom.xos"), name: "zoom.us", isPlaying: true, processCount: 1)])
        let rows = L10n.$override.withValue(.en) { l.summary(for: l.selectedTarget!) }
        #expect(rows.map(\.label) == ["Target", "Profile", "Operation", "Mic"])
        #expect(rows[0].value == "zoom.us  (us.zoom.xos)")
    }
}
