import Foundation

/// 過去の録音（セッションディレクトリ）1 つ分
public struct SessionEntry: Equatable, Sendable {
    public var directory: URL
    /// session.json（読めなければ nil。`cappy recover` で作り直せる）
    public var metadata: SessionMetadata?
    public var startedAt: Date?
    public var transcript: URL?
    public var liveTranscript: URL?
    public var summary: URL?
    /// 録音中の原本（CAF）
    public var originals: [TrackID: URL]
    /// 送信用ファイル（16 kHz モノラル）
    public var sendFiles: [TrackID: URL]
    /// 別のプロセスで録音中（削除させない）
    public var isActive = false
    /// 要約の元にする文字起こし（transcript.json、なければ live-transcript.json）
    public var summarySource: URL? = nil

    /// 要約がまだなく、作れるか（文字起こしの結果があり、録音中でない）
    public var canSummarize: Bool {
        summary == nil && summarySource != nil && metadata != nil && !isActive
    }

    /// 要約があり、作り直せるか（別のプロファイル・モデルで作り直すなど）
    public var canResummarize: Bool {
        summary != nil && summarySource != nil && metadata != nil && !isActive
    }

    public var title: String {
        if let n = metadata?.name, !n.isEmpty { return n }
        // "2026-11-12T2244_weekly-sync" の名前の部分
        let base = directory.lastPathComponent
        if let r = base.range(of: "_") { return String(base[r.upperBound...]) }
        return ""
    }

    public var durationMs: Int64? {
        metadata?.tracks.filter { $0.id != .mix }.compactMap(\.durationMs).max()
    }

    /// 相手と自分を合わせて聞けるか（送信用ファイルが 2 本、または --mix で作ったものがある）
    public var canPlayMix: Bool {
        sendFiles[.mix] != nil || (sendFiles[.remote] != nil && sendFiles[.mic] != nil)
    }

    /// 開く音声（原本があれば原本、なければ送信用）
    public func audio(_ track: TrackID) -> URL? { originals[track] ?? sendFiles[track] }

    public var target: String {
        guard let t = metadata?.targets.first else { return "" }
        switch t.kind {
        case .app: return t.bundleID ?? ""
        case .pid: return t.pid.map { "PID \($0)" } ?? ""
        case .system: return tr("system", ja: "システム全体")
        }
    }
}

