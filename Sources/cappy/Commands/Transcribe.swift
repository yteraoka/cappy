import ArgumentParser
import CappyKit
import Foundation

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "録音済みセッションを外部サービスで文字起こしする（中断しても同じコマンドで再開できる）"
    )

    @Argument(help: "セッションディレクトリ")
    var sessionDir: String

    @Option(help: "文字起こしプロバイダ（gemini / google / transcribe / none。既定はプロファイルの provider）")
    var provider: String?

    @Option(help: "言語コード（既定はプロファイルの language。例: ja-JP）")
    var language: String?

    @Flag(help: "2 トラックをミックスした 1 本で送る（課金対象は約半分になるが、自分と相手の区別は失われる）")
    var mix = false

    @Option(help: "出力形式（md,json,srt のカンマ区切り）")
    var format: String = "md,json,srt"

    @Flag(help: "完了済み・実行中のジョブを破棄してやり直す")
    var force = false

    @Flag(name: .customLong("keep-remote"), help: "バケット上の音声と結果（Transcribe ならジョブ）を削除しない")
    var keepRemote = false

    @Flag(inversion: .prefixedNo, help: "続けて会議の要約（summary.md）を作る（既定はプロファイルの summary.auto）")
    var summarize: Bool?

    @OptionGroup var common: CommonOptions

    func run() async throws {
        CappyLog.shared.verbose = common.verbose
        let dir = URL(fileURLWithPath: FileSecurity.expandTilde(sessionDir), isDirectory: true)
        let store = try SessionStore.open(dir)
        let profile = try common.loadProfile(fallback: store.metadata.profile)
        let formats = try TranscriptFormat.parseList(format)
        CappyLog.shared.attach(sessionDirectory: dir)
        CappyLog.shared.info("cappy \(CappyVersion.current) transcribe 開始 session=\(store.metadata.id)")

        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
        }
        let path = dir.path
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler {
                Console.clearStatus()
                Console.print("中断しました。`cappy transcribe \(path)` で再開できます（要約は `cappy summarize \(path)`）")
                Foundation.exit(130)
            }
            src.resume()
            sources.append(src)
        }
        defer { sources.forEach { $0.cancel() } }

        try await TranscribeRunner.run(store: store, profile: profile, request: .init(
            providerName: provider, language: language, mix: mix, formats: formats, force: force, keepRemote: keepRemote))
        if (summarize ?? profile.summary.auto) && (provider ?? profile.provider) != "none" {
            try await SummarizeRunner.run(store: store, profile: profile, request: .init(explicit: summarize == true))
        }
        CappyLog.shared.detach()
    }
}
