import Foundation

/// TUI の一覧に出す録音対象（同じアプリのヘルパープロセスは 1 行にまとめる）
public struct LaunchTarget: Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// bundle ID の前方一致（record --app）
        case app(String)
        /// bundle ID のないプロセス（record --pid）
        case pid(Int32)
        /// システム全体（record --system）
        case system
    }

    public var kind: Kind
    public var name: String
    public var isPlaying: Bool
    public var processCount: Int
    /// アプリか（false ならシステムのデーモンなど。一覧の後ろに薄く出す）
    public var isApp: Bool

    public init(kind: Kind, name: String, isPlaying: Bool, processCount: Int, isApp: Bool = true) {
        self.kind = kind
        self.name = name
        self.isPlaying = isPlaying
        self.processCount = processCount
        self.isApp = isApp
    }

    public static var system: LaunchTarget { LaunchTarget(kind: .system, name: tr("All system audio (except cappy)", ja: "システム全体の音声（cappy を除く）"),
                                            isPlaying: false, processCount: 0, isApp: false) }

    public var arguments: [String] {
        switch kind {
        case .app(let id): return ["--app", id]
        case .pid(let pid): return ["--pid", String(pid)]
        case .system: return ["--system"]
        }
    }

    /// 音声プロセスの一覧を 1 アプリ 1 行にまとめる。
    ///
    /// bundle ID が別の bundle ID に「.」区切りで続くもの（com.google.Chrome.helper など）は親にまとめる。
    /// record --app は前方一致なので、親の bundle ID を指定すればヘルパーも録音される。
    /// 出力中のもの、アプリ、それ以外（デーモンなど）の順に、それぞれ名前順に並べ、最後にシステム全体を置く。
    public static func group(_ processes: [AudioProcessInfo], excludingPID: Int32? = nil) -> [LaunchTarget] {
        let list = processes.filter { $0.pid != excludingPID }
        let ids = Set(list.map(\.bundleID).filter { !$0.isEmpty })
        func root(_ id: String) -> String {
            // 最も短い親（a.b が a.b.c.d の親で、a.b.c も候補にあれば a.b）
            ids.filter { id.hasPrefix($0 + ".") }.min { $0.count < $1.count } ?? id
        }
        var groups: [String: [AudioProcessInfo]] = [:]
        var targets: [LaunchTarget] = []
        for p in list {
            if p.bundleID.isEmpty {
                targets.append(LaunchTarget(kind: .pid(p.pid), name: p.name.isEmpty ? "PID \(p.pid)" : p.name,
                                            isPlaying: p.isRunningOutput, processCount: 1, isApp: p.isUserApp))
            } else {
                groups[root(p.bundleID), default: []].append(p)
            }
        }
        for (id, members) in groups {
            let owner = members.first { $0.bundleID == id } ?? members[0]
            targets.append(LaunchTarget(kind: .app(id), name: appName(owner.name),
                                        isPlaying: members.contains(where: \.isRunningOutput), processCount: members.count,
                                        isApp: members.contains(where: \.isUserApp)))
        }
        targets.sort { a, b in
            if a.isPlaying != b.isPlaying { return a.isPlaying }
            if a.isApp != b.isApp { return a.isApp }
            let c = a.name.localizedCaseInsensitiveCompare(b.name)
            if c != .orderedSame { return c == .orderedAscending }
            return a.sortKey < b.sortKey
        }
        return targets + [system]
    }

    /// "Google Chrome (Google Chrome Helper)" → "Google Chrome"
    static func appName(_ name: String) -> String {
        guard name.hasSuffix(")"), let r = name.range(of: " (") else { return name }
        return String(name[..<r.lowerBound])
    }

    var sortKey: String {
        switch kind {
        case .app(let id): return id
        case .pid(let pid): return String(format: "~%010d", pid)
        case .system: return "~~"
        }
    }

    var detail: String {
        switch kind {
        case .app(let id): return id
        case .pid(let pid): return "PID \(pid)"
        case .system: return "--system"
        }
    }
}