/// 出力先のディレクトリからセッションを探す
public enum SessionCatalog {
    /// - Parameter active: 録音中のセッションディレクトリ（既定は RecordingRegistry に登録されているもの）
    public static func scan(_ directories: [URL], active: Set<String>? = nil) -> [SessionEntry] {
        let fm = FileManager.default
        let activePaths = active ?? activeSessionPaths()
        var seen = Set<String>()
        var entries: [SessionEntry] = []
        for parent in directories {
            guard let children = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for dir in children {
                let path = dir.standardizedFileURL.path
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, seen.insert(path).inserted else { continue }
                if var e = load(dir) {
                    e.isActive = activePaths.contains(normalized(dir))
                    entries.append(e)
                }
            }
        }
        return entries.sorted { a, b in
            switch (a.startedAt, b.startedAt) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.directory.lastPathComponent > b.directory.lastPathComponent
            }
        }
    }

    /// 録音中の `cappy record` のセッションディレクトリ
    public static func activeSessionPaths() -> Set<String> {
        Set(RecordingRegistry.list().map { normalized(URL(fileURLWithPath: $0.session)) })
    }

    static func normalized(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    /// セッションをゴミ箱に移す（Finder から元に戻せる）。録音中なら移さない
    @discardableResult
    public static func moveToTrash(_ entry: SessionEntry, active: Set<String>? = nil) throws -> URL? {
        guard !(active ?? activeSessionPaths()).contains(normalized(entry.directory)) else {
            throw CappyError.usage(tr("This session is being recorded: \(entry.directory.path)", ja: "このセッションは録音中です: \(entry.directory.path)"))
        }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: entry.directory, resultingItemURL: &trashed)
        SessionPlayback.removeCachedMix(for: entry)
        return trashed as URL?
    }

    /// セッションディレクトリを読む（session.json も CAF もなければ nil）
    public static func load(_ dir: URL) -> SessionEntry? {
        let fm = FileManager.default
        func existing(_ name: String?) -> URL? {
            guard let name else { return nil }
            let u = dir.appendingPathComponent(name)
            return fm.fileExists(atPath: u.path) ? u : nil
        }
        let metaURL = dir.appendingPathComponent(SessionStore.fileName)
        let meta = (try? Data(contentsOf: metaURL)).flatMap { try? SessionStore.decode($0) }
        var originals: [TrackID: URL] = [:]
        var sends: [TrackID: URL] = [:]
        if let meta {
            for t in meta.tracks {
                originals[t.id] = existing(t.file)
                sends[t.id] = existing(t.sendFile)
            }
        } else {
            for t in [TrackID.remote, .mic] {
                originals[t] = existing("\(t.rawValue).caf")
                sends[t] = existing("\(t.rawValue).flac") ?? existing("\(t.rawValue).wav")
            }
            guard !originals.isEmpty || fm.fileExists(atPath: metaURL.path) else { return nil }
        }
        let summarySource = existing(TranscriptFormat.json.fileName)
            ?? existing(TranscriptFormat.json.fileName(base: LiveTranscription.baseName))
        let started = meta?.startedAt.flatMap(TimeFormat.parseISO8601) ?? dateFromDirectoryName(dir.lastPathComponent)
        return SessionEntry(directory: dir, metadata: meta, startedAt: started,
                            transcript: existing("transcript.md"), liveTranscript: existing("live-transcript.md"),
                            summary: existing(meta?.summary?.file) ?? existing("summary.md"),
                            originals: originals.compactMapValues { $0 }, sendFiles: sends.compactMapValues { $0 },
                            summarySource: summarySource)
    }

    /// "2026-11-12T2244_name" → 日時
    static func dateFromDirectoryName(_ name: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HHmm"
        return f.date(from: String(name.prefix(15)))
    }
}

/// 過去の録音を聞くための音声ファイル
public enum SessionPlayback {
    /// 相手と自分をミックスした 1 本。--mix で作ったものがあればそれを、なければ一時ディレクトリに作る
    public static func mixedFile(for entry: SessionEntry) throws -> URL {
        if let mix = entry.sendFiles[.mix] { return mix }
        guard let remote = entry.sendFiles[.remote], let mic = entry.sendFiles[.mic] else {
            throw CappyError.usage(tr("There are no files to send for both tracks; create them with `cappy recover \(entry.directory.path)`",
                                      ja: "2 トラック分の送信用ファイルがありません。`cappy recover \(entry.directory.path)` で作成できます"))
        }
        let base = cacheBase(for: entry)
        try FileSecurity.createPrivateDirectory(base.deletingLastPathComponent())
        // 前に作ったものがあり、送信用ファイルより新しければそのまま使う
        let fm = FileManager.default
        func modified(_ u: URL) -> Date { (try? fm.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast }
        for ext in ["flac", "wav"] {
            let u = base.appendingPathExtension(ext)
            if fm.fileExists(atPath: u.path), modified(u) >= max(modified(remote), modified(mic)) { return u }
        }
        let offset: (TrackID) -> Int64 = { id in entry.metadata?.track(id)?.offsetMs ?? 0 }
        return try SendFileConverter.mix(inputs: [(remote, offset(.remote)), (mic, offset(.mic))], outputBase: base).url
    }

    /// 一時ディレクトリに作ったミックス（拡張子なし）
    static func cacheBase(for entry: SessionEntry) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cappy-playback", isDirectory: true)
            .appendingPathComponent(entry.directory.lastPathComponent + "-mix")
    }

    /// 一時ディレクトリに作ったミックスを消す（セッションを削除したとき）
    public static func removeCachedMix(for entry: SessionEntry) {
        let base = cacheBase(for: entry)
        for ext in ["flac", "wav"] { try? FileManager.default.removeItem(at: base.appendingPathExtension(ext)) }
    }
}

/// 過去の録音の一覧のページ。Enter で操作のメニューを開く
public struct SessionBrowser: Sendable {
    public typealias Line = RecordLauncher.Line

