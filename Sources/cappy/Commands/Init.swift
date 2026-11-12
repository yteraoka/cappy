import ArgumentParser
import CappyKit
import Foundation

/// 対話で設定ファイル（~/.config/cappy/config.toml）を作る
struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("Create the config file interactively", ja: "対話で設定ファイルを作る"),
        discussion: tr("""
        Asks where to transcribe and summarize, the Google Cloud project or AWS profile, the buckets and so on,
        and writes one profile to ~/.config/cappy/config.toml (CAPPY_CONFIG to change it).
        If the file already exists, the profile is added; a profile with the same name is replaced after confirmation
        (the previous file is kept as config.toml.bak). Other profiles and comments are left as they are.
        Credentials are never written (Google uses Application Default Credentials, AWS uses ~/.aws profiles).
        """, ja: """
        文字起こしと要約に使うサービス、Google Cloud のプロジェクトや AWS のプロファイル、バケットなどを尋ねて、
        ~/.config/cappy/config.toml（CAPPY_CONFIG で変更可）に 1 つのプロファイルを書き込みます。
        ファイルがすでにあればプロファイルを追加します。同名のプロファイルは確認のうえ置き換えます
        （元のファイルは config.toml.bak に残します）。ほかのプロファイルやコメントはそのまま残します。
        認証情報は書き込みません（Google は Application Default Credentials、AWS は ~/.aws のプロファイルを使います）。
        """)
    )

    @Option(help: ArgumentHelp(tr("Name of the profile to create (default: default)", ja: "作成するプロファイル名（既定: default）")),
            completion: .custom { _, _, _ in CompletionCandidates.profiles() })
    var profile: String?

    func run() async throws {
        guard isatty(STDIN_FILENO) != 0 else {
            throw CappyError.usage(tr("cappy init asks questions; run it in a terminal", ja: "cappy init は質問に答えて進めるため、ターミナルで実行してください"))
        }
        let path = CappyConfig.defaultPath
        let existing: String?
        if FileManager.default.fileExists(atPath: path.path) {
            do {
                existing = try String(contentsOf: path, encoding: .utf8)
            } catch {
                throw CappyError.usage(tr("Cannot read the config file: \(path.path): \(error.localizedDescription)", ja: "設定ファイルを読めません: \(path.path): \(error.localizedDescription)"))
            }
        } else {
            existing = nil
        }
        // 書式が壊れたファイルに追記すると、どこが悪いのか分かりにくくなるため先に直してもらう
        let current = try existing.map { try CappyConfig.parse($0, path: path) }

        let io = SetupIO(
            readLine: { Swift.readLine() },
            write: { text in
                FileHandle.standardOutput.write(Data(text.utf8))
            })
        io.write(tr("Set up cappy. Press Enter to accept the value in [ ]; Ctrl-C to quit without saving.\n", ja: "cappy の設定を行います。[ ] の値でよければそのまま Enter、Ctrl-C で保存せずに終了します。\n"))
        io.write(tr("Config file: \(path.path)\(existing == nil ? " (new)" : "")\n", ja: "設定ファイル: \(path.path)\(existing == nil ? "（新規作成）" : "")\n"))

        let wizard = SetupWizard(io: io, environment: SetupEnvironment.detect(), existingProfiles: Set(current?.profiles.keys.map { $0 } ?? []))
        let answers: SetupAnswers
        do {
            answers = try wizard.run(profileName: profile)
        } catch is SetupWizard.Cancelled {
            io.write("\n")
            throw CappyError.usage(tr("Cancelled; nothing was saved", ja: "中止しました。何も保存していません"))
        }

        let text = SetupConfigFile.merged(existing: existing, answers: answers)
        // 書き込む前に読み込めることを確かめる
        let parsed = try CappyConfig.parse(text, path: path)
        _ = try parsed.profile(named: answers.profileName)

        io.write(tr("\nThe following will be written to \(path.path):\n\n", ja: "\n\(path.path) に次の内容を書き込みます:\n\n"))
        io.write(SetupConfigFile.render(answers).split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)" }.joined(separator: "\n") + "\n")
        guard try wizard.confirm(tr("Save?", ja: "保存しますか？"), default: true) else {
            throw CappyError.usage(tr("Cancelled; nothing was saved", ja: "中止しました。何も保存していません"))
        }

        do {
            try FileSecurity.createPrivateDirectory(path.deletingLastPathComponent())
            if existing != nil {
                let backup = path.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.copyItem(at: path, to: backup)
                FileSecurity.makePrivate(backup)
            }
            try FileSecurity.writeAtomically(Data(text.utf8), to: path)
        } catch {
            throw CappyError.io(tr("Cannot write the config file: \(path.path): \(error.localizedDescription)", ja: "設定ファイルを書き込めません: \(path.path): \(error.localizedDescription)"))
        }
        io.write(tr("\nSaved \(path.path)\(existing != nil ? " (the previous file is \(path.lastPathComponent).bak)" : "")\n", ja: "\n\(path.path) を保存しました\(existing != nil ? "（元のファイルは \(path.lastPathComponent).bak）" : "")\n"))

        let profileArgs = answers.profileName == "default" ? [] : ["--profile", answers.profileName]
        let flag = profileArgs.isEmpty ? "" : " --profile \(answers.profileName)"
        var steps: [String] = []
        if answers.usesGoogleCloud {
            steps.append(tr("Sign in to Google Cloud: gcloud auth application-default login", ja: "Google Cloud にログイン: gcloud auth application-default login"))
        }
        if answers.usesAWS {
            let env = SetupEnvironment.detect()
            if let p = answers.awsProfile, env.awsProfiles.first(where: { $0.name == p })?.usesSSO == true {
                steps.append(tr("Sign in to AWS: aws sso login --profile \(p)", ja: "AWS にログイン: aws sso login --profile \(p)"))
            } else if env.awsProfiles.isEmpty {
                steps.append(tr("Set up AWS credentials: aws configure sso", ja: "AWS の認証情報を設定: aws configure sso"))
            }
        }
        steps.append(tr("Allow audio recording: cappy doctor --request-permissions\(flag)", ja: "録音の許可: cappy doctor --request-permissions\(flag)"))
        steps.append(tr("Record: cappy record --app us.zoom.xos\(flag)", ja: "録音: cappy record --app us.zoom.xos\(flag)"))
        io.write(tr("\nNext steps:\n", ja: "\n次の手順:\n") + steps.enumerated().map { "  \($0.offset + 1). \($0.element)\n" }.joined())

        if try wizard.confirm(tr("Check the settings with `cappy doctor\(flag)` now?", ja: "`cappy doctor\(flag)` で今の設定を確認しますか？"), default: true) {
            io.write("\n")
            let doctor = try Doctor.parse(profileArgs)
            try await doctor.run()
        }
    }
}