/// 録音の後に何をするか
public enum LaunchOperation: String, CaseIterable, Sendable {
    case record, transcribe, summarize, live, liveSummarize

    public var label: String {
        switch self {
        case .record: return tr("Record only", ja: "録音のみ")
        case .transcribe: return tr("Record → transcribe", ja: "録音 → 文字起こし")
        case .summarize: return tr("Record → transcribe → summarize", ja: "録音 → 文字起こし → 要約")
        case .live: return tr("Live transcription", ja: "リアルタイム文字起こし")
        case .liveSummarize: return tr("Live transcription → summarize", ja: "リアルタイム文字起こし → 要約")
        }
    }

    public var arguments: [String] {
        switch self {
        case .record: return []
        case .transcribe: return ["--transcribe", "--no-summarize"]
        case .summarize: return ["--transcribe", "--summarize"]
        case .live: return ["--live", "--no-summarize"]
        case .liveSummarize: return ["--live", "--summarize"]
        }
    }

    var summarizes: Bool { self == .summarize || self == .liveSummarize }

    /// プロファイルで使える操作（文字起こし・要約のプロバイダが none なら除く）
    public static func available(for profile: Profile) -> [LaunchOperation] {
        if profile.provider == "none" { return [.record] }
        let canSummarize = profile.summaryProvider != "none"
        return allCases.filter { canSummarize || !$0.summarizes }
    }

    /// プロファイルを選んだときの初期値（summary.auto なら要約まで）
    public static func preferred(for profile: Profile) -> LaunchOperation {
        let ops = available(for: profile)
        if profile.summary.auto, ops.contains(.summarize) { return .summarize }
        return ops.contains(.transcribe) ? .transcribe : .record
    }
}

public enum LaunchMic: CaseIterable, Sendable {
    case on, muted, off

    public var label: String {
        switch self {
        case .on: return tr("On", ja: "オン")
        case .muted: return tr("Start muted", ja: "ミュートで開始")
        case .off: return tr("Off (do not record)", ja: "オフ（録音しない）")
        }
    }

    public var arguments: [String] {
        switch self {
        case .on: return []
        case .muted: return ["--muted"]
        case .off: return ["--no-mic"]
        }
    }
}

/// `cappy tui` の画面の状態。キー入力を受けて、録音を始めるときは record の引数を返す
public struct RecordLauncher: Sendable {
    public enum Field: CaseIterable, Sendable { case profile, operation, mic, duration, name }

    public enum Action: Equatable, Sendable {
        case start([String])
        case quit
        case refresh
        /// 前回の録音のログを表示する
        case showLog
        /// 過去の録音のページに切り替える（Tab）
        case switchPage
    }

    /// 前回の録音の結果（選ぶ画面に戻ったときに上に出す）
    public struct Notice: Equatable, Sendable {
        public var text: String
        public var isError: Bool
        public init(text: String, isError: Bool) {
            self.text = text
            self.isError = isError
        }
    }
    public var notice: Notice?

    public enum Row: Equatable, Sendable {
        case field(Field)
        case target(Int)
    }

    public static let durations: [String?] = [nil, "30m", "1h", "90m", "2h", "3h"]

    public private(set) var profiles: [Profile]
    public private(set) var profileIndex: Int
    public private(set) var operations: [LaunchOperation]
    public private(set) var operation: LaunchOperation
    public private(set) var mic: LaunchMic = .on
    public private(set) var durationIndex = 0
    public private(set) var name = ""
    public private(set) var targets: [LaunchTarget] = [LaunchTarget.system]
    /// 0..<Field.allCases.count が設定の行、それ以降が録音対象の行
    public private(set) var cursor: Int
    public var verbose = false
    /// 一覧で対象を選び直したか（選ぶまでは、一覧が更新されても先頭を指す）
    private var picked = false
    /// セッション名を編集中か（Session name の行で Enter を押すと始まる）
    public private(set) var editingName = false
    private var nameBeforeEdit = ""

