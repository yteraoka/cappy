import ArgumentParser
import CappyKit
import Foundation

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("Transcribe a recorded session with a cloud service (resume with the same command if interrupted)", ja: "録音済みセッションを外部サービスで文字起こしする（中断しても同じコマンドで再開できる）")
    )

    @Argument(help: ArgumentHelp(tr("Session directory", ja: "セッションディレクトリ")), completion: .directory)
    var sessionDir: String

    @Option(help: ArgumentHelp(tr("Transcription provider (gemini / google / transcribe / none; default: provider of the profile)", ja: "文字起こしプロバイダ（gemini / google / transcribe / none。既定はプロファイルの provider）")),
            completion: .list(CompletionCandidates.providers))
    var provider: String?

    @Option(help: ArgumentHelp(tr("Language code (default: language of the profile, e.g. ja-JP)", ja: "言語コード（既定はプロファイルの language。例: ja-JP）")), completion: .list(CompletionCandidates.languages))
    var language: String?

    @Flag(help: ArgumentHelp(tr("Send a single mix of the two tracks (about half the billed audio, but you and the remote side can no longer be told apart)", ja: "2 トラックをミックスした 1 本で送る（課金対象は約半分になるが、自分と相手の区別は失われる）")))
    var mix = false

    @Option(help: ArgumentHelp(tr("Output formats (comma-separated md,json,srt)", ja: "出力形式（md,json,srt のカンマ区切り）")), completion: .list(CompletionCandidates.formats))
    var format: String = "md,json,srt"

    @Flag(help: ArgumentHelp(tr("Discard finished or running jobs and start over", ja: "完了済み・実行中のジョブを破棄してやり直す")))
    var force = false

    @Flag(name: .customLong("keep-remote"), help: ArgumentHelp(tr("Keep the audio and results in the bucket (and the job for Transcribe)", ja: "バケット上の音声と結果（Transcribe ならジョブ）を削除しない")))
    var keepRemote = false

    @Flag(inversion: .prefixedNo, help: ArgumentHelp(tr("Then summarize the meeting into summary.md (default: summary.auto of the profile)", ja: "続けて会議の要約（summary.md）を作る（既定はプロファイルの summary.auto）")))
    var summarize: Bool?

    @OptionGroup var common: CommonOptions

    func run() async throws {
        CappyLog.shared.verbose = common.verbose
        let dir = URL(fileURLWithPath: FileSecurity.expandTilde(sessionDir), isDirectory: true)
        let store = try SessionStore.open(dir)
        let profile = try common.loadProfile(fallback: store.metadata.profile)
        let formats = try TranscriptFormat.parseList(format)
        CappyLog.shared.attach(sessionDirectory: dir)
        CappyLog.shared.info(tr("cappy \(CappyVersion.current) transcribe started session=\(store.metadata.id)", ja: "cappy \(CappyVersion.current) transcribe 開始 session=\(store.metadata.id)"))

        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
        }
        let path = dir.path
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler {
                Console.clearStatus()
                Console.print(tr("Interrupted. Resume with `cappy transcribe \(path)` (summary: `cappy summarize \(path)`)", ja: "中断しました。`cappy transcribe \(path)` で再開できます（要約は `cappy summarize \(path)`）"))
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
