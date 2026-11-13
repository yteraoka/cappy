import AVFoundation
import Foundation
import Testing
@testable import CappyKit

@Suite struct SessionBrowserTests {
    /// 録音・変換・文字起こし・要約まで終わったセッションを作る
    private func makeSession(in parent: URL, _ dirName: String, name: String?, started: String,
                             transcript: Bool = true, summary: Bool = true, audio: Bool = true) throws -> URL {
        let dir = parent.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var meta = SessionMetadata(id: UUID().uuidString, name: name)
        meta.startedAt = started
        meta.profile = "default"
        meta.targets = [SessionTarget(kind: .app, bundleID: "us.zoom.xos")]
        meta.recording.state = .converted
        meta.markers = [SessionMarker(atMs: 5_000, label: "決定事項")]
        for (id, freq) in [(TrackID.mic, 300.0), (.remote, 440.0)] {
            var t = SessionTrack(id: id, file: "\(id.rawValue).caf", sampleRate: 48_000, channels: 1, offsetMs: id == .mic ? 500 : 0)
            t.durationMs = 1_000
            if audio {
                try TestSupport.writeSineCAF(dir.appendingPathComponent(t.file), seconds: 1, channels: 1, frequency: freq)
                let r = try SendFileConverter.convert(input: dir.appendingPathComponent(t.file), outputBase: dir.appendingPathComponent(id.rawValue))
                t.sendFile = r.url.lastPathComponent
            }
            meta.tracks.append(t)
        }
        if transcript { try "# 文字起こし\n\n自分: こんにちは".write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8) }
        if summary {
            var s = SummaryState(provider: "google", model: "gemini-4-argon", region: "global")
            s.state = .done
            s.file = "summary.md"
            meta.summary = s
            try "# 要約\n\n- 決定事項".write(to: dir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        }
        try SessionStore.encode(meta).write(to: dir.appendingPathComponent(SessionStore.fileName))
        return dir
    }

    @Test func scanFindsSessionsNewestFirst() throws {
        let root = try TestSupport.tempDir()
        let a = try makeSession(in: root, "2026-11-10T1000_old", name: "old", started: "2026-11-10T01:00:00.000Z", summary: false, audio: false)
        let b = try makeSession(in: root, "2026-11-12T2244_weekly-sync", name: "weekly-sync", started: "2026-11-12T13:44:00.000Z")
        // session.json がなく CAF だけ残ったもの（異常終了）も出す
        let broken = root.appendingPathComponent("2026-11-11T0900")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try TestSupport.writeSineCAF(broken.appendingPathComponent("remote.caf"), seconds: 0.1, channels: 1)
        // 関係ないディレクトリは出さない
        try FileManager.default.createDirectory(at: root.appendingPathComponent("other"), withIntermediateDirectories: true)

        let entries = SessionCatalog.scan([root, root]) // 同じ保存先が重なっても 1 回だけ
        #expect(entries.map(\.directory.lastPathComponent) == [b.lastPathComponent, broken.lastPathComponent, a.lastPathComponent])
        let e = entries[0]
        #expect(e.title == "weekly-sync")
        #expect(e.target == "us.zoom.xos")
        #expect(e.durationMs == 1_000)
        #expect(e.transcript != nil && e.summary != nil && e.liveTranscript == nil)
        #expect(e.audio(.remote)?.lastPathComponent == "remote.caf")
        #expect(e.canPlayMix)
        #expect(entries[1].metadata == nil)
        #expect(entries[1].audio(.remote) != nil)
        #expect(!entries[2].canPlayMix)
    }

