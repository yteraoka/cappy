import Foundation

/// `cappy init` で決めた設定（1 プロファイル分）
public struct SetupAnswers: Equatable, Sendable {
    public var profileName = "default"
    /// 文字起こしのクラウド: google / aws / none
    public var provider = "google"
    /// provider = google のモデル（gemini-* なら Gemini、それ以外は Speech-to-Text）
    public var transcribeModel: String?
    /// provider = google の location
    public var transcribeLocation: String?
    public var language = "ja-JP"
    public var outputDir = "~/Recordings/cappy"
    public var googleProjectID: String?
    public var googleBucket: String?
    public var awsProfile: String?
    public var awsRegion: String?
    /// provider = aws の S3 バケット
    public var awsBucket: String?
    /// 要約のクラウド: google / aws / none
    public var summaryProvider = "none"
    public var summaryModel: String?
    public var summaryRegion: String?
    public var summaryAuto = false

    public init() {}

    public var usesGoogleCloud: Bool { provider == "google" || summaryProvider == "google" }
    public var usesAWS: Bool { provider == "aws" || summaryProvider == "aws" }
}

/// 設定ファイルの組み立てと書き換え
public enum SetupConfigFile {
    /// 1 プロファイル分の TOML
    public static func render(_ a: SetupAnswers) -> String {
        let base = "profiles.\(a.profileName)"
        var out: [String] = []
        func section(_ name: String, _ entries: [(String, String?)]) {
            let lines = entries.compactMap { key, value in value.map { "\(key) = \($0)" } }
            guard !lines.isEmpty else { return }
            if !out.isEmpty { out.append("") }
            out.append("[\(name)]")
            out += lines
        }
        section(base, [("language", quote(a.language)), ("output_dir", quote(a.outputDir))])
        // アカウントの設定（文字起こしと要約で共通）
        section(base + ".google", [("project_id", a.googleProjectID.map(quote)), ("bucket", a.googleBucket.map(quote))])
        section(base + ".aws", [("profile", a.awsProfile.map(quote)), ("region", a.awsRegion.map(quote)),
                                ("bucket", a.awsBucket.map(quote))])
        section(base + ".transcribe", [("provider", quote(a.provider)), ("model", a.transcribeModel.map(quote)),
                                       ("location", a.transcribeLocation.map(quote))])
        if a.provider != "none" {
            section(base + ".summary", [("provider", quote(a.summaryProvider)),
                                        ("model", a.summaryProvider == "none" ? nil : a.summaryModel.map(quote)),
                                        ("region", a.summaryProvider == "none" ? nil : a.summaryRegion.map(quote)),
                                        ("auto", a.summaryProvider == "none" ? nil : (a.summaryAuto ? "true" : "false"))])
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// 既存の設定ファイル（なければ nil）に、プロファイルを追加する（同名のプロファイルは置き換える）
    public static func merged(existing: String?, answers: SetupAnswers, date: Date = Date()) -> String {
        let profile = render(answers)
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return """
            # cappy config (created by `cappy init` on \(f.string(from: date)))
            # All settings are described in config.example.toml: https://github.com/yteraoka/cappy
            # Do not write credentials here (Google uses Application Default Credentials, AWS uses ~/.aws profiles)

            \(profile)
            """
        }
        var rest = removingProfile(answers.profileName, from: existing)
        while rest.hasSuffix("\n\n") { rest.removeLast() }
        if !rest.hasSuffix("\n") { rest += "\n" }
        return rest + "\n" + profile
    }

    /// [profiles.<name>] と [profiles.<name>.*] の節を取り除く（ほかの節とコメントは残す）。
    /// 取り除く節の末尾にあるコメントと空行は、次の節の説明であることが多いので、次の節を残すなら一緒に残す
    public static func removingProfile(_ name: String, from text: String) -> String {
        var kept: [Substring] = []
        var pending: [Substring] = []   // 取り除く節の中で、次の見出しの直前に続くコメントと空行
        var skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let path = headerPath(line) {
                let ours = path.count >= 2 && path[0] == "profiles" && path[1] == name
                if skipping && !ours { kept += pending }
                pending.removeAll()
                skipping = ours
            } else if skipping {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") { pending.append(line) } else { pending.removeAll() }
                continue
            }
            if !skipping { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    /// 節の見出し（[a.b] / [[a.b]]）ならキーの並びを返す
    static func headerPath(_ line: Substring) -> [String]? {
        var s = line.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("[") else { return nil }
        if let hash = s.firstIndex(of: "#"), !s[..<hash].contains("\"") { s = String(s[..<hash]).trimmingCharacters(in: .whitespaces) }
        let isArray = s.hasPrefix("[[")
        let open = isArray ? 2 : 1
        guard s.hasSuffix(isArray ? "]]" : "]"), s.count > open * 2 else { return nil }
        let inner = s.dropFirst(open).dropLast(open)
        return inner.split(separator: ".").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case _ where ch.value < 0x20: out += String(format: "\\u%04X", ch.value)
            default: out.unicodeScalars.append(ch)
            }
        }
        return out + "\""
    }
}

/// 既定値の候補（gcloud の設定・~/.aws/config）
public struct SetupEnvironment: Sendable {
    public struct AWSProfile: Sendable, Equatable {
        public var name: String
        public var region: String?
        public var usesSSO: Bool
        public init(name: String, region: String? = nil, usesSSO: Bool = false) {
            self.name = name
            self.region = region
            self.usesSSO = usesSSO
        }
    }

