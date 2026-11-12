import ArgumentParser
import CappyKit
import Foundation

struct Cappy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cappy",
        abstract: tr("Record meeting app audio and your microphone as separate tracks, then transcribe and summarize them with cloud services", ja: "会議アプリの音声とマイク音声を別トラックで録音し、外部サービスで文字起こし・要約する"),
        discussion: tr("""
        Config file: ~/.config/cappy/config.toml (override with CAPPY_CONFIG)
        Language: English by default. Set CAPPY_LANG=ja (or a ja_* locale in LC_ALL / LC_MESSAGES / LANG) for Japanese.

        Exit codes:
          0 success  1 invalid arguments or config  2 missing permission  3 recording target not found
          4 I/O error while recording  5 transcription or summary service error
        """, ja: """
        設定ファイル: ~/.config/cappy/config.toml（CAPPY_CONFIG で変更可）
        表示言語: 既定は英語。CAPPY_LANG=ja（または LC_ALL / LC_MESSAGES / LANG が ja_*）で日本語になります。

        終了コード:
          0 正常終了  1 引数・設定の誤り  2 権限不足  3 録音対象が見つからない
          4 録音中の I/O エラー  5 文字起こし・要約サービスのエラー
        """),
        version: CappyVersion.current,
        subcommands: [Init.self, Record.self, TUI.self, Mic.self, Transcribe.self, Summarize.self, Apps.self, Devices.self, Doctor.self, Recover.self, Completion.self]
    )
}

struct CommonOptions: ParsableArguments {
    @Option(help: ArgumentHelp(tr("Config profile name (default: default)", ja: "設定プロファイル名（既定: default）")), completion: .custom { _, _, _ in CompletionCandidates.profiles() })
    var profile: String?

    @Flag(name: .shortAndLong, help: ArgumentHelp(tr("Verbose logging (dropped buffers, ring buffer usage, etc.)", ja: "詳細ログ（バッファ欠落数・リングバッファ使用率など）を出力する")))
    var verbose = false

    func loadProfile(fallback: String? = nil) throws -> Profile {
        let config = try CappyConfig.load()
        return try config.profile(named: profile ?? fallback)
    }
}

@main
enum CappyMain {
    static func main() async {
        FileSecurity.restrictUmask()
        do {
            var command = try Cappy.parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            exit(0)
        } catch let e as CappyError {
            Console.clearStatus()
            Console.print(tr("Error: \(e.message)", ja: "エラー: \(e.message)"))
            if let hint = e.hint { Console.print(hint) }
            CappyLog.shared.error(e.message)
            exit(e.status.rawValue)
        } catch {
            let code = Cappy.exitCode(for: error)
            if code == .validationFailure {
                // 仕様の終了コード表に合わせて、引数の誤りは 1 にする
                FileHandle.standardError.write(Data((Cappy.fullMessage(for: error) + "\n").utf8))
                exit(ExitStatus.usage.rawValue)
            }
            Cappy.exit(withError: error)
        }
    }
}