    /// 開いている選択肢のリスト（設定の行で Enter を押すと開く）
    public struct Picker: Equatable, Sendable {
        public var field: Field
        /// リストの中で選んでいる位置
        public var index: Int
    }
    public private(set) var picker: Picker?

    public init(profiles: [Profile], initialProfile: String? = nil) {
        let list = profiles.isEmpty ? [Profile(name: "default")] : profiles
        let index = initialProfile.flatMap { n in list.firstIndex { $0.name == n } } ?? 0
        self.profiles = list
        profileIndex = index
        let p = list[index]
        operations = LaunchOperation.available(for: p)
        operation = LaunchOperation.preferred(for: p)
        cursor = Field.allCases.count
    }

    /// 設定ファイルのプロファイルを default を先頭に並べる
    public static func orderedProfiles(_ config: CappyConfig) -> [Profile] {
        config.profiles.values.sorted { a, b in
            if (a.name == "default") != (b.name == "default") { return a.name == "default" }
            return a.name < b.name
        }
    }

    public var profile: Profile { profiles[profileIndex] }
    public var duration: String? { Self.durations[durationIndex] }

    public var row: Row {
        cursor < Field.allCases.count ? .field(Field.allCases[cursor]) : .target(cursor - Field.allCases.count)
    }

    public var selectedTarget: LaunchTarget? {
        if case .target(let i) = row, targets.indices.contains(i) { return targets[i] }
        return nil
    }

    private var rowCount: Int { Field.allCases.count + targets.count }

    /// 一覧を新しくする。選んでいた対象が残っていれば、並びが変わってもそこに留まる
    public mutating func update(targets new: [LaunchTarget]) {
        let selected = picked ? selectedTarget?.kind : nil
        targets = new.isEmpty ? [LaunchTarget.system] : new
        if selectedTarget != nil && !picked {
            cursor = Field.allCases.count
        } else if let selected {
            if let i = targets.firstIndex(where: { $0.kind == selected }) {
                cursor = Field.allCases.count + i
            } else {
                cursor = min(cursor, rowCount - 1)
            }
        }
    }

    /// 録音中の画面に出す、選んだ内容（項目名と値）
    public func summary(for target: LaunchTarget) -> [(label: String, value: String)] {
        var rows: [(String, String)] = [
            (tr("Target", ja: "録音対象"), "\(target.name)  (\(target.detail))"),
            (label(of: .profile), value(of: .profile)),
            (label(of: .operation), value(of: .operation)),
            (label(of: .mic), value(of: .mic)),
        ]
        if duration != nil { rows.append((label(of: .duration), value(of: .duration))) }
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { rows.append((label(of: .name), n)) }
        return rows
    }

    /// record に渡す引数
    public func arguments(for target: LaunchTarget) -> [String] {
        var args = target.arguments + ["--profile", profile.name] + operation.arguments + mic.arguments
        if let duration { args += ["--duration", duration] }
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { args += ["--name", n] }
        if verbose { args.append("--verbose") }
        return args
    }

    public mutating func handle(_ key: TUIKey) -> Action? {
        let before = cursor
        defer { if cursor != before { picked = true } }
        if editingName { return handleEditing(key) }
        if picker != nil { return handlePicker(key) }
        switch key {
        case .interrupt, .escape:
            return .quit
        case .tab, .backTab:
            return .switchPage
        case .up:
            cursor = max(0, cursor - 1)
        case .down:
            cursor = min(rowCount - 1, cursor + 1)
        case .pageUp:
            cursor = max(0, cursor - 10)
        case .pageDown:
            cursor = min(rowCount - 1, cursor + 10)
        case .home:
            cursor = 0
        case .end:
            cursor = rowCount - 1
        case .left:
            if case .field(let f) = row { change(f, by: -1) }
        case .right:
            if case .field(let f) = row { change(f, by: 1) }
        case .enter:
            switch row {
            case .field(.name):
                nameBeforeEdit = name
                editingName = true
            case .field(let f):
                picker = Picker(field: f, index: currentIndex(of: f))
            case .target:
                if let t = selectedTarget { return .start(arguments(for: t)) }
            }
        case .backspace, .clearLine:
            break
        case .char(let c):
            switch c {
            case "q", "Q": return .quit
            case "r", "R": return .refresh
            case "l", "L": return notice == nil ? nil : .showLog
            case "k": cursor = max(0, cursor - 1)
            case "j": cursor = min(rowCount - 1, cursor + 1)
            default: break
            }
        }
        return nil
    }