    public var gcloudProject: String?
    public var awsProfiles: [AWSProfile] = []
    /// AWS_PROFILE / AWS_DEFAULT_PROFILE
    public var awsProfileFromEnvironment: String?
    /// AWS_REGION / AWS_DEFAULT_REGION
    public var awsRegionFromEnvironment: String?
    public var awsConfigPath = "~/.aws/config"

    public init(gcloudProject: String? = nil, awsProfiles: [AWSProfile] = [], awsProfileFromEnvironment: String? = nil,
                awsRegionFromEnvironment: String? = nil) {
        self.gcloudProject = gcloudProject
        self.awsProfiles = awsProfiles
        self.awsProfileFromEnvironment = awsProfileFromEnvironment
        self.awsRegionFromEnvironment = awsRegionFromEnvironment
    }

    public static func detect(variables: [String: String] = ProcessInfo.processInfo.environment,
                              home: String = NSHomeDirectory()) -> SetupEnvironment {
        func value(_ k: String) -> String? { variables[k].flatMap { $0.isEmpty ? nil : $0 } }
        var env = SetupEnvironment()
        env.gcloudProject = value("CLOUDSDK_CORE_PROJECT") ?? value("GOOGLE_CLOUD_PROJECT")
            ?? gcloudProject(configDir: value("CLOUDSDK_CONFIG") ?? (home as NSString).appendingPathComponent(".config/gcloud"))
        let aws = AWSEnvironment(variables: variables, homeDirectory: home)
        env.awsConfigPath = aws.configPath
        if let files = try? AWSConfigFile.load(configPath: aws.configPath, credentialsPath: aws.credentialsPath) {
            env.awsProfiles = files.profiles.keys.sorted().map { name in
                let p = files.profiles[name] ?? [:]
                return AWSProfile(name: name, region: p["region"].flatMap { $0.isEmpty ? nil : $0 },
                                  usesSSO: p["sso_session"] != nil || p["sso_start_url"] != nil)
            }
        }
        env.awsProfileFromEnvironment = value("AWS_PROFILE") ?? value("AWS_DEFAULT_PROFILE")
        env.awsRegionFromEnvironment = value("AWS_REGION") ?? value("AWS_DEFAULT_REGION")
        return env
    }