    public enum Operation: Equatable, Sendable {
        case viewTranscript, viewLiveTranscript, viewSummary
        /// 要約を作る（まだないとき）
        case summarize
        /// 要約を作り直す（あるとき）
        case resummarize
        case playMix, open(TrackID), reveal
        /// ゴミ箱に移す（確認してから）
        case delete

        public var label: String {
            switch self {
            case .viewTranscript: return tr("Show the transcript", ja: "文字起こしを表示")
            case .viewLiveTranscript: return tr("Show the live transcript", ja: "リアルタイム文字起こしを表示")
            case .viewSummary: return tr("Show the summary", ja: "要約を表示")
            case .summarize: return tr("Create the summary", ja: "要約を作成")
            case .resummarize: return tr("Create the summary again", ja: "要約を作り直す")
            case .playMix: return tr("Play both tracks mixed", ja: "相手と自分を合わせて再生")
            case .open(.remote): return tr("Open the remote audio", ja: "相手の音声を開く")
            case .open(.mic): return tr("Open the mic audio", ja: "自分の音声を開く")
            case .open: return tr("Open the mixed audio", ja: "ミックスの音声を開く")
            case .reveal: return tr("Show the folder in Finder", ja: "フォルダを Finder で開く")
            case .delete: return tr("Delete (move to the Trash)", ja: "削除（ゴミ箱に移動）")
            }
        }

        /// 一覧で直接押せるキー
        public var shortcut: String? {
            switch self {
            case .viewTranscript: return "t"
            case .viewSummary: return "s"
            case .viewLiveTranscript: return "l"
            case .playMix: return "p"
            case .reveal: return "f"
            case .delete: return "d"
            case .open, .summarize, .resummarize: return nil
            }
        }
    }

    public enum Action: Equatable, Sendable {
        /// テキストを読む
        case view(title: String, url: URL)
        /// 既定のアプリで開く（音声は再生アプリ、フォルダは Finder）
        case open(URL)
        /// ミックスを作って再生アプリで開く
        case playMix(SessionEntry)
        /// 確認を経て、ゴミ箱に移す
        case trash(SessionEntry)
        /// 要約を作る（profile: 使うプロファイル、model: nil ならプロファイルの summary.model、force: 作り直す）
        case summarize(SessionEntry, profile: String, model: String?, force: Bool)
        /// 要約モデルの一覧を取得する（終わったら setModelList を呼ぶ）
        case loadModels(key: String, profile: Profile)
        case switchPage
        case refresh
        case quit
    }

    public private(set) var entries: [SessionEntry] = []
    public private(set) var cursor = 0
    /// 開いているメニューの選んでいる位置
    public private(set) var menu: Int?
    /// 削除の確認を出している（0: キャンセル、1: ゴミ箱に移動）
    public private(set) var confirmDelete: Int?
    /// 一覧の上に出す知らせ（開いた・失敗したなど）
    public var notice: String?
    public var directories: [URL]

    /// 要約に使えるプロファイル（設定ファイルのもの。summary.provider が none のものは選ばせない）
    public var profiles: [Profile]
    /// 取得した要約モデルの一覧（SummaryModelCatalog.cacheKey ごと）
    public private(set) var modelLists: [String: RecordLauncher.ModelList] = [:]

    /// 要約を作る前に、プロファイル → モデルの順に選ぶウィンドウ
    public struct SummarizeForm: Equatable, Sendable {
        public enum Step: Equatable, Sendable { case profile, model }
        public var entry: SessionEntry
        /// 作り直すか
        public var force: Bool
        public var step: Step
        /// summaryProfiles の中で選んだプロファイル
        public var profileIndex: Int
        /// ウィンドウの中で選んでいる位置
        public var index: Int
    }
    public private(set) var summarizeForm: SummarizeForm?

    public init(directories: [URL], profiles: [Profile] = []) {
        self.directories = directories
        self.profiles = profiles
    }

    public var summaryProfiles: [Profile] { profiles.filter { $0.summaryProvider != "none" } }

    public var selected: SessionEntry? { entries.indices.contains(cursor) ? entries[cursor] : nil }