    /// セッション名の編集中のキー。Enter で確定、Esc で取り消し、↑↓ は確定して移動する
    private mutating func handleEditing(_ key: TUIKey) -> Action? {
        switch key {
        case .interrupt:
            return .quit
        case .enter:
            editingName = false
        case .escape:
            name = nameBeforeEdit
            editingName = false
        case .up, .backTab:
            editingName = false
            cursor = max(0, cursor - 1)
        case .down, .tab:
            editingName = false
            cursor = min(rowCount - 1, cursor + 1)
        case .left, .right, .pageUp, .pageDown, .home, .end:
            break
        case .backspace:
            if !name.isEmpty { name.removeLast() }
        case .clearLine:
            name = ""
        case .char(let c):
            if DisplayWidth.of(name) < 60 { name += c }
        }
        return nil
    }

    /// 選択肢のリストを開いている間のキー。↑↓ で選び、Enter で決定、Esc（q）で閉じる
    private mutating func handlePicker(_ key: TUIKey) -> Action? {
        guard var p = picker else { return nil }
        let count = options(for: p.field).count
        switch key {
        case .interrupt:
            return .quit
        case .up, .backTab, .char("k"):
            p.index = max(0, p.index - 1)
        case .down, .tab, .char("j"):
            p.index = min(count - 1, p.index + 1)
        case .home, .pageUp:
            p.index = 0
        case .end, .pageDown:
            p.index = count - 1
        case .enter:
            select(p.field, p.index)
            picker = nil
            return nil
        case .escape, .char("q"), .char("Q"):
            picker = nil
            return nil
        default:
            break
        }
        picker = p
        return nil
    }

    /// 設定の行の選択肢（表示用の文字列）
    public func options(for field: Field) -> [String] {
        switch field {
        case .profile: return profiles.map(Self.describe)
        case .operation: return operations.map(\.label)
        case .mic: return LaunchMic.allCases.map(\.label)
        case .duration: return Self.durations.map(Self.describeDuration)
        case .name: return []
        }
    }

    func currentIndex(of field: Field) -> Int {
        switch field {
        case .profile: return profileIndex
        case .operation: return operations.firstIndex(of: operation) ?? 0
        case .mic: return LaunchMic.allCases.firstIndex(of: mic) ?? 0
        case .duration: return durationIndex
        case .name: return 0
        }
    }

    private mutating func select(_ field: Field, _ index: Int) {
        let count = options(for: field).count
        guard count > 0 else { return }
        let i = min(max(0, index), count - 1)
        switch field {
        case .profile:
            profileIndex = i
            operations = LaunchOperation.available(for: profile)
            if !operations.contains(operation) { operation = LaunchOperation.preferred(for: profile) }
        case .operation: operation = operations[i]
        case .mic: mic = LaunchMic.allCases[i]
        case .duration: durationIndex = i
        case .name: break
        }
    }

    /// ←→ で前後の値に切り替える（端で反対側に回る）
    private mutating func change(_ field: Field, by delta: Int) {
        let count = options(for: field).count
        guard count > 1 else { return }
        select(field, ((currentIndex(of: field) + delta) % count + count) % count)
    }

    // MARK: - 表示

