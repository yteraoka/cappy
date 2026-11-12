import ArgumentParser
import CappyKit
import Foundation

struct Completion: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("Print a shell completion script (bash / zsh)", ja: "シェルの補完スクリプトを出力する（bash / zsh）"),
        discussion: tr("""
        zsh (compinit must be called in ~/.zshrc):
          mkdir -p ~/.zfunc
          cappy completion zsh > ~/.zfunc/_cappy
          # In ~/.zshrc, before compinit: fpath=(~/.zfunc $fpath)

        bash (with bash-completion):
          mkdir -p ~/.local/share/bash-completion/completions
          cappy completion bash > ~/.local/share/bash-completion/completions/cappy
          # Without bash-completion, add to ~/.bashrc: source <(cappy completion bash)

        When installed with Homebrew, the formula installs the completion scripts.
        --profile, --app, --pid, --mic and others are completed from the current config file, audio processes and devices.
        """, ja: """
        zsh（~/.zshrc で compinit を呼んでいること）:
          mkdir -p ~/.zfunc
          cappy completion zsh > ~/.zfunc/_cappy
          # ~/.zshrc の compinit より前に: fpath=(~/.zfunc $fpath)

        bash（bash-completion を使っている場合）:
          mkdir -p ~/.local/share/bash-completion/completions
          cappy completion bash > ~/.local/share/bash-completion/completions/cappy
          # bash-completion がなければ ~/.bashrc に: source <(cappy completion bash)

        Homebrew で入れた場合は、formula が補完スクリプトも配置します。
        --profile・--app・--pid・--mic などは、その時点の設定ファイルや音声プロセス・デバイスから候補を出します。
        """)
    )

    @Argument(help: ArgumentHelp(tr("Shell (bash / zsh; detected from $SHELL if omitted)", ja: "シェル（bash / zsh。省略時は $SHELL から判断）")), completion: .list(["bash", "zsh"]))
    var shell: String?

    func run() throws {
        let name = shell ?? CompletionShell.autodetected()?.rawValue
        guard let name, let s = CompletionShell(rawValue: name), s == .bash || s == .zsh else {
            throw CappyError.usage(tr("Supported shells are bash and zsh", ja: "対応しているシェルは bash と zsh です") + (name.map { tr(" (given: \($0))", ja: "（指定: \($0)）") } ?? ""),
                                   hint: tr("Specify the shell, e.g. `cappy completion zsh`", ja: "`cappy completion zsh` のようにシェルを指定してください"))
        }
        print(Cappy.completionScript(for: s), terminator: "")
    }
}

/// 補完の候補。設定ファイルや Core Audio の状態から作る（失敗したら候補なし）
enum CompletionCandidates {
    /// zsh では「値:説明」の形で説明を付けられる（値の「:」はエスケープする）
    static func format(_ items: [(value: String, description: String?)]) -> [String] {
        let zsh = CompletionShell.requesting == .zsh
        return items.map { item in
            guard zsh else { return item.value }
            let v = item.value.replacingOccurrences(of: ":", with: "\\:")
            return item.description.map { "\(v):\($0)" } ?? v
        }
    }

    static func profiles() -> [String] {
        guard let config = try? CappyConfig.load() else { return ["default"] }
        let names = Set(config.profiles.keys).union(["default"]).sorted()
        return format(names.map { n in
            let p = config.profiles[n]
            return (n, p.map { "transcribe=\($0.provider), summary=\($0.summaryProvider)" })
        })
    }

    static func processes() -> [AudioProcessInfo] {
        ((try? AudioProcesses.list()) ?? []).sorted { a, b in
            if a.isRunningOutput != b.isRunningOutput { return a.isRunningOutput }
            return a.bundleID == b.bundleID ? a.pid < b.pid : a.bundleID < b.bundleID
        }
    }

    /// 音声プロセスの bundle ID（出力中のものを先に）
    static func apps() -> [String] {
        var seen = Set<String>()
        let items = processes().filter { !$0.bundleID.isEmpty && seen.insert($0.bundleID).inserted }.map {
            ($0.bundleID, Optional($0.name + ($0.isRunningOutput ? tr(" (playing)", ja: "（出力中）") : "")))
        }
        return format(items)
    }

    static func pids() -> [String] {
        format(processes().map { (String($0.pid), Optional([$0.name, $0.bundleID].filter { !$0.isEmpty }.joined(separator: " ")
            + ($0.isRunningOutput ? tr(" (playing)", ja: "（出力中）") : ""))) })
    }

    /// 入力デバイスの UID
    static func microphones() -> [String] {
        let devices = ((try? AudioDevices.all()) ?? []).filter { $0.inputChannels > 0 && !$0.uid.hasPrefix("dev.cappy.") }
        return format(devices.map { ($0.uid, Optional($0.name + ($0.isDefaultInput ? tr(" (default)", ja: "（既定）") : ""))) })
    }

    /// よく使うモデルと、設定ファイルに書かれたモデル
    static func models() -> [String] {
        var models = ["gemini-4-argon", "gemini-3.5-flash", "claude-opus-5-5", "claude-opus-4-8",
                      "global.moonshotai.kimi-k3.1", "global.zai.glm-5.3"]
        if let config = try? CappyConfig.load() {
            for p in config.profiles.values {
                models.append(p.summary.model)
                if let f = p.summary.fallbackModel, !f.isEmpty { models.append(f) }
            }
        }
        var seen = Set<String>()
        return format(models.filter { seen.insert($0).inserted }.map { ($0, nil) })
    }

    static let providers = Profile.providers
    static let transcribeModels = [GeminiSettings().model, GoogleSettings().model]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]
    static let formats = ["md,json,srt", "md", "json", "srt", "md,json", "md,srt", "json,srt"]
    static let languages = ["ja-JP", "en-US", "en-GB", "zh-CN", "ko-KR"]
}