    @Test func operationsAndShortcuts() throws {
        let root = try TestSupport.tempDir()
        _ = try makeSession(in: root, "2026-11-12T2244_weekly-sync", name: "weekly-sync", started: "2026-11-12T13:44:00.000Z")
        _ = try makeSession(in: root, "2026-11-10T1000", name: nil, started: "2026-11-10T01:00:00.000Z",
                            transcript: false, summary: false, audio: false)
        var b = SessionBrowser(directories: [root])
        b.update(entries: SessionCatalog.scan([root]))
        let e = try #require(b.selected)
        #expect(b.operations(for: e) == [.viewTranscript, .viewSummary, .playMix, .open(.remote), .open(.mic), .reveal, .delete])

        guard case .view(_, let url)? = b.handle(.char("t")) else { Issue.record("t should show the transcript"); return }
        #expect(url.lastPathComponent == "transcript.md")
        guard case .view(_, let summaryURL)? = b.handle(.char("s")) else { Issue.record("s should show the summary"); return }
        #expect(summaryURL.lastPathComponent == "summary.md")
        #expect(b.handle(.char("p")) == .playMix(e))
        #expect(b.handle(.char("f")) == .open(e.directory))

        // Enter でメニューを開き、↓ で選んで Enter
        #expect(b.handle(.enter) == nil)
        #expect(b.menu == 0)
        for _ in 0..<3 { _ = b.handle(.down) }
        #expect(b.handle(.enter) == .open(e.directory.appendingPathComponent("remote.caf")))
        #expect(b.menu == nil)
        // メニューは Esc で閉じるだけ（終了しない）
        _ = b.handle(.enter)
        #expect(b.handle(.escape) == nil)
        #expect(b.menu == nil)

        // ファイルがないセッションでは、ショートカットは何もしない
        _ = b.handle(.down)
        let empty = try #require(b.selected)
        #expect(b.operations(for: empty) == [.reveal, .delete])
        #expect(b.handle(.char("t")) == nil)
        #expect(b.handle(.tab) == .switchPage)
        #expect(b.handle(.char("q")) == .quit)
    }

    @Test func deleteAsksBeforeMovingToTheTrash() throws {
        let root = try TestSupport.tempDir()
        _ = try makeSession(in: root, "2026-11-12T2244_weekly-sync", name: "weekly-sync", started: "2026-11-12T13:44:00.000Z", audio: false)
        var b = SessionBrowser(directories: [root])
        b.update(entries: SessionCatalog.scan([root], active: []))
        let e = try #require(b.selected)

        // d で確認を出す。初めはキャンセルを選んでいるので、そのまま Enter では消さない
        #expect(b.handle(.char("d")) == nil)
        #expect(b.confirmDelete == 0)
        let lines = L10n.$override.withValue(.ja) { b.render(width: 100, height: 24) }
        #expect(lines.contains { $0.text.contains("「weekly-sync」を削除しますか？") })
        #expect(b.handle(.enter) == nil)
        #expect(b.confirmDelete == nil)

        // ↓ で「ゴミ箱に移動する」を選んで Enter
        _ = b.handle(.char("d"))
        _ = b.handle(.down)
        #expect(b.handle(.enter) == .trash(e))

        // y でも移す。Esc・n・ほかのキーは取り消し
        _ = b.handle(.char("d"))
        #expect(b.handle(.char("y")) == .trash(e))
        _ = b.handle(.char("d"))
        #expect(b.handle(.char("n")) == nil)
        #expect(b.confirmDelete == nil)
        _ = b.handle(.char("d"))
        #expect(b.handle(.escape) == nil)
        #expect(b.handle(.char("q")) == .quit) // 確認を閉じた後の q は終了

        // メニューからも選べる（最後の項目）
        var m = SessionBrowser(directories: [root])
        m.update(entries: SessionCatalog.scan([root], active: []))
        _ = m.handle(.enter)
        _ = m.handle(.end)
        #expect(m.handle(.enter) == nil)
        #expect(m.confirmDelete == 0)
    }