    public struct Line: Equatable, Sendable {
        public enum Style: Sendable { case normal, title, heading, selected, dim }
        /// 1 行の中で表示を変える部分（選択肢のウィンドウを重ねた行は複数になる）
        public struct Segment: Equatable, Sendable {
            public var text: String
            public var style: Style
            public init(text: String, style: Style) {
                self.text = text
                self.style = style
            }
        }
        public var segments: [Segment]
        public var text: String { segments.map(\.text).joined() }
        /// 行の地のスタイル
        public var style: Style { segments.first?.style ?? .normal }

        public init(text: String, style: Style) { segments = [Segment(text: text, style: style)] }

        /// 桁 column から segments を重ねる（下の行の文字は隠れる）
        mutating func overlay(_ parts: [Segment], at column: Int, width: Int) {
            let base = text, baseStyle = style
            let w = parts.reduce(0) { $0 + DisplayWidth.of($1.text) }
            var result: [Segment] = []
            if column > 0 { result.append(Segment(text: DisplayWidth.slice(base, from: 0, to: column), style: baseStyle)) }
            result += parts
            if column + w < width { result.append(Segment(text: DisplayWidth.slice(base, from: column + w, to: width), style: baseStyle)) }
            segments = result
        }
    }

    /// 画面の各行（幅に合わせて切り詰め・空白埋め済み）。入力中のカーソル位置（行, 桁）も返す
    public func render(width: Int, height: Int) -> (lines: [Line], cursor: (row: Int, column: Int)?) {
        let w = max(20, width)
        var lines: [Line] = []
        var textCursor: (Int, Int)?
        var pickerAnchor: (row: Int, column: Int)?
        func add(_ s: String, _ style: Line.Style = .normal) { lines.append(Line(text: DisplayWidth.fit(s, w), style: style)) }

        add(tr(" cappy — choose the settings and the app to record", ja: " cappy — 設定と録音するアプリを選んでください"), .title)
        if let notice {
            let text = (notice.isError ? "✗ " : "✓ ") + notice.text + tr("   (l: show the log)", ja: "   （l: ログを表示）")
            for l in DisplayWidth.wrap(text, w - 1).prefix(3) { add(" " + l, notice.isError ? .selected : .heading) }
        }
        add("")
        let labelWidth = max(Field.allCases.map { DisplayWidth.of(label(of: $0)) }.max() ?? 0, 8)
        for (i, f) in Field.allCases.enumerated() {
            let selected = cursor == i
            let l = label(of: f)
            let pad = String(repeating: " ", count: labelWidth - DisplayWidth.of(l))
            let v = value(of: f)
            let prefix = (selected ? " ▶ " : "   ") + l + pad + "  "
            let shown: String
            let open = picker?.field == f
            if f == .name {
                shown = "  " + (v.isEmpty && !editingName ? tr("(none)", ja: "（なし）") : v)
                if editingName { textCursor = (lines.count, DisplayWidth.of(prefix) + 2 + DisplayWidth.of(v)) }
            } else {
                shown = selected && !open ? "‹ \(v) ›" : "  \(v)"
            }
            if open { pickerAnchor = (lines.count, DisplayWidth.of(prefix)) }
            add(prefix + shown, selected && !open ? .selected : .normal)
        }
        add("")
        add(tr("   Apps that use audio (● playing; refreshed automatically)", ja: "   音声を使うアプリ（● 出力中。自動で更新します）"), .heading)

        // 一覧の行数（下にヘルプ 2 行）
        let footer = 2
        var available = max(3, height - lines.count - footer)
        if targets.count > available { available = max(1, available - 1) } // 「n 件中」の行の分
        let selectedIndex: Int? = { if case .target(let i) = row { return i } else { return nil } }()
        var first = 0
        if targets.count > available {
            let focus = selectedIndex ?? 0
            first = min(max(0, focus - available / 2), targets.count - available)
        }
        let nameWidth = min(36, max(12, targets.map { DisplayWidth.of($0.name) }.max() ?? 12))
        for i in first..<min(targets.count, first + available) {
            let t = targets[i]
            let selected = selectedIndex == i
            let more = t.processCount > 1 ? tr("  (\(t.processCount) processes)", ja: "（\(t.processCount) プロセス）") : ""
            let mark = t.kind == .system ? "  " : (t.isPlaying ? "● " : "  ")
            let text = (selected ? " ▶ " : "   ") + mark + DisplayWidth.fit(t.name, nameWidth) + "  " + t.detail + more
            add(text, selected ? .selected : (t.isApp || t.isPlaying ? .normal : .dim))
        }
        if targets.count > available {
            add(tr("   (\(first + 1)–\(min(targets.count, first + available)) of \(targets.count))", ja: "   （\(targets.count) 件中 \(first + 1)–\(min(targets.count, first + available))）"), .dim)
        }
        while lines.count < height - footer { add("") }
        let help: String
        switch row {
        case .field where picker != nil:
            help = tr(" ↑↓ choose  Enter select  Esc cancel", ja: " ↑↓ 選択  Enter 決定  Esc 取り消し")
        case .field(.name) where editingName:
            help = tr(" Type the session name  Enter done  Esc cancel  Ctrl-U clear",
                      ja: " セッション名を入力  Enter 確定  Esc 取り消し  Ctrl-U 消去")
        case .field(.name):
            help = tr(" ↑↓ move  Enter edit the session name  Tab past recordings  q quit",
                      ja: " ↑↓ 移動  Enter セッション名を編集  Tab 過去の録音  q 終了")
        case .field:
            help = tr(" ↑↓ move  Enter choose from the list  ←→ change  Tab past recordings  q quit",
                      ja: " ↑↓ 移動  Enter 一覧から選ぶ  ←→ 変更  Tab 過去の録音  q 終了")
        case .target:
            help = tr(" ↑↓ move  Enter start recording  r refresh  Tab past recordings  q quit", ja: " ↑↓ 移動  Enter 録音を開始  r 更新  Tab 過去の録音  q 終了")
        }
        add("")
        add(help, .dim)
        if let p = picker, let anchor = pickerAnchor {
            overlayPicker(p, below: anchor, on: &lines, width: w, height: height)
        }
        return (lines, textCursor)
    }

