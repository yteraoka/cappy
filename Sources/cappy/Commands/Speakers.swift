import ArgumentParser
import CappyKit
import Foundation

struct Speakers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("Name the speakers (Me, Remote 1, ...) in the transcript from what was said", ja: "発言内容から文字起こしの話者（自分・相手 1 など）の名前を推定して埋める"),
        discussion: tr("""
        Sends transcript.json to the summary model and works out who each speaker label is from self-introductions,
        answers after being addressed by name, and so on. The names are written into transcript.md / .srt / .json
        as "Tanaka (Remote 1)", and are used by the summary.
        Labels the model is not sure about (low confidence) are left without a name.
        Fix mistakes with --set "Remote 1=Tanaka" (an empty name, "Remote 1=", leaves the label without a name);
        --unset goes back to the inferred name. Your own name can be set with speakers.me in the profile.
        By default this also runs before summarizing (speakers.auto = false turns it off).
        If you transcribe again, the speaker labels can change, so the names are inferred again.
        """, ja: """
        transcript.json を要約のモデルに送り、自己紹介や名前で呼ばれた直後の応答などから、各話者ラベルが誰かを推定します。
        名前は transcript.md / .srt / .json に「田中（相手 1）」の形で書き込み、要約でも使います。
        確度の低い（low）ラベルには名前を付けません。
        間違いは --set "相手 1=田中" で直せます（"相手 1=" のように名前を空にすると名前を付けません）。
        --unset で推定した名前に戻します。自分の名前はプロファイルの speakers.me で指定できます。
        既定では要約の前にも自動で実行します（speakers.auto = false で無効）。
        文字起こしをやり直すと話者のラベルが変わりうるため、名前は推定し直します。
        """)
    )

    @Argument(help: ArgumentHelp(tr("Session directory", ja: "セッションディレクトリ")), completion: .directory)
    var sessionDir: String

    @Option(name: .customLong("set"), help: ArgumentHelp(tr("Give a speaker's name, e.g. \"Remote 1=Tanaka\" (repeatable; an empty name leaves the label without a name)", ja: "話者の名前を指定する。例: \"相手 1=田中\"（複数回指定可。名前を空にすると名前を付けない）")))
    var assignments: [String] = []

    @Option(name: .customLong("unset"), help: ArgumentHelp(tr("Drop the name given with --set and go back to the inferred one (repeatable)", ja: "--set で指定した名前を取り消し、推定した名前に戻す（複数回指定可）")))
    var unsets: [String] = []

    @Flag(help: ArgumentHelp(tr("Remove all names (inferred and given) from the transcript", ja: "推定・指定したすべての名前を文字起こしから取り除く")))
    var clear = false

    @Flag(help: ArgumentHelp(tr("Show the current names without changing anything", ja: "変更せずに、今の名前を表示する")))
    var list = false

    @Flag(help: ArgumentHelp(tr("Infer again even if already inferred from the same transcript", ja: "同じ文字起こしから推定済みでも推定し直す")))
    var force = false

    @Option(help: ArgumentHelp(tr("Model (default: speakers.model, or summary.model of the profile)", ja: "モデル（既定はプロファイルの speakers.model、なければ summary.model）")),
            completion: .custom { _, _, _ in CompletionCandidates.models() })
    var model: String?

    @Option(help: ArgumentHelp(tr("Thinking effort (low / medium / high / xhigh / max; default: speakers.effort of the profile, low)", ja: "思考の深さ（low / medium / high / xhigh / max。既定はプロファイルの speakers.effort、low）")),
            completion: .list(CompletionCandidates.efforts))
    var effort: String?

    @OptionGroup var common: CommonOptions

    func validate() throws {
        let edits = !assignments.isEmpty || !unsets.isEmpty
        if (edits && clear) || (list && (edits || clear)) {
            throw ValidationError(tr("--set / --unset, --clear and --list cannot be combined", ja: "--set / --unset、--clear、--list は同時に指定できません"))
        }
        if (edits || clear || list) && (force || model != nil || effort != nil) {
            throw ValidationError(tr("--force, --model and --effort are for inferring, and cannot be combined with --set / --unset / --clear / --list", ja: "--force・--model・--effort は推定のためのもので、--set / --unset / --clear / --list とは同時に指定できません"))
        }
        for a in assignments where Self.parseAssignment(a) == nil {
            throw ValidationError(tr("Invalid --set: \(a) (write it as \"Remote 1=Tanaka\")", ja: "--set が不正です: \(a)（\"相手 1=田中\" の形で指定してください）"))
        }
    }

    /// "相手 1=田中" → ("相手 1", "田中")。名前は空でもよい
    static func parseAssignment(_ s: String) -> (label: String, name: String?)? {
        guard let eq = s.firstIndex(of: "=") else { return nil }
        let label = s[..<eq].trimmingCharacters(in: .whitespaces)
        let name = s[s.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return (label: label, name: name)
    }

    func run() async throws {
        CappyLog.shared.verbose = common.verbose
        let dir = URL(fileURLWithPath: FileSecurity.expandTilde(sessionDir), isDirectory: true)
        let store = try SessionStore.open(dir)
        let profile = try common.loadProfile(fallback: store.metadata.profile)
        CappyLog.shared.attach(sessionDirectory: dir)
        CappyLog.shared.info(tr("cappy \(CappyVersion.current) speakers started session=\(store.metadata.id)", ja: "cappy \(CappyVersion.current) speakers 開始 session=\(store.metadata.id)"))
        defer { CappyLog.shared.detach() }

        if list {
            try SpeakersRunner.printNames(store: store, profile: profile)
            return
        }
        if clear {
            try SpeakerNamer.clear(store)
            try SpeakerNamer.apply(store, me: profile.speakers.me)
            Console.print(tr("Removed the speaker names", ja: "話者の名前を取り除きました"))
            try SpeakersRunner.printNames(store: store, profile: profile)
            return
        }
        if !assignments.isEmpty || !unsets.isEmpty {
            let edits = assignments.compactMap(Self.parseAssignment) + unsets.map { (label: $0, name: String?.none) }
            try SpeakerNamer.setManual(store, edits)
            try SpeakerNamer.apply(store, me: profile.speakers.me)
            Console.print(tr("Updated the speaker names:", ja: "話者の名前を更新しました:"))
            try SpeakersRunner.printNames(store: store, profile: profile)
            Self.printSummaryHint(store)
            return
        }

        for sig in [SIGINT, SIGTERM] { signal(sig, SIG_IGN) }
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler {
                Console.clearStatus()
                Console.print(tr("Interrupted", ja: "中断しました"))
                Foundation.exit(130)
            }
            src.resume()
            sources.append(src)
        }
        defer { sources.forEach { $0.cancel() } }

        try await SpeakersRunner.infer(store: store, profile: profile, request: .init(force: force, model: model, effort: effort))
        Self.printSummaryHint(store)
    }

    /// 要約があれば、名前を反映するには作り直すことを伝える
    static func printSummaryHint(_ store: SessionStore) {
        guard store.metadata.summary?.state == .done else { return }
        Console.print(tr("To use the names in the summary, run `cappy summarize \(store.directory.path)`",
                         ja: "要約に名前を反映するには `cappy summarize \(store.directory.path)` を実行してください"))
    }
}
