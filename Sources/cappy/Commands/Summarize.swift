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
        If a summary of the same transcript exists, it is not regenerated (use --force to regenerate).
        """, ja: """
        transcript.json を Vertex AI の Claude / Gemini、または Amazon Bedrock のモデル（Claude、Kimi K3.1、GLM-5.3 など）に送り、概要・決定事項・アクションアイテム・議論の要点・未解決事項をまとめます。
        モデルは claude- で始まれば Claude、gemini- で始まれば Gemini を使います。Bedrock では global.moonshotai.kimi-k3.1 のような Bedrock のモデル ID も指定できます。
        認証は、Vertex AI なら Google のアプリケーションデフォルト認証情報（ADC）、Bedrock なら AWS のプロファイル（AWS_PROFILE・SSO など）を使います。
        同じ文字起こしから作った要約がある場合は作り直しません（--force で作り直す）。
        """)
    )

    @Argument(help: ArgumentHelp(tr("Session directory", ja: "セッションディレクトリ")), completion: .directory)
    var sessionDir: String

    @Option(help: ArgumentHelp(tr("Model (default: summary.model of the profile, e.g. gemini-4-argon, claude-opus-5-5, or global.moonshotai.kimi-k3.1 on Bedrock)", ja: "モデル（既定はプロファイルの summary.model。例: gemini-4-argon, claude-opus-5-5、Bedrock なら global.moonshotai.kimi-k3.1）")),
            completion: .custom { _, _, _ in CompletionCandidates.models() })
    var model: String?

    @Option(help: ArgumentHelp(tr("Thinking effort (low / medium / high / xhigh / max; default: summary.effort of the profile)", ja: "思考の深さ（low / medium / high / xhigh / max。既定はプロファイルの summary.effort）")),
            completion: .list(CompletionCandidates.efforts))
    var effort: String?

    @Flag(help: ArgumentHelp(tr("Regenerate even if a summary exists", ja: "既存の要約があっても作り直す")))
    var force = false

    @OptionGroup var common: CommonOptions

    func run() async throws {
        CappyLog.shared.verbose = common.verbose
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
            force: force, model: model, effort: effort, explicit: true))
    }
}