    @Test func summarizeIsOfferedOnlyWithoutASummary() throws {
        let root = try TestSupport.tempDir()
        let done = try makeSession(in: root, "2026-11-12T2244_done", name: "done", started: "2026-11-12T13:44:00.000Z", audio: false)
        let todo = try makeSession(in: root, "2026-11-11T1000_todo", name: "todo", started: "2026-11-11T01:00:00.000Z", summary: false, audio: false)
        let live = try makeSession(in: root, "2026-11-10T1000_live", name: "live", started: "2026-11-10T01:00:00.000Z",
                                   transcript: false, summary: false, audio: false)
        _ = try makeSession(in: root, "2026-11-09T1000_none", name: "none", started: "2026-11-09T01:00:00.000Z",
                            transcript: false, summary: false, audio: false)
        for dir in [done, todo] { try Data("{}".utf8).write(to: dir.appendingPathComponent("transcript.json")) }
        try Data("{}".utf8).write(to: live.appendingPathComponent("live-transcript.json"))

        var b = SessionBrowser(directories: [root])
        b.update(entries: SessionCatalog.scan([root], active: []))
        #expect(b.entries.map(\.canSummarize) == [false, true, true, false])
        #expect(b.entries[1].summarySource?.lastPathComponent == "transcript.json")
        #expect(b.entries[2].summarySource?.lastPathComponent == "live-transcript.json")
        #expect(!b.operations(for: b.entries[0]).contains(.summarize))
        #expect(b.operations(for: b.entries[3]) == [.reveal, .delete])

        // 要約がまだないセッションは、メニューの「要約を表示」の位置に「要約を作成」が出る
        _ = b.handle(.down)
        let e = try #require(b.selected)
        #expect(b.operations(for: e) == [.viewTranscript, .summarize, .reveal, .delete])
        // ショートカットはない（s は要約がないので何もしない）
        #expect(b.handle(.char("s")) == nil)
        _ = b.handle(.enter)
        _ = b.handle(.down)
        // 要約できるプロファイルが渡されていなければ、録音したときのプロファイルでそのまま始める
        #expect(b.handle(.enter) == .summarize(e, profile: "default", model: nil, prompt: nil, force: false))

        // 録音中のものは作らせない
        var active = e
        active.isActive = true
        #expect(!active.canSummarize)
    }

    private func summaryProfile(_ name: String, provider: String = "google", model: String = "gemini-4-argon") -> Profile {
        var p = Profile(name: name)
        p.summary.provider = provider
        p.summary.model = model
        return p
    }

    /// 要約がまだないセッション（transcript.json あり）を 1 つ作り、選んだ状態の一覧を返す
    private func browserWithUnsummarized(profiles: [Profile], summary: Bool = false) throws -> (SessionBrowser, SessionEntry) {
        let root = try TestSupport.tempDir()
        let dir = try makeSession(in: root, "2026-11-11T1000_todo", name: "todo", started: "2026-11-11T01:00:00.000Z", summary: summary, audio: false)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("transcript.json"))
        var b = SessionBrowser(directories: [root], profiles: profiles)
        b.update(entries: SessionCatalog.scan([root], active: []))
        return (b, try #require(b.selected))
    }

