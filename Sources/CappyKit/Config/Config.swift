import Foundation

public struct GoogleSettings: Sendable, Equatable {
    public var projectID: String?
    public var location: String = "us"
    public var bucket: String?
    public var model: String = "chirp_3"
    public var deleteRemoteAfter: Bool = true
    /// 単語タイムスタンプ（chirp_3 の BatchRecognize では有効時に 1 ファイル約 20 分までの制限がある）
    public var wordTimestamps: Bool = true
    /// 1 ファイルあたりの最大長（分）。超える場合は分割して送信する。nil なら wordTimestamps から自動決定
    public var chunkMinutes: Int?
    /// remote トラックで話者分離を試みるか
    public var diarization: Bool = true
    public var minSpeakers: Int?
    public var maxSpeakers: Int?

    public init() {}

    /// 実際に使う分割長（秒）
    public var effectiveChunkSeconds: TimeInterval {
        if let chunkMinutes, chunkMinutes > 0 { return TimeInterval(chunkMinutes * 60) }
        return wordTimestamps ? 19 * 60 : 59 * 60
    }
}

/// Vertex AI の Gemini による文字起こし（ファイル: generateContent、リアルタイム: Live API）
public struct GeminiSettings: Sendable, Equatable {
    public var location: String = "global"
    /// 録音済みファイルの文字起こしに使うモデル
    public var model: String = "gemini-3.5-transcribe"
    /// リアルタイム文字起こし（record --live）に使うモデル
    public var liveModel: String = "gemini-3.5-transcribe-live"
    /// 1 リクエストあたりの長さ（分）。話者分離・タイムスタンプ有効時は 15 分までのため既定 14 分
    public var chunkMinutes: Int = 14
    /// remote トラックで話者分離を行うか
    public var diarization: Bool = true
    /// 単語タイムスタンプ（無効にすると発言の時刻が推定になる）
    public var wordTimestamps: Bool = true
    /// 認識を寄せたい語句（固有名詞・製品名など。1000 語まで）
    public var customVocabulary: [String] = []

    public init() {}

    public var chunkSeconds: TimeInterval { TimeInterval(max(1, chunkMinutes) * 60) }
}

/// 会議の要約（google: Vertex AI の Claude / Gemini、aws: Amazon Bedrock の Claude など）
public struct SummarySettings: Sendable, Equatable {
    /// google / aws / none。nil なら文字起こしと同じ（transcribe.provider）
    public var provider: String?
    /// 既定は google.project_id
    public var projectID: String?
    /// Vertex AI: global / us / eu / リージョン名。
    /// Bedrock: 推論プロファイルの範囲（global / jp / us / eu / au / apac など）、またはリージョン名（そのリージョンだけで処理）
    public var region: String = "global"
    /// claude- で始まれば Claude、gemini- で始まれば Gemini を使う（Bedrock は Claude のみ）
    public var model: String = SummarySettings.defaultModel
    /// 拒否（refusal）されたときに再試行するモデル。nil ならモデルの系統で決める
    /// （Claude は claude-opus-4-8、Gemini は再試行しない）。空文字なら再試行しない
    public var fallbackModel: String?
    /// low / medium / high / xhigh / max
    public var effort: String = "high"
    public var maxTokens: Int = 32000
    /// true なら transcribe の完了後に自動で要約する
    public var auto: Bool = false
    /// 要約の書き方を追加で指示するファイル（任意）
    public var instructionsFile: String?

    public init() {}

    public static let defaultModel = "gemini-4-argon"
    /// provider = aws（Bedrock）で model を省略したときのモデル
    public static let defaultBedrockModel = "claude-opus-5-5"
    public static let knownProviders: Set<String> = ["google", "aws", "none"]
    /// Bedrock の推論プロファイルの範囲として知られているもの（これ以外は警告だけ出す）
    public static let knownBedrockRoutings: Set<String> = ["global", "us", "eu", "jp", "au", "apac", "ca", "us-gov"]

    /// 実際に使う再試行先。model が設定の model と違う（--model で上書きした）場合は系統の既定を使う
    public func effectiveFallback(for model: String) -> String? {
        if model == self.model, let f = fallbackModel { return f.isEmpty ? nil : f }
        return SummaryModelFamily.of(model)?.defaultFallback
    }
    public static let knownEfforts: Set<String> = ["low", "medium", "high", "xhigh", "max"]
}