    /// 一覧を新しくする（選んでいたセッションに留まる）
    public mutating func update(entries new: [SessionEntry]) {
        let dir = selected?.directory
        entries = new
        cursor = dir.flatMap { d in new.firstIndex { $0.directory == d } } ?? min(cursor, max(0, new.count - 1))
        if selected == nil {
            menu = nil
            confirmDelete = nil
        }
    }

    /// セッションでできること（ファイルがあるものだけ）
    public func operations(for e: SessionEntry) -> [Operation] {
        var ops: [Operation] = []
        if e.transcript != nil { ops.append(.viewTranscript) }
        if e.liveTranscript != nil { ops.append(.viewLiveTranscript) }
        if e.summary != nil { ops.append(.viewSummary) }
        if e.canSummarize { ops.append(.summarize) }
        if e.canResummarize { ops.append(.resummarize) }
        if e.canPlayMix { ops.append(.playMix) }
        if e.audio(.remote) != nil { ops.append(.open(.remote)) }
        if e.audio(.mic) != nil { ops.append(.open(.mic)) }
        ops.append(.reveal)
        if !e.isActive { ops.append(.delete) }
        return ops
    }

    mutating func action(_ op: Operation, _ e: SessionEntry) -> Action? {
        let name = e.title.isEmpty ? e.directory.lastPathComponent : e.title
        switch op {
        case .viewTranscript: return e.transcript.map { .view(title: tr("Transcript — \(name)", ja: "文字起こし — \(name)"), url: $0) }
        case .viewLiveTranscript: return e.liveTranscript.map { .view(title: tr("Live transcript — \(name)", ja: "リアルタイム文字起こし — \(name)"), url: $0) }
        case .viewSummary: return e.summary.map { .view(title: tr("Summary — \(name)", ja: "要約 — \(name)"), url: $0) }
        case .summarize: return e.canSummarize ? startSummarize(e, force: false) : nil
        case .resummarize: return e.canResummarize ? startSummarize(e, force: true) : nil
        case .playMix: return .playMix(e)
        case .open(let t): return e.audio(t).map(Action.open)
        case .reveal: return .open(e.directory)
        case .delete:
            // すぐには消さず、確認を出す（初めはキャンセルを選んでおく）
            guard !e.isActive else { return nil }
            confirmDelete = 0
            return nil
        }
    }

    /// 削除の確認のキー。y か「ゴミ箱に移動」を選んで Enter で移す。それ以外は取り消し
    private mutating func handleConfirm(_ key: TUIKey, _ choice: Int, _ e: SessionEntry) -> Action? {
        switch key {
        case .interrupt: return .quit
        case .up, .down, .left, .right, .tab, .backTab, .char("k"), .char("j"):
            confirmDelete = 1 - choice
            return nil
        case .enter:
            confirmDelete = nil
            return choice == 1 ? .trash(e) : nil
        case .char("y"), .char("Y"):
            confirmDelete = nil
            return .trash(e)
        default:
            confirmDelete = nil
            return nil
        }
    }

    // MARK: 要約のプロファイルとモデル

    /// 要約のプロファイル・モデルを選ぶウィンドウを開く。初めは録音したときのプロファイルを選んでおき、
    /// 選べるプロファイルが 1 つならモデルから選ぶ
    mutating func startSummarize(_ e: SessionEntry, force: Bool) -> Action? {
        let list = summaryProfiles
        guard !list.isEmpty else {
            // 要約できるプロファイルがない: 録音したときのプロファイルで試み、その理由を表示させる
            return .summarize(e, profile: e.metadata?.profile ?? "default", model: nil, force: force)
        }
        let p = list.firstIndex { $0.name == e.metadata?.profile } ?? 0
        if list.count == 1 {
            summarizeForm = SummarizeForm(entry: e, force: force, step: .model, profileIndex: 0, index: 0)
            return modelLoadAction()
        }
        summarizeForm = SummarizeForm(entry: e, force: force, step: .profile, profileIndex: p, index: p)
        return nil
    }

    /// 選んでいるプロファイル（ウィンドウを開いていなければ nil）
    public var formProfile: Profile? {
        guard let f = summarizeForm, summaryProfiles.indices.contains(f.profileIndex) else { return nil }
        return summaryProfiles[f.profileIndex]
    }