    @Test func summarizeAsksForTheProfileAndTheModel() throws {
        var bedrock = summaryProfile("bedrock", provider: "aws", model: "claude-opus-5-5")
        bedrock.summary.region = "jp"
        let (b0, e) = try browserWithUnsummarized(profiles: [summaryProfile("default"), bedrock, summaryProfile("rec", provider: "none")])
        var b = b0
        #expect(b.summaryProfiles.map(\.name) == ["default", "bedrock"]) // none は選ばせない
        _ = b.handle(.enter)
        _ = b.handle(.down) // 要約を作成
        #expect(b.handle(.enter) == nil)
        // 初めは録音したときのプロファイル（default）を選んでいる
        #expect(b.summarizeForm?.step == .profile)
        #expect(b.summarizeForm?.index == 0)
        _ = b.handle(.down)
        guard case .loadModels(let key, let p)? = b.handle(.enter) else {
            Issue.record("no load")
            return
        }
        #expect(p.name == "bedrock")
        #expect(b.summarizeForm?.step == .model)
        #expect(L10n.$override.withValue(.en) { b.formOptions() } == ["claude-opus-5-5 (profile default)", "Checking the available models…"])
        let lines = b.render(width: 100, height: 30)
        #expect(lines.contains { $0.text.contains("claude-opus-5-5") })
        #expect(lines.allSatisfy { DisplayWidth.of($0.text) == 100 })

        // 取得中の行は選べない
        _ = b.handle(.down)
        #expect(b.handle(.enter) == nil)
        b.setModelList(key: key, .success([SummaryModelOption(id: "claude-opus-5-5"), SummaryModelOption(id: "moonshotai.kimi-k3.1")]))
        #expect(b.formOptions().count == 2)
        #expect(b.summarizeForm?.index == 1)
        #expect(b.handle(.enter) == .summarize(e, profile: "bedrock", model: "moonshotai.kimi-k3.1", prompt: nil, force: false))
        #expect(b.summarizeForm == nil)

        // 2 回目は取得済みの一覧を使う。Esc でモデルからプロファイルに戻り、もう一度 Esc で閉じる
        _ = b.handle(.enter)
        _ = b.handle(.down)
        _ = b.handle(.enter)
        _ = b.handle(.down)
        #expect(b.handle(.enter) == nil)
        #expect(b.summarizeForm?.step == .model)
        _ = b.handle(.escape)
        #expect(b.summarizeForm?.step == .profile)
        #expect(b.summarizeForm?.index == 1)
        _ = b.handle(.escape)
        #expect(b.summarizeForm == nil)
    }

    @Test func singleProfileGoesStraightToTheModel() throws {
        let (b0, e) = try browserWithUnsummarized(profiles: [summaryProfile("default")])
        var b = b0
        _ = b.handle(.enter)
        _ = b.handle(.down)
        guard case .loadModels(let key, _)? = b.handle(.enter) else {
            Issue.record("no load")
            return
        }
        #expect(b.summarizeForm?.step == .model)
        b.setModelList(key: key, .failure(CappyError.usage("denied")))
        #expect(L10n.$override.withValue(.en) { b.formOptions() }.last == "✗ Cannot get the models: denied")
        // 失敗の行で Enter を押すと取り直す
        _ = b.handle(.down)
        if case .loadModels(_, _)? = b.handle(.enter) {} else { Issue.record("no retry") }
        // 既定のモデルで始める
        _ = b.handle(.home)
        #expect(b.handle(.enter) == .summarize(e, profile: "default", model: nil, prompt: nil, force: false))
        // プロファイルが 1 つなら Esc で閉じる
        _ = b.handle(.enter)
        _ = b.handle(.down)
        _ = b.handle(.enter)
        _ = b.handle(.escape)
        #expect(b.summarizeForm == nil)
    }

    @Test func summarizedSessionCanBeSummarizedAgain() throws {
        let (b0, e) = try browserWithUnsummarized(profiles: [summaryProfile("default")], summary: true)
        var b = b0
        #expect(!e.canSummarize)
        #expect(e.canResummarize)
        #expect(b.operations(for: e) == [.viewTranscript, .viewSummary, .resummarize, .reveal, .delete])
        _ = b.handle(.enter)
        _ = b.handle(.down)
        _ = b.handle(.down)
        guard case .loadModels(let key, _)? = b.handle(.enter) else {
            Issue.record("no load")
            return
        }
        #expect(b.summarizeForm?.force == true)
        b.setModelList(key: key, .success([SummaryModelOption(id: "gemini-3.5-flash")]))
        _ = b.handle(.down)
        #expect(b.handle(.enter) == .summarize(e, profile: "default", model: "gemini-3.5-flash", prompt: nil, force: true))
    }

