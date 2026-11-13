import ArgumentParser
import CappyKit
import Foundation

struct Summarize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("Summarize a transcribed session into summary.md", ja: "文字起こし済みのセッションから会議の要約（summary.md）を作る"),
        discussion: tr("""
        Sends transcript.json to Claude / Gemini on Vertex AI, or to a model on Amazon Bedrock (Claude, Kimi K3.1, GLM-5.3, ...), and writes an overview, decisions, action items, discussion points and open issues.
        Models starting with claude- use Claude and gemini- use Gemini. On Bedrock you can also give a Bedrock model ID such as global.moonshotai.kimi-k3.1.
        Authentication uses Google Application Default Credentials (ADC) for Vertex AI, and the AWS profile (AWS_PROFILE, SSO, ...) for Bedrock.
        If a summary of the same transcript and prompt exists, it is not regenerated (use --force to regenerate).

        The structure of the output can be replaced with a template: put Markdown files in prompts/ next to the config
        file (~/.config/cappy/prompts/<name>.md) and choose one with summary.prompt or --prompt <name>.
        Start from the built-in one with `cappy summarize --print-prompt > ~/.config/cappy/prompts/minutes.md`.
        In a template, {{language}} is replaced with the output language and {{language_code}} with the language code.
        """, ja: """
        transcript.json を Vertex AI の Claude / Gemini、または Amazon Bedrock のモデル（Claude、Kimi K3.1、GLM-5.3 など）に送り、概要・決定事項・アクションアイテム・議論の要点・未解決事項をまとめます。
        モデルは claude- で始まれば Claude、gemini- で始まれば Gemini を使います。Bedrock では global.moonshotai.kimi-k3.1 のような Bedrock のモデル ID も指定できます。
        認証は、Vertex AI なら Google のアプリケーションデフォルト認証情報（ADC）、Bedrock なら AWS のプロファイル（AWS_PROFILE・SSO など）を使います。
        同じ文字起こし・依頼文から作った要約がある場合は作り直しません（--force で作り直す）。

        出力の構成はテンプレートで差し替えられます。設定ファイルと同じディレクトリの prompts/
        （~/.config/cappy/prompts/<名前>.md）に Markdown を置き、summary.prompt か --prompt <名前> で選びます。
        `cappy summarize --print-prompt > ~/.config/cappy/prompts/minutes.md` で組み込みのものから始められます。
        テンプレートの {{language}} は出力する言語、{{language_code}} は言語コードに置き換えます。
        """)
    )

    @Argument(help: ArgumentHelp(tr("Session directory", ja: "セッションディレクトリ")), completion: .directory)
    var sessionDir: String?

    @Option(help: ArgumentHelp(tr("Model (default: summary.model of the profile, e.g. gemini-4-argon, claude-opus-5-5, or global.moonshotai.kimi-k3.1 on Bedrock)", ja: "モデル（既定はプロファイルの summary.model。例: gemini-4-argon, claude-opus-5-5、Bedrock なら global.moonshotai.kimi-k3.1）")),
            completion: .custom { _, _, _ in CompletionCandidates.models() })
    var model: String?

    @Option(help: ArgumentHelp(tr("Thinking effort (low / medium / high / xhigh / max; default: summary.effort of the profile)", ja: "思考の深さ（low / medium / high / xhigh / max。既定はプロファイルの summary.effort）")),
            completion: .list(CompletionCandidates.efforts))
    var effort: String?

    @Flag(help: ArgumentHelp(tr("Regenerate even if a summary exists", ja: "既存の要約があっても作り直す")))
    var force = false

    @Option(help: ArgumentHelp(tr("Template for the structure of the summary: a name in prompts/ or a path to a .md file (default: summary.prompt of the profile, or the built-in default)", ja: "要約の構成のテンプレート。prompts/ の名前か .md ファイルのパス（既定はプロファイルの summary.prompt、なければ組み込みの default）")),
            completion: .custom { _, _, _ in CompletionCandidates.prompts() })
    var prompt: String?

    @Flag(help: ArgumentHelp(tr("Print the template (the structure part of the prompt) and exit; save it in prompts/ to customize", ja: "テンプレート（依頼文の構成の部分）を表示して終わる。prompts/ に保存して編集できる")))
    var printPrompt = false

    @Flag(help: ArgumentHelp(tr("Print the whole system prompt that would be sent and exit", ja: "送る依頼文（システムプロンプト）全体を表示して終わる")))
    var printSystemPrompt = false

    @OptionGroup var common: CommonOptions

    func validate() throws {
        if sessionDir == nil && !printPrompt && !printSystemPrompt {
            throw ValidationError(tr("Specify the session directory", ja: "セッションディレクトリを指定してください"))
        }
        if printPrompt && printSystemPrompt {
            throw ValidationError(tr("--print-prompt cannot be combined with --print-system-prompt", ja: "--print-prompt と --print-system-prompt は同時に指定できません"))
        }
    }

    /// --print-prompt / --print-system-prompt。言語はセッションの文字起こし、なければプロファイルの language
    private func printTemplate() throws {
        var store: SessionStore?
        if let sessionDir { store = try SessionStore.open(URL(fileURLWithPath: FileSecurity.expandTilde(sessionDir), isDirectory: true)) }
        let profile = try common.loadProfile(fallback: store?.metadata.profile)
        let template = try SummaryTemplate.load(prompt ?? profile.summary.prompt)
        let language = store?.metadata.transcription?.language ?? profile.language
        if printSystemPrompt {
            print(SummaryPrompt.system(language: language, extraInstructions: try SummaryClientFactory.instructions(profile: profile), template: template))
        } else {
            // 組み込みは変数のまま書き出す（保存すれば別の言語の会議でも使える）
            print(template.body ?? SummaryTemplate.builtinBody(UILanguage.forDocument(language)))
        }
    }

    func run() async throws {
        CappyLog.shared.verbose = common.verbose
        if printPrompt || printSystemPrompt {
            try printTemplate()
            return
        }
        guard let sessionDir else { return }
        let dir = URL(fileURLWithPath: FileSecurity.expandTilde(sessionDir), isDirectory: true)
        let store = try SessionStore.open(dir)
        let profile = try common.loadProfile(fallback: store.metadata.profile)
        CappyLog.shared.attach(sessionDirectory: dir)
        CappyLog.shared.info(tr("cappy \(CappyVersion.current) summarize started session=\(store.metadata.id)", ja: "cappy \(CappyVersion.current) summarize 開始 session=\(store.metadata.id)"))
        defer { CappyLog.shared.detach() }

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

        if profile.summaryProvider == "none" {
            throw CappyError.usage(tr("The summary provider of profile \(profile.name) is none", ja: "プロファイル \(profile.name) の要約プロバイダが none です"),
                                   hint: tr("Set provider in [profiles.\(profile.name).summary] to vertex or bedrock", ja: "[profiles.\(profile.name).summary] の provider を vertex か bedrock にしてください"))
        }
        try await SummarizeRunner.run(store: store, profile: profile, request: .init(
            force: force, model: model, effort: effort, prompt: prompt, explicit: true))
    }
}