    /// モデルを選ぶ段階で、一覧をまだ取得していなければ取得を始める（取得中にする）
    mutating func modelLoadAction() -> Action? {
        guard let f = summarizeForm, f.step == .model, let p = formProfile else { return nil }
        let key = SummaryModelCatalog.cacheKey(for: p)
        guard modelLists[key] == nil else { return nil }
        modelLists[key] = .loading
        return .loadModels(key: key, profile: p)
    }

    /// 取得した一覧（または失敗の理由）を入れる
    public mutating func setModelList(key: String, _ result: Result<[SummaryModelOption], Error>) {
        switch result {
        case .success(let models): modelLists[key] = .loaded(models)
        case .failure(let e): modelLists[key] = .failed(RecordLauncher.describeModelError(e))
        }
        if var f = summarizeForm, f.step == .model {
            f.index = min(f.index, max(0, formOptions().count - 1))
            summarizeForm = f
        }
    }

    private func formModelList() -> RecordLauncher.ModelList? {
        formProfile.flatMap { modelLists[SummaryModelCatalog.cacheKey(for: $0)] }
    }

    /// 選べるモデル（nil はプロファイルの既定）
    func formModelChoices() -> [String?] {
        guard let p = formProfile else { return [] }
        return RecordLauncher.modelChoiceList(default: p.summary.model, list: formModelList(), selected: nil)
    }

    /// ウィンドウに出す選択肢
    func formOptions() -> [String] {
        guard let f = summarizeForm else { return [] }
        switch f.step {
        case .profile:
            return summaryProfiles.map { p in
                let via = p.summaryProvider == "aws" ? "Bedrock" : "Vertex AI"
                return "\(p.name)  (\(via), \(p.summary.model))"
            }
        case .model:
            guard let p = formProfile else { return [] }
            return RecordLauncher.modelOptionLabels(default: p.summary.model, list: formModelList(), selected: nil)
        }
    }

    /// ウィンドウを開いている間のキー。↑↓ で選び、Enter で次へ（モデルなら要約を始める）、Esc で戻る
    private mutating func handleForm(_ key: TUIKey, _ form: SummarizeForm) -> Action? {
        var f = form
        let count = formOptions().count
        switch key {
        case .interrupt:
            return .quit
        case .up, .backTab, .char("k"):
            f.index = max(0, f.index - 1)
        case .down, .tab, .char("j"):
            f.index = min(max(0, count - 1), f.index + 1)
        case .home, .pageUp:
            f.index = 0
        case .end, .pageDown:
            f.index = max(0, count - 1)
        case .enter:
            switch f.step {
            case .profile:
                guard summaryProfiles.indices.contains(f.index) else { return nil }
                f.profileIndex = f.index
                f.step = .model
                f.index = 0
                summarizeForm = f
                return modelLoadAction()
            case .model:
                let choices = formModelChoices()
                guard let p = formProfile else { return nil }
                if choices.indices.contains(f.index) {
                    summarizeForm = nil
                    return .summarize(f.entry, profile: p.name, model: choices[f.index], force: f.force)
                }
                // 取得に失敗した行で Enter: 取り直す
                if case .failed(_)? = formModelList() {
                    modelLists[SummaryModelCatalog.cacheKey(for: p)] = nil
                    return modelLoadAction()
                }
                return nil
            }
        case .escape, .left, .char("q"), .char("Q"):
            // モデルからはプロファイルに戻る（プロファイルが 1 つなら閉じる）
            if f.step == .model && summaryProfiles.count > 1 {
                f.step = .profile
                f.index = f.profileIndex
            } else {
                summarizeForm = nil
                return nil
            }
        default:
            break
        }
        summarizeForm = f
        return nil
    }