    /// 選択肢を枠で囲んだウィンドウにして、設定の行の下に重ねる（✓ が今の値、反転が選んでいる位置）
    private func overlayPicker(_ p: Picker, below anchor: (row: Int, column: Int), on lines: inout [Line], width: Int, height: Int) {
        // 選択肢の文字が上の値（anchor.column + 2 桁目）と同じ桁に来るようにする
        TUIMenuBox.overlay(options: options(for: p.field), current: currentIndex(of: p.field), selected: p.index,
                           belowRow: anchor.row, textColumn: anchor.column + 2, on: &lines, width: width, height: height)
    }

    func label(of field: Field) -> String {
        switch field {
        case .profile: return tr("Profile", ja: "プロファイル")
        case .operation: return tr("Operation", ja: "操作")
        case .mic: return tr("Mic", ja: "マイク")
        case .duration: return tr("Auto stop", ja: "自動停止")
        case .name: return tr("Session name", ja: "セッション名")
        }
    }

    func value(of field: Field) -> String {
        switch field {
        case .profile: return Self.describe(profile)
        case .operation: return operation.label
        case .mic: return mic.label
        case .duration: return Self.describeDuration(duration)
        case .name: return name
        }
    }

    static func describe(_ p: Profile) -> String {
        let detail = p.provider == "none" ? tr("recording only", ja: "録音のみ") : p.transcriptionService.displayName
        return "\(p.name)  (\(detail), \(p.language))"
    }

    static func describeDuration(_ d: String?) -> String {
        d ?? tr("None (Ctrl-C to stop)", ja: "しない（Ctrl-C で停止）")
    }
}