    /// gcloud の現在の構成の [core] project
    static func gcloudProject(configDir: String) -> String? {
        let active = (try? String(contentsOfFile: (configDir as NSString).appendingPathComponent("active_config"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (active?.isEmpty ?? true) ? "default" : active!
        let path = (configDir as NSString).appendingPathComponent("configurations/config_\(name)")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var inCore = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inCore = line == "[core]"; continue }
            guard inCore, let eq = line.firstIndex(of: "=") else { continue }
            if line[..<eq].trimmingCharacters(in: .whitespaces) == "project" {
                let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }
}

/// 対話のやり取り（テストでは差し替える）
public struct SetupIO: Sendable {
    public var readLine: @Sendable () -> String?
    public var write: @Sendable (String) -> Void

    public init(readLine: @escaping @Sendable () -> String?, write: @escaping @Sendable (String) -> Void) {
        self.readLine = readLine
        self.write = write
    }
}

/// 対話で 1 プロファイル分の設定を決める
public struct SetupWizard {
    public struct Cancelled: Error {}

    let io: SetupIO
    let env: SetupEnvironment
    let existingProfiles: Set<String>

    public init(io: SetupIO, environment: SetupEnvironment, existingProfiles: Set<String>) {
        self.io = io
        self.env = environment
        self.existingProfiles = existingProfiles
    }

    public func run(profileName: String? = nil) throws -> SetupAnswers {
        var a = SetupAnswers()
        a.profileName = try askProfileName(initial: profileName)

        section(tr("Transcription", ja: "文字起こし"))
        a.provider = try choose(tr("Which cloud should transcribe the recordings?", ja: "文字起こしに使うクラウドを選んでください"), [
            ("google", tr("Google Cloud (Gemini on Vertex AI, or Speech-to-Text)", ja: "Google Cloud（Vertex AI の Gemini、または Speech-to-Text）")),
            ("aws", tr("AWS (Amazon Transcribe)", ja: "AWS（Amazon Transcribe）")),
            ("none", tr("None: record only, nothing is sent outside", ja: "使わない: 録音だけ行い、外部には送信しない")),
        ], default: "google")
        a.language = try ask(tr("Meeting language (e.g. ja-JP, en-US)", ja: "会議の言語（例: ja-JP, en-US）"),
                             default: L10n.current == .ja ? "ja-JP" : "en-US", validate: Self.validLanguage)

        switch a.provider {
        case "google":
            try askGoogleCloud(&a)
            a.transcribeModel = try choose(tr("Transcription model", ja: "文字起こしに使うモデル"), [
                (GeminiSettings().model, tr("Gemini on Vertex AI. Recommended", ja: "Vertex AI の Gemini。おすすめ")),
                (GoogleSettings().model, "Speech-to-Text v2"),
            ], default: GeminiSettings().model)
            if Profile.transcriptionService(provider: a.provider, model: a.transcribeModel) == .gemini {
                a.transcribeLocation = try choose(tr("Vertex AI location for Gemini", ja: "Gemini を使う Vertex AI のロケーション"), [
                    ("global", tr("lowest latency and price", ja: "遅延・料金とも最も小さい")),
                    ("us", tr("processed in the US only", ja: "米国内だけで処理")),
                    ("eu", tr("processed in the EU only", ja: "EU 内だけで処理")),
                ], default: "global")
            } else {
                a.transcribeLocation = try ask(tr("Speech-to-Text location (e.g. us, eu, asia-northeast1)", ja: "Speech-to-Text のロケーション（例: us, eu, asia-northeast1）"),
                                           default: "us", validate: Self.validLocation)
            }
        case "aws":
            try askAWS(&a, bucket: true)
        default:
            break
        }

        if a.provider != "none" {
            section(tr("Meeting summary", ja: "会議の要約"))
            a.summaryProvider = try choose(tr("Which cloud should create the meeting summary?", ja: "要約に使うクラウドを選んでください"), [
                ("google", tr("Google Cloud (Claude / Gemini on Vertex AI)", ja: "Google Cloud（Vertex AI の Claude / Gemini）")),
                ("aws", tr("AWS (Claude and other models on Amazon Bedrock)", ja: "AWS（Amazon Bedrock の Claude など）")),
                ("none", tr("No summary", ja: "要約しない")),
            ], default: a.provider)
            switch a.summaryProvider {
            case "google":
                if a.googleProjectID == nil { try askGoogleProject(&a) }
                a.summaryModel = try chooseModel(tr("Summary model", ja: "要約に使うモデル"), [
                    (SummarySettings.defaultModel, "Gemini"),
                    (SummarySettings.defaultBedrockModel, "Claude"),
                ], default: SummarySettings.defaultModel, bedrock: false)
                a.summaryRegion = try choose(tr("Vertex AI region for the summary", ja: "要約に使う Vertex AI のリージョン"), [
                    ("global", tr("processed anywhere", ja: "処理する場所を限定しない")),
                    ("us", tr("processed in the US only, about 10% more expensive", ja: "米国内だけで処理。約 10% 高い")),
                    ("eu", tr("processed in the EU only, about 10% more expensive", ja: "EU 内だけで処理。約 10% 高い")),
                ], default: "global")
            case "aws":
                if a.awsRegion == nil && a.awsProfile == nil { try askAWS(&a, bucket: false) }
                a.summaryModel = try chooseModel(tr("Summary model", ja: "要約に使うモデル"), [
                    (SummarySettings.defaultBedrockModel, "Claude"),
                    ("global.moonshotai.kimi-k3.1", "Kimi K3.1"),
                ], default: SummarySettings.defaultBedrockModel, bedrock: true)
                a.summaryRegion = try ask(tr("Bedrock inference profile scope (global / jp / us / eu / au / apac, or a Region name)", ja: "Bedrock の推論プロファイルの範囲（global / jp / us / eu / au / apac、またはリージョン名）"),
                                          default: Self.bedrockScope(for: a.awsRegion ?? effectiveAWSRegion(a)), validate: Self.validLocation)
            default:
                break
            }
            if a.summaryProvider != "none" {
                a.summaryAuto = try confirm(tr("Create the summary automatically after transcription?", ja: "文字起こしの後に続けて要約を作りますか？"), default: true)
            }
        }

        section(tr("Recordings", ja: "録音"))
        a.outputDir = try ask(tr("Directory to save recordings in", ja: "録音を保存するディレクトリ"), default: "~/Recordings/cappy",
                              validate: { $0.isEmpty ? tr("Enter a directory", ja: "ディレクトリを入力してください") : nil })
        return a
    }

    // MARK: 質問

    private func askProfileName(initial: String?) throws -> String {
        var suggestion = initial ?? "default"
        while true {
            let name = try ask(tr("Profile name", ja: "プロファイル名"), default: suggestion, validate: Self.validProfileName)
            guard existingProfiles.contains(name) else { return name }
            if try confirm(tr("Profile \(name) already exists. Replace it?", ja: "プロファイル \(name) はすでにあります。置き換えますか？"), default: false) {
                return name
            }
            suggestion = ""
        }
    }

    private func askGoogleCloud(_ a: inout SetupAnswers) throws {
        try askGoogleProject(&a)
        a.googleBucket = try ask(tr("Cloud Storage bucket to hold the audio temporarily (create it in advance)", ja: "音声を一時的に置く Cloud Storage のバケット（事前に作成しておく）"),
                                 default: nil, transform: { Self.stripScheme($0, "gs://") }, validate: Self.validBucket)
    }

    private func askGoogleProject(_ a: inout SetupAnswers) throws {
        a.googleProjectID = try ask(tr("Google Cloud project ID", ja: "Google Cloud のプロジェクト ID"), default: env.gcloudProject,
                                    validate: { $0.isEmpty || $0.contains(" ") ? tr("Enter the project ID", ja: "プロジェクト ID を入力してください") : nil })
    }

    private func askAWS(_ a: inout SetupAnswers, bucket: Bool) throws {
        if env.awsProfiles.isEmpty {
            io.write(tr("  No profiles found in \(env.awsConfigPath). Create one with `aws configure sso` (or leave this empty to use the default credentials).\n",
                        ja: "  \(env.awsConfigPath) にプロファイルがありません。`aws configure sso` で作成できます（空のままなら既定の認証情報を使います）。\n"))
        } else {
            io.write(tr("  Profiles in \(env.awsConfigPath): ", ja: "  \(env.awsConfigPath) のプロファイル: ") + env.awsProfiles.map(\.name).joined(separator: ", ") + "\n")
        }
        let names = Set(env.awsProfiles.map(\.name))
        let suggested = env.awsProfileFromEnvironment ?? (names.contains("default") ? "default" : env.awsProfiles.first?.name)
        let profile = try ask(tr("AWS profile", ja: "AWS のプロファイル"), default: suggested, allowEmpty: true, validate: { name in
            guard !name.isEmpty, !names.isEmpty, !names.contains(name) else { return nil }
            return tr("Profile \(name) is not in \(env.awsConfigPath)", ja: "プロファイル \(name) は \(env.awsConfigPath) にありません")
        })
        a.awsProfile = profile.isEmpty ? nil : profile
        a.awsRegion = try ask(tr("AWS Region", ja: "AWS のリージョン"), default: effectiveAWSRegion(a), validate: Self.validAWSRegion)
        if bucket {
            a.awsBucket = try ask(tr("S3 bucket to hold the audio temporarily (create it in advance in the same Region)", ja: "音声を一時的に置く S3 バケット（同じリージョンに事前に作成しておく）"),
                                  default: nil, transform: { Self.stripScheme($0, "s3://") }, validate: Self.validBucket)
        }
    }

    private func effectiveAWSRegion(_ a: SetupAnswers) -> String {
        if let r = a.awsRegion { return r }
        if let p = a.awsProfile, let r = env.awsProfiles.first(where: { $0.name == p })?.region { return r }
        return env.awsRegionFromEnvironment ?? (a.language.hasPrefix("ja") ? "ap-northeast-1" : "us-east-1")
    }

    private func chooseModel(_ question: String, _ options: [(String, String)], default def: String, bedrock: Bool) throws -> String {
        let other = "__other__"
        let picked = try choose(question, options.map { ($0.0, $0.1) } + [(other, tr("Other (enter a model ID)", ja: "そのほか（モデル ID を入力）"))], default: def)
        guard picked == other else { return picked }
        return try ask(tr("Model ID", ja: "モデル ID"), default: nil, validate: { id in
            guard let family = SummaryModelFamily.of(id) else {
                return tr("Enter a model ID starting with claude- or gemini-\(bedrock ? ", or a Bedrock model ID" : "")", ja: "claude- または gemini- で始まるモデル ID\(bedrock ? "、または Bedrock のモデル ID" : "")を入力してください")
            }
            if bedrock && family == .gemini { return tr("Gemini models are not available on Bedrock", ja: "Bedrock では Gemini のモデルは使えません") }
            if !bedrock && family == .bedrockChat { return tr("Bedrock model IDs can be used only with Bedrock", ja: "Bedrock のモデル ID は Bedrock でだけ使えます") }
            return nil
        })
    }

    // MARK: 入出力

    private func section(_ title: String) {
        io.write("\n\(title)\n")
    }

    private func readAnswer() throws -> String {
        guard let line = io.readLine() else { throw Cancelled() }
        return line.trimmingCharacters(in: .whitespaces)
    }

    func ask(_ question: String, default def: String?, allowEmpty: Bool = false,
             transform: (String) -> String = { $0 }, validate: (String) -> String? = { _ in nil }) throws -> String {
        while true {
            io.write("? \(question)\(def.map { $0.isEmpty ? "" : " [\($0)]" } ?? ""): ")
            var answer = transform(try readAnswer())
            if answer.isEmpty, let def { answer = def }
            if answer.isEmpty {
                if allowEmpty { return "" }
                io.write(tr("  Please enter a value\n", ja: "  入力してください\n"))
                continue
            }
            if let problem = validate(answer) {
                io.write("  \(problem)\n")
                continue
            }
            return answer
        }
    }

    func choose(_ question: String, _ options: [(value: String, label: String)], default def: String) throws -> String {
        io.write("? \(question)\n")
        for (i, o) in options.enumerated() {
            // 値が内部用（__other__ など）や表示名と同じなら表示名だけ出す
            let text = o.value.hasPrefix("__") || o.value == o.label ? o.label : "\(o.value) — \(o.label)"
            io.write("  \(i + 1)) \(text)\n")
        }
        let defIndex = (options.firstIndex { $0.value == def } ?? 0) + 1
        while true {
            io.write(tr("  Choose [\(defIndex)]: ", ja: "  番号を選択 [\(defIndex)]: "))
            let answer = try readAnswer()
            if answer.isEmpty { return options[defIndex - 1].value }
            if let n = Int(answer), (1...options.count).contains(n) { return options[n - 1].value }
            if let o = options.first(where: { $0.value == answer && !$0.value.hasPrefix("__") }) { return o.value }
            io.write(tr("  Enter a number from 1 to \(options.count)\n", ja: "  1〜\(options.count) の番号を入力してください\n"))
        }
    }

    public func confirm(_ question: String, default def: Bool) throws -> Bool {
        while true {
            io.write("? \(question) [\(def ? "Y/n" : "y/N")]: ")
            switch try readAnswer().lowercased() {
            case "": return def
            case "y", "yes", "はい": return true
            case "n", "no", "いいえ": return false
            default: io.write(tr("  Answer y or n\n", ja: "  y か n で答えてください\n"))
            }
        }
    }

    // MARK: 検証

    static func validProfileName(_ s: String) -> String? {
        s.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == nil
            ? tr("Use letters, digits, - and _ only", ja: "英数字と - _ だけを使ってください") : nil
    }

    static func validLanguage(_ s: String) -> String? {
        s.range(of: "^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) == nil
            ? tr("Enter a language code such as ja-JP or en-US", ja: "ja-JP や en-US のような言語コードを入力してください") : nil
    }

    static func validLocation(_ s: String) -> String? {
        s.range(of: "^[a-z0-9-]+$", options: .regularExpression) == nil
            ? tr("Use lowercase letters, digits and - only", ja: "小文字の英数字と - だけを使ってください") : nil
    }

    static func validAWSRegion(_ s: String) -> String? {
        s.range(of: "^[a-z]{2}(-[a-z]+)+-[0-9]+$", options: .regularExpression) == nil
            ? tr("Enter a Region name such as ap-northeast-1", ja: "ap-northeast-1 のようなリージョン名を入力してください") : nil
    }

    static func validBucket(_ s: String) -> String? {
        s.range(of: "^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", options: .regularExpression) == nil
            ? tr("Enter a bucket name (3-63 lowercase letters, digits, ., - or _)", ja: "バケット名を入力してください（小文字の英数字と . - _ で 3〜63 文字）") : nil
    }

    static func stripScheme(_ s: String, _ scheme: String) -> String {
        var v = s
        if v.lowercased().hasPrefix(scheme) { v = String(v.dropFirst(scheme.count)) }
        while v.hasSuffix("/") { v.removeLast() }
        return v
    }

    /// AWS のリージョンに近い Bedrock の推論プロファイルの範囲
    static func bedrockScope(for region: String) -> String {
        switch region {
        case "ap-northeast-1", "ap-northeast-3": return "jp"
        case "ap-southeast-2", "ap-southeast-4": return "au"
        case _ where region.hasPrefix("us-gov-"): return "us-gov"
        case _ where region.hasPrefix("us-"): return "us"
        case _ where region.hasPrefix("eu-"): return "eu"
        case _ where region.hasPrefix("ca-"): return "ca"
        case _ where region.hasPrefix("ap-"): return "apac"
        default: return "global"
        }
    }
}