    public mutating func handle(_ key: TUIKey) -> Action? {
        if let f = summarizeForm { return handleForm(key, f) }
        if let c = confirmDelete, let e = selected { return handleConfirm(key, c, e) }
        if let m = menu, let e = selected {
            let ops = operations(for: e)
            switch key {
            case .interrupt: return .quit
            case .up, .char("k"): menu = max(0, m - 1)
            case .down, .char("j"): menu = min(ops.count - 1, m + 1)
            case .home, .pageUp: menu = 0
            case .end, .pageDown: menu = ops.count - 1
            case .enter:
                menu = nil
                return ops.indices.contains(m) ? action(ops[m], e) : nil
            case .escape, .char("q"), .char("Q"), .left:
                menu = nil
            case .char(let c):
                // メニューの中でもショートカットで選べる
                if let op = ops.first(where: { $0.shortcut == c }) {
                    menu = nil
                    return action(op, e)
                }
            default:
                break
            }
            return nil
        }
        switch key {
        case .interrupt, .escape, .char("q"), .char("Q"): return .quit
        case .tab, .backTab: return .switchPage
        case .up, .char("k"): cursor = max(0, cursor - 1)
        case .down, .char("j"): cursor = min(max(0, entries.count - 1), cursor + 1)
        case .pageUp: cursor = max(0, cursor - 10)
        case .pageDown: cursor = min(max(0, entries.count - 1), cursor + 10)
        case .home: cursor = 0
        case .end: cursor = max(0, entries.count - 1)
        case .enter, .right:
            if selected != nil { menu = 0 }
        case .char("r"), .char("R"):
            return .refresh
        case .char(let c):
            if let e = selected, let op = operations(for: e).first(where: { $0.shortcut == c }) { return action(op, e) }
        default:
            break
        }
        return nil
    }

    // MARK: 表示

