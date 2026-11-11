import ArgumentParser
import CappyKit
import Foundation

struct Summarize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "文字起こし済みのセッションから会議の要約（summary.md）を作る",
        discussion: """
        transcript.json を Vertex AI の Claude または Gemini に送り、概要・決定事項・アクションアイテム・議論の要点・未解決事項をまとめます。
        モデルは claude- で始まれば Claude、gemini- で始まれば Gemini を使います。
        認証は文字起こしと同じ Google のアプリケーションデフォルト認証情報（ADC）を使います。
        同じ文字起こしから作った要約がある場合は作り直しません（--force で作り直す）。
        """
    )

    @Argument(help: "セッションディレクトリ")
    var sessionDir: String

    @Option(help: "モデル（既定はプロファイルの summary.model。例: gemini-4-argon, claude-opus-5-5）")
    var model: String?

    @Option(help: "思考の深さ（low / medium / high / xhigh / max。既定はプロファイルの summary.effort）")
    var effort: String?

    @Flag(help: "既存の要約があっても作り直す")
    var force = false

    @OptionGroup var common: CommonOptions

    func run() async throws {
        CappyLog.shared.verbose = common.verbose
        let dir = URL(fileURLWithPath: FileSecurity.expandTilde(sessionDir), isDirectory: true)
        let store = try SessionStore.open(dir)
        let profile = try common.loadProfile(fallback: store.metadata.profile)
        CappyLog.shared.attach(sessionDirectory: dir)
        CappyLog.shared.info("cappy \(CappyVersion.current) summarize 開始 session=\(store.metadata.id)")
        defer { CappyLog.shared.detach() }

        for sig in [SIGINT, SIGTERM] { signal(sig, SIG_IGN) }
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler {
                Console.clearStatus()
                Console.print("中断しました")
                Foundation.exit(130)
            }
            src.resume()
            sources.append(src)
        }
        defer { sources.forEach { $0.cancel() } }

        if profile.summaryProvider == "none" {
            throw CappyError.usage("プロファイル \(profile.name) の要約プロバイダが none です",
                                   hint: "[profiles.\(profile.name).summary] の provider を vertex にしてください")
        }
        try await SummarizeRunner.run(store: store, profile: profile, request: .init(
            force: force, model: model, effort: effort, explicit: true))
    }
}