/// AWS の共通設定（[profiles.<name>.aws]）。認証情報そのものは書かず、~/.aws/config のプロファイルを使う
public struct AWSSettings: Sendable, Equatable {
    /// ~/.aws/config のプロファイル名。nil なら AWS_PROFILE → AWS_DEFAULT_PROFILE → default
    public var profile: String?
    /// nil なら AWS_REGION → AWS_DEFAULT_REGION → プロファイルの region
    public var region: String?
    /// Amazon Transcribe に送る音声を一時的に置く S3 バケット（文字起こしと同じリージョン）
    public var bucket: String?
    /// 文字起こし後に S3 上の音声と Transcribe のジョブを削除する
    public var deleteRemoteAfter: Bool = true

    public init(profile: String? = nil, region: String? = nil, bucket: String? = nil, deleteRemoteAfter: Bool = true) {
        self.profile = profile
        self.region = region
        self.bucket = bucket
        self.deleteRemoteAfter = deleteRemoteAfter
    }
}

/// 文字起こしに使うサービス（transcribe.provider と transcribe.model から決まる）
public enum TranscriptionService: String, Sendable {
    /// Vertex AI の Gemini（provider = google、model = gemini-*）
    case gemini
    /// Speech-to-Text v2（provider = google、model = chirp_3 など）
    case speech
    /// Amazon Transcribe（provider = aws）
    case amazon
    case none

    /// 画面に出す名前
    public var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .speech: return "Speech-to-Text"
        case .amazon: return "Amazon Transcribe"
        case .none: return "none"
        }
    }
}

public struct Profile: Sendable, Equatable {
    public var name: String
    /// 文字起こしのクラウド: google / aws / none
    public var provider: String = "google"
    /// transcribe.model（nil なら既定のモデル。google なら gemini-3.5-transcribe）
    public var transcribeModel: String?
    public var language: String = "ja-JP"
    public var outputDir: String = "~/Recordings/cappy"
    /// 空き容量がこれを下回ったら警告（MB）
    public var diskWarnMB: Int = 1024
    /// 空き容量がこれを下回ったら録音を停止（MB）
    public var diskStopMB: Int = 300
    public var google = GoogleSettings()
    public var gemini = GeminiSettings()
    public var summary = SummarySettings()
    /// [profiles.<name>.aws] があるときだけ設定される
    public var aws: AWSSettings?
    /// Amazon Transcribe（provider = aws）
    public var awsTranscribe = TranscribeSettings()

    public init(name: String) { self.name = name }

    /// 実際に使う要約のクラウド（google / aws / none）。省略時は文字起こしと同じ
    public var summaryProvider: String { summary.provider ?? provider }

    /// 文字起こしに使うサービス
    public var transcriptionService: TranscriptionService { Self.transcriptionService(provider: provider, model: transcribeModel) }

    /// provider と model から文字起こしのサービスを決める（google では gemini- で始まるモデルが Gemini、それ以外が Speech-to-Text）
    public static func transcriptionService(provider: String, model: String?) -> TranscriptionService {
        switch provider {
        case "google": return (model ?? GeminiSettings().model).hasPrefix("gemini") ? .gemini : .speech
        case "aws": return .amazon
        default: return .none
        }
    }

    /// 要約に使う Google Cloud プロジェクト
    public var summaryProjectID: String? { summary.projectID ?? google.projectID }

    public var outputDirectoryURL: URL {
        URL(fileURLWithPath: FileSecurity.expandTilde(outputDir), isDirectory: true)
    }
}

public struct CappyConfig: Sendable {
    public var profiles: [String: Profile]
    public var path: URL
    public var fileExists: Bool