    public func render(width: Int, height: Int) -> [Line] {
        let w = max(20, width)
        var lines: [Line] = []
        func add(_ s: String, _ style: Line.Style = .normal) { lines.append(Line(text: DisplayWidth.fit(s, w), style: style)) }

        add(tr(" cappy — past recordings", ja: " cappy — 過去の録音"), .title)
        if let notice { for l in DisplayWidth.wrap(notice, w - 1).prefix(2) { add(" " + l, .heading) } }
        add("")
        guard !entries.isEmpty else {
            add(tr("   No recordings in: ", ja: "   録音がありません: ") + directories.map(\.path).joined(separator: ", "), .dim)
            while lines.count < height - 2 { add("") }
            add("")
            add(tr(" Tab back to recording  r refresh  q quit", ja: " Tab 録音に戻る  r 更新  q 終了"), .dim)
            return Array(lines.prefix(height))
        }

        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd HH:mm"
        let yes = "✓"
        let header = [tr("DATE", ja: "日時"), tr("LENGTH", ja: "長さ"), tr("TRANSCRIPT", ja: "文字起こし"), tr("SUMMARY", ja: "要約"), tr("NAME / TARGET", ja: "名前 / 対象")]
        let rows: [[String]] = entries.map { e in
            let transcript = e.transcript != nil ? yes : (e.liveTranscript != nil ? tr("live", ja: "ライブ") : (e.metadata?.transcription?.state == .failed ? "!" : ""))
            let summary = e.summary != nil ? yes : (e.metadata?.summary?.state == .failed ? "!" : "")
            var name = e.title.isEmpty ? "-" : e.title
            if !e.target.isEmpty { name += "  (\(e.target))" }
            return [e.startedAt.map(date.string) ?? e.directory.lastPathComponent,
                    e.durationMs.map { TimeFormat.hms(ms: $0) } ?? "-", transcript, summary, name]
        }
        var widths = header.map { DisplayWidth.of($0) }
        for r in rows { for (i, c) in r.enumerated() where i < 4 { widths[i] = max(widths[i], DisplayWidth.of(c)) } }
        func row(_ cells: [String]) -> String {
            cells.enumerated().map { i, c in i < 4 ? DisplayWidth.fit(c, widths[i]) : c }.joined(separator: "  ")
        }
        add("     " + row(header), .dim)

        // 下に詳細 5 行とヘルプ 2 行
        let detailLines = 5
        let footer = 2
        let room = max(3, height - lines.count - detailLines - footer - 1)
        var first = 0
        if entries.count > room { first = min(max(0, cursor - room / 2), entries.count - room) }
        let listTop = lines.count
        var cursorRow = listTop
        for i in first..<min(entries.count, first + room) {
            let selected = i == cursor
            if selected { cursorRow = lines.count }
            add((selected ? " ▶   " : "     ") + row(rows[i]), selected ? .selected : .normal)
        }
        if entries.count > room {
            add(tr("     (\(first + 1)–\(min(entries.count, first + room)) of \(entries.count))", ja: "     （\(entries.count) 件中 \(first + 1)–\(min(entries.count, first + room))）"), .dim)
        }
        while lines.count < height - detailLines - footer { add("") }
        add(String(repeating: "─", count: w), .dim)
        for l in details().prefix(detailLines - 1) { add("   " + l) }
        while lines.count < height - footer { add("") }
        add("")
        let help: String
        if summarizeForm != nil {
            help = tr(" ↑↓ choose  Enter decide  Esc back", ja: " ↑↓ 選択  Enter 決定  Esc 戻る")
        } else if confirmDelete != nil {
            help = tr(" ↑↓ choose  Enter decide  y move to the Trash  Esc / n cancel", ja: " ↑↓ 選択  Enter 決定  y ゴミ箱に移動  Esc / n キャンセル")
        } else if menu != nil {
            help = tr(" ↑↓ choose  Enter run  Esc close", ja: " ↑↓ 選択  Enter 実行  Esc 閉じる")
        } else {
            help = tr(" ↑↓ move  Enter actions  t transcript  s summary  p play  f Finder  d delete  r refresh  Tab recording  q quit",
                      ja: " ↑↓ 移動  Enter 操作  t 文字起こし  s 要約  p 再生  f Finder  d 削除  r 更新  Tab 録音  q 終了")
        }
        add(help, .dim)
        if let m = menu, let e = selected {
            let labels = operations(for: e).map { op in op.label + (op.shortcut.map { "  (\($0))" } ?? "") }
            TUIMenuBox.overlay(options: labels, current: nil, selected: m, belowRow: cursorRow, textColumn: 9,
                               on: &lines, width: w, height: height)
        }
        if let f = summarizeForm {
            let name = f.entry.title.isEmpty ? f.entry.directory.lastPathComponent : f.entry.title
            let verb = f.force ? tr("Summarize again", ja: "作り直す") : tr("Summarize", ja: "要約する")
            let title: String
            switch f.step {
            case .profile:
                title = tr("\(verb) \"\(name)\": profile", ja: "「\(name)」を\(verb): プロファイル")
            case .model:
                title = tr("\(verb) \"\(name)\": model (\(formProfile?.name ?? "-"))", ja: "「\(name)」を\(verb): モデル（\(formProfile?.name ?? "-")）")
            }
            let current: Int? = f.step == .profile ? summaryProfiles.firstIndex(where: { $0.name == f.entry.metadata?.profile }) : 0
            TUIMenuBox.overlay(options: formOptions(), current: current, selected: f.index, belowRow: cursorRow, textColumn: 9,
                               title: title, on: &lines, width: w, height: height)
        }
        if let c = confirmDelete, let e = selected {
            let name = e.title.isEmpty ? e.directory.lastPathComponent : e.title
            TUIMenuBox.overlay(options: [tr("Cancel", ja: "キャンセル"), tr("Move to the Trash", ja: "ゴミ箱に移動する")],
                               current: nil, selected: c, belowRow: cursorRow, textColumn: 9,
                               title: tr("Delete \"\(name)\"? (it goes to the Trash)", ja: "「\(name)」を削除しますか？（ゴミ箱に移動）"),
                               on: &lines, width: w, height: height)
        }
        return Array(lines.prefix(height))
    }