    @Test func sessionsBeingRecordedCannotBeDeleted() throws {
        let root = try TestSupport.tempDir()
        let dir = try makeSession(in: root, "2026-11-12T2244_now", name: "now", started: "2026-11-12T13:44:00.000Z", audio: false)
        let active: Set<String> = [SessionCatalog.normalized(dir)]
        var b = SessionBrowser(directories: [root])
        b.update(entries: SessionCatalog.scan([root], active: active))
        let e = try #require(b.selected)
        #expect(e.isActive)
        #expect(!b.operations(for: e).contains(.delete))
        #expect(b.handle(.char("d")) == nil)
        #expect(b.confirmDelete == nil)
        // 一覧を読んだ後に録音が始まっていても、移す直前に確かめて断る
        var stale = e
        stale.isActive = false
        #expect(throws: CappyError.self) { try SessionCatalog.moveToTrash(stale, active: active) }
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func renderShowsListDetailsAndMenu() throws {
        let root = try TestSupport.tempDir()
        _ = try makeSession(in: root, "2026-11-12T2244_weekly-sync", name: "weekly-sync", started: "2026-11-12T13:44:00.000Z")
        var b = SessionBrowser(directories: [root])
        b.update(entries: SessionCatalog.scan([root]))
        var lines = L10n.$override.withValue(.ja) { b.render(width: 100, height: 24) }
        #expect(lines.count == 24)
        #expect(lines.allSatisfy { DisplayWidth.of($0.text) == 100 })
        #expect(lines.contains { $0.style == .selected && $0.text.contains("weekly-sync  (us.zoom.xos)") && $0.text.contains("00:00:01") })
        #expect(lines.contains { $0.text.contains("マーカー: 00:00:05 決定事項") })
        _ = b.handle(.enter)
        lines = L10n.$override.withValue(.ja) { b.render(width: 100, height: 24) }
        #expect(lines.contains { $0.segments.contains { $0.style == .selected && $0.text.contains("文字起こしを表示") } })

        let empty = SessionBrowser(directories: [root.appendingPathComponent("none")]).render(width: 80, height: 10)
        #expect(empty.count == 10)
    }

    @Test func mixedFileIsCreatedOnceAndReused() throws {
        let root = try TestSupport.tempDir()
        let dir = try makeSession(in: root, "2026-11-12T2244_mix-\(UUID().uuidString.prefix(6))", name: "mix", started: "2026-11-12T13:44:00.000Z")
        let entry = try #require(SessionCatalog.load(dir))
        let url = try SessionPlayback.mixedFile(for: entry)
        defer { try? FileManager.default.removeItem(at: url) }
        let f = try AVAudioFile(forReading: url)
        // mic は 0.5 秒遅れて始まるので、全体は 1.5 秒
        #expect(abs(Double(f.length) / f.processingFormat.sampleRate - 1.5) < 0.01)
        let again = try SessionPlayback.mixedFile(for: entry)
        #expect(again == url)

        var noAudio = entry
        noAudio.sendFiles = [:]
        #expect(throws: CappyError.self) { try SessionPlayback.mixedFile(for: noAudio) }
    }

    @Test func pagerScrollsWithinTheText() {
        var p = TextPager(title: "要約", text: (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n# 見出し")
        let lines = p.render(width: 40, height: 12)
        #expect(lines.count == 12)
        #expect(lines[2].text.hasPrefix(" line 1 "))
        #expect(p.handle(.char(" "), width: 40, height: 12) == nil)
        #expect(p.top == 8)
        #expect(p.handle(.end, width: 40, height: 12) == nil)
        #expect(p.top == 101 - 8)
        let last = p.render(width: 40, height: 12)
        #expect(last.contains { $0.style == .heading && $0.text.contains("# 見出し") })
        _ = p.handle(.down, width: 40, height: 12) // 末尾より先には行かない
        #expect(p.top == 101 - 8)
        _ = p.handle(.home, width: 40, height: 12)
        #expect(p.top == 0)
        #expect(p.handle(.char("q"), width: 40, height: 12) == .close)
        #expect(p.handle(.interrupt, width: 40, height: 12) == .quit)
    }

    @Test func pagingKeys() {
        var parser = TUIKeyParser()
        let keys = Array("\u{1B}[5~\u{1B}[6~\u{1B}[H\u{1B}[F\u{1B}[1~\u{1B}[4~".utf8).compactMap { parser.feed($0) }
        #expect(keys == [.pageUp, .pageDown, .home, .end, .home, .end])
    }
}