    public static var defaultPath: URL {
        if let env = ProcessInfo.processInfo.environment["CAPPY_CONFIG"], !env.isEmpty {
            return URL(fileURLWithPath: FileSecurity.expandTilde(env))
        }
        let base: String
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = xdg
        } else {
            base = FileSecurity.expandTilde("~/.config")
        }
        return URL(fileURLWithPath: base).appendingPathComponent("cappy/config.toml")
    }

    public static func load(from url: URL = CappyConfig.defaultPath) throws -> CappyConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CappyConfig(profiles: [:], path: url, fileExists: false)
        }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CappyError.usage(tr("Cannot read the config file: \(url.path): \(error.localizedDescription)", ja: "設定ファイルを読めません: \(url.path): \(error.localizedDescription)"))
        }
        return try parse(text, path: url)
    }

    public static func parse(_ text: String, path: URL) throws -> CappyConfig {
        let doc: [String: TOMLValue]
        do {
            doc = try TOML.parse(text)
        } catch {
            throw CappyError.usage(tr("Invalid config file format: \(path.path): \(error)", ja: "設定ファイルの書式が不正です: \(path.path): \(error)"))
        }
        var profiles: [String: Profile] = [:]
        for (name, value) in doc["profiles"]?.table ?? [:] {
            guard let t = value.table else {
                throw CappyError.usage(tr("profiles.\(name) must be a table", ja: "profiles.\(name) はテーブルである必要があります"))
            }
            profiles[name] = try parseProfile(name: name, t)
        }
        return CappyConfig(profiles: profiles, path: path, fileExists: true)
    }

    private static func parseProfile(name: String, _ t: [String: TOMLValue]) throws -> Profile {
        var p = Profile(name: name)
        let ctx = "profiles.\(name)"
        if let v = try str("language", t, ctx) { p.language = v }
        if let v = try str("output_dir", t, ctx) { p.outputDir = v }
        if let v = try int("disk_warn_mb", t, ctx) { p.diskWarnMB = v }
        if let v = try int("disk_stop_mb", t, ctx) { p.diskStopMB = v }

        // Google Cloud のアカウント（文字起こしと要約で共通）
        if let g = t["google"]?.table {
            let gctx = ctx + ".google"
            p.google.projectID = try str("project_id", g, gctx)
            p.google.bucket = try str("bucket", g, gctx)
            if let v = try bool("delete_remote_after", g, gctx) { p.google.deleteRemoteAfter = v }
            warnUnknownKeys(g, ["project_id", "bucket", "delete_remote_after"], gctx)
        }

        // 文字起こし。model / location / chunk_minutes はモデルのサービス（Gemini か Speech-to-Text）に、
        // diarization などはそれを持つすべてのサービスに当てる（cappy transcribe --model / --provider で切り替えても効くように）
        if let tt = t["transcribe"]?.table {
            let tctx = ctx + ".transcribe"
            if let v = try str("provider", tt, tctx) { p.provider = v }
            guard Profile.knownProviders.contains(p.provider) else {
                throw CappyError.usage(tr("Invalid \(tctx).provider: \(p.provider) (\(Profile.providerList))", ja: "\(tctx).provider が不正です: \(p.provider)（\(Profile.providerList)）"))
            }
            p.transcribeModel = try str("model", tt, tctx)
            let service = p.transcriptionService
            func googleOnly(_ key: String) -> CappyError {
                CappyError.usage(tr("\(tctx).\(key) can be set only with provider = \"google\"", ja: "\(tctx).\(key) は provider = \"google\" のときだけ指定できます"))
            }
            if let v = p.transcribeModel {
                switch service {
                case .gemini: p.gemini.model = v
                case .speech: p.google.model = v
                default: throw googleOnly("model")
                }
            }
            if let v = try str("location", tt, tctx) {
                switch service {
                case .gemini: p.gemini.location = v
                case .speech: p.google.location = v
                default: throw googleOnly("location")
                }
            }
            if let v = try int("chunk_minutes", tt, tctx) {
                switch service {
                case .gemini:
                    guard (1...15).contains(v) else { throw CappyError.usage(tr("\(tctx).chunk_minutes must be between 1 and 15 for Gemini", ja: "Gemini では \(tctx).chunk_minutes は 1〜15 にしてください")) }
                    p.gemini.chunkMinutes = v
                case .speech: p.google.chunkMinutes = v
                default: throw googleOnly("chunk_minutes")
                }
            }
            if let v = try str("live_model", tt, tctx) { p.gemini.liveModel = v }
            if let v = try bool("diarization", tt, tctx) {
                p.gemini.diarization = v
                p.google.diarization = v
                p.awsTranscribe.diarization = v
            }
            if let v = try bool("word_timestamps", tt, tctx) {
                p.gemini.wordTimestamps = v
                p.google.wordTimestamps = v
            }
            if let v = try int("min_speakers", tt, tctx) { p.google.minSpeakers = v }
            if let v = try int("max_speakers", tt, tctx) {
                p.google.maxSpeakers = v
                if (2...30).contains(v) {
                    p.awsTranscribe.maxSpeakers = v
                } else if service == .amazon {
                    throw CappyError.usage(tr("\(tctx).max_speakers must be between 2 and 30 for Amazon Transcribe", ja: "Amazon Transcribe では \(tctx).max_speakers は 2〜30 にしてください"))
                }
            }
            if let v = tt["custom_vocabulary"] {
                guard let list = v.array?.compactMap(\.string), list.count == v.array?.count else {
                    throw CappyError.usage(tr("\(tctx).custom_vocabulary must be an array of strings", ja: "\(tctx).custom_vocabulary は文字列の配列である必要があります"))
                }
                guard list.count <= 1000 else { throw CappyError.usage(tr("\(tctx).custom_vocabulary can have up to 1000 entries", ja: "\(tctx).custom_vocabulary は 1000 語までです")) }
                p.gemini.customVocabulary = list
            }
            p.awsTranscribe.vocabularyName = try str("vocabulary_name", tt, tctx)
            p.awsTranscribe.languageModelName = try str("language_model_name", tt, tctx)
            warnUnknownKeys(tt, ["provider", "model", "location", "chunk_minutes", "live_model", "diarization", "word_timestamps",
                                 "min_speakers", "max_speakers", "custom_vocabulary", "vocabulary_name", "language_model_name"], tctx)
        }

        do {
            let m = t["summary"]?.table ?? [:]
            let sctx = ctx + ".summary"
            p.summary.provider = try str("provider", m, sctx)
            p.summary.projectID = try str("project_id", m, sctx)
            if let v = try str("region", m, sctx) { p.summary.region = v }
            if let v = try str("model", m, sctx) { p.summary.model = v }
            p.summary.fallbackModel = try str("fallback_model", m, sctx)
            if let v = try str("effort", m, sctx) { p.summary.effort = v }
            if let v = try int("max_tokens", m, sctx) { p.summary.maxTokens = v }
            if let v = try bool("auto", m, sctx) { p.summary.auto = v }
            p.summary.instructionsFile = try str("instructions_file", m, sctx)
            if let v = p.summary.provider, !SummarySettings.knownProviders.contains(v) {
                throw CappyError.usage(tr("Invalid \(sctx).provider: \(v) (google / aws / none)", ja: "\(sctx).provider が不正です: \(v)（google / aws / none）"))
            }
            if p.summaryProvider == "aws" {
                if m["model"] == nil { p.summary.model = SummarySettings.defaultBedrockModel }
                for (key, value) in [("model", p.summary.model), ("fallback_model", p.summary.fallbackModel ?? "")]
                where SummaryModelFamily.of(value) == .gemini {
                    throw CappyError.usage(tr("Invalid \(sctx).\(key): \(value) (Gemini models are not available on Bedrock)", ja: "\(sctx).\(key) が不正です: \(value)（Bedrock では Claude のモデルだけを使えます）"))
                }
                let r = p.summary.region
                if !SummarySettings.knownBedrockRoutings.contains(r) && !BedrockClaudeClient.isAWSRegion(r) {
                    CappyLog.shared.warning(tr("\(sctx).region = \(r) is not a known Bedrock inference profile scope (global / jp / us / eu / au / apac, or a Region name)", ja: "\(sctx).region = \(r) は Bedrock の推論プロファイルの範囲として不明です（global / jp / us / eu / au / apac、またはリージョン名）"))
                }
            } else {
                for (key, value) in [("model", p.summary.model), ("fallback_model", p.summary.fallbackModel ?? "")]
                where value.contains("anthropic.") || SummaryModelFamily.of(value) == .bedrockChat {
                    throw CappyError.usage(tr("Invalid \(sctx).\(key): \(value) (Bedrock model IDs can be used only with provider = \"aws\")", ja: "\(sctx).\(key) が不正です: \(value)（Bedrock のモデル ID は provider = \"aws\" のときだけ使えます）"))
                }
            }
            if !SummarySettings.knownEfforts.contains(p.summary.effort) {
                throw CappyError.usage(tr("Invalid \(sctx).effort: \(p.summary.effort) (low / medium / high / xhigh / max)", ja: "\(sctx).effort が不正です: \(p.summary.effort)（low / medium / high / xhigh / max）"))
            }
            for (key, value) in [("model", p.summary.model), ("fallback_model", p.summary.fallbackModel ?? "")]
            where !value.isEmpty && SummaryModelFamily.of(value) == nil {
                throw CappyError.usage(tr("Invalid \(sctx).\(key): \(value) (a model ID starting with claude- or gemini-; on Bedrock, a Bedrock model ID such as moonshotai.kimi-k3.1 is also allowed)", ja: "\(sctx).\(key) が不正です: \(value)（claude- または gemini- で始まるモデル ID。Bedrock なら moonshotai.kimi-k3.1 のような Bedrock のモデル ID も可）"))
            }
            if p.summary.maxTokens < 1024 {
                throw CappyError.usage(tr("\(sctx).max_tokens must be 1024 or more", ja: "\(sctx).max_tokens は 1024 以上にしてください"))
            }
            warnUnknownKeys(m, ["provider", "project_id", "region", "model", "fallback_model", "effort",
                                "max_tokens", "auto", "instructions_file"], sctx)
        }
        if let a = t["aws"]?.table {
            let actx = ctx + ".aws"
            p.aws = AWSSettings(profile: try str("profile", a, actx), region: try str("region", a, actx),
                                bucket: try str("bucket", a, actx),
                                deleteRemoteAfter: try bool("delete_remote_after", a, actx) ?? true)
            warnUnknownKeys(a, ["profile", "region", "bucket", "delete_remote_after"], actx)
        }
        warnUnknownKeys(t, ["language", "output_dir", "disk_warn_mb", "disk_stop_mb", "google", "aws", "transcribe", "summary"], ctx)
        return p
    }

    // MARK: 値の読み取り

    private static func str(_ key: String, _ table: [String: TOMLValue], _ ctx: String) throws -> String? {
        guard let v = table[key] else { return nil }
        guard let s = v.string else { throw CappyError.usage(tr("\(ctx).\(key) must be a string", ja: "\(ctx).\(key) は文字列である必要があります")) }
        return s
    }

    private static func bool(_ key: String, _ table: [String: TOMLValue], _ ctx: String) throws -> Bool? {
        guard let v = table[key] else { return nil }
        guard let b = v.bool else { throw CappyError.usage(tr("\(ctx).\(key) must be true or false", ja: "\(ctx).\(key) は true / false である必要があります")) }
        return b
    }

    private static func int(_ key: String, _ table: [String: TOMLValue], _ ctx: String) throws -> Int? {
        guard let v = table[key] else { return nil }
        guard let i = v.int else { throw CappyError.usage(tr("\(ctx).\(key) must be an integer", ja: "\(ctx).\(key) は整数である必要があります")) }
        return Int(i)
    }

    private static func warnUnknownKeys(_ table: [String: TOMLValue], _ known: Set<String>, _ ctx: String) {
        for key in table.keys.sorted() where !known.contains(key) {
            CappyLog.shared.warning(tr("Ignoring unknown setting \(ctx).\(key)", ja: "設定 \(ctx).\(key) は不明なキーのため無視します"))
        }
    }

    /// プロファイルを取得する。設定ファイルがない場合の "default" は既定値で返す
    public func profile(named name: String?) throws -> Profile {
        let n = name ?? "default"
        if let p = profiles[n] { return p }
        if n == "default" { return Profile(name: "default") }
        let available = profiles.keys.sorted().joined(separator: ", ")
        throw CappyError.usage(
            tr("Profile \(n) is not in the config file: \(path.path)", ja: "プロファイル \(n) が設定ファイルにありません: \(path.path)"),
            hint: available.isEmpty ? nil : tr("Available profiles: \(available)", ja: "利用可能なプロファイル: \(available)"))
    }
}

extension Profile {
    /// 文字起こしのプロバイダ（表示順）
    public static let providers = ["google", "aws", "none"]
    public static let knownProviders = Set(providers)
    public static var providerList: String { providers.joined(separator: " / ") }
}