    /// 選んでいるセッションの詳細
    func details() -> [String] {
        guard let e = selected else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = e.directory.path
        var out = [path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path]
        guard let m = e.metadata else {
            out.append(tr("session.json cannot be read (repair with `cappy recover`)", ja: "session.json を読めません（`cappy recover` で修復できます）"))
            return out
        }
        var info: [String] = []
        if let p = m.profile { info.append(tr("Profile: \(p)", ja: "プロファイル: \(p)")) }
        let tracks = m.tracks.filter { $0.id != .mix }.sorted { $0.id < $1.id }
            .map { "\($0.id.displayName) \($0.durationMs.map { TimeFormat.hms(ms: $0) } ?? "-")" }
        if !tracks.isEmpty { info.append(tr("Tracks: ", ja: "トラック: ") + tracks.joined(separator: " / ")) }
        switch m.recording.state {
        case .recording: info.append(tr("Recording, or ended abnormally", ja: "録音中、または異常終了"))
        case .finalized: info.append(tr("No files to send (`cappy recover`)", ja: "送信用ファイルなし（`cappy recover`）"))
        case .converted: break
        }
        if e.isActive { info.append(tr("● Recording now", ja: "● 録音中")) }
        out.append(info.joined(separator: "   "))
        var jobs: [String] = []
        if let t = m.transcription {
            jobs.append(tr("Transcription: \(t.model ?? t.provider) (\(t.state.rawValue))", ja: "文字起こし: \(t.model ?? t.provider)（\(t.state.rawValue)）"))
        }
        if let s = m.summary { jobs.append(tr("Summary: \(s.model) (\(s.state.rawValue))", ja: "要約: \(s.model)（\(s.state.rawValue)）")) }
        if !jobs.isEmpty { out.append(jobs.joined(separator: "   ")) }
        if !m.markers.isEmpty {
            let list = m.markers.prefix(5).map { TimeFormat.hms(ms: $0.atMs) + ($0.label.map { " \($0)" } ?? "") }
            out.append(tr("Markers: ", ja: "マーカー: ") + list.joined(separator: ", ") + (m.markers.count > 5 ? " …" : ""))
        }
        return out
    }
}

/// テキスト（transcript.md・summary.md など）を読むページ
public struct TextPager: Sendable {
    public typealias Line = RecordLauncher.Line

    public enum Result: Equatable, Sendable { case close, quit }

    public var title: String
    public private(set) var source: [String]
    /// 表示の先頭（折り返した後の行で数える）
    public private(set) var top = 0

    public init(title: String, text: String) {
        self.title = title
        source = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// 折り返した行と、その行の見た目（見出しは太字）
    func wrapped(width: Int) -> [(String, Line.Style)] {
        source.flatMap { line -> [(String, Line.Style)] in
            let style: Line.Style = line.hasPrefix("#") ? .heading : .normal
            return DisplayWidth.wrap(line, max(1, width)).map { ($0, style) }
        }
    }

    private static func bodyHeight(_ height: Int) -> Int { max(1, height - 4) }

    public mutating func handle(_ key: TUIKey, width: Int, height: Int) -> Result? {
        let page = Self.bodyHeight(height)
        let total = wrapped(width: max(20, width) - 2).count
        let maxTop = max(0, total - page)
        switch key {
        case .interrupt: return .quit
        case .escape, .char("q"), .char("Q"), .left, .tab, .backTab: return .close
        case .up, .char("k"): top -= 1
        case .down, .char("j"), .enter: top += 1
        case .pageDown, .char(" "), .char("f"): top += page
        case .pageUp, .char("b"): top -= page
        case .home, .char("g"): top = 0
        case .end, .char("G"): top = maxTop
        default: break
        }
        top = min(max(0, top), maxTop)
        return nil
    }

    public func render(width: Int, height: Int) -> [Line] {
        let w = max(20, width)
        var lines: [Line] = []
        func add(_ s: String, _ style: Line.Style = .normal) { lines.append(Line(text: DisplayWidth.fit(s, w), style: style)) }
        let body = wrapped(width: w - 2)
        let page = Self.bodyHeight(height)
        let start = min(top, max(0, body.count - page))
        add(" " + title, .title)
        add(String(repeating: "─", count: w), .dim)
        for (text, style) in body.dropFirst(start).prefix(page) { add(" " + text, style) }
        while lines.count < height - 2 { add("") }
        add(String(repeating: "─", count: w), .dim)
        let position = body.isEmpty ? "" : tr("lines \(start + 1)–\(min(body.count, start + page)) of \(body.count)",
                                              ja: "\(body.count) 行中 \(start + 1)–\(min(body.count, start + page))")
        add(tr(" ↑↓ scroll  Space/b page  g/G top/bottom  q back", ja: " ↑↓ スクロール  Space/b ページ  g/G 先頭/末尾  q 戻る") + "   " + position, .dim)
        return Array(lines.prefix(height))
    }
}
