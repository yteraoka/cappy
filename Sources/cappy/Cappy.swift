import ArgumentParser
import CappyKit
import Foundation

struct Cappy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cappy",
        abstract: "会議アプリの音声とマイク音声を別トラックで録音し、外部サービスで文字起こしする",
        discussion: """
        設定ファイル: ~/.config/cappy/config.toml（CAPPY_CONFIG で変更可）

        終了コード:
          0 正常終了  1 引数・設定の誤り  2 権限不足  3 録音対象が見つからない
          4 録音中の I/O エラー  5 文字起こしサービスのエラー
        """,
        version: CappyVersion.current,
        subcommands: [Record.self, Transcribe.self, Apps.self, Devices.self, Doctor.self, Recover.self]
    )
}

struct CommonOptions: ParsableArguments {
    @Option(help: "設定プロファイル名（既定: default）")
    var profile: String?

    @Flag(name: .shortAndLong, help: "詳細ログ（バッファ欠落数・リングバッファ使用率など）を出力する")
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
            Console.print("エラー: \(e.message)")
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
