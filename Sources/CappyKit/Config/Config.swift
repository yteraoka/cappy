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

/// 会議の要約（Vertex AI の Claude / Gemini）
public struct SummarySettings: Sendable, Equatable {
    /// vertex / none。nil ならプロファイルの provider から決める（none なら none、それ以外は vertex）
    public var provider: String?
    /// 既定は google.project_id
    public var projectID: String?
    /// global / us / eu / リージョン名
    public var region: String = "global"
    /// claude- で始まれば Claude、gemini- で始まれば Gemini を使う
    public var model: String = "gemini-4-argon"
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

    public static let knownProviders: Set<String> = ["vertex", "none"]

    /// 実際に使う再試行先。model が設定の model と違う（--model で上書きした）場合は系統の既定を使う
    public func effectiveFallback(for model: String) -> String? {
        if model == self.model, let f = fallbackModel { return f.isEmpty ? nil : f }
        return SummaryModelFamily.of(model)?.defaultFallback
    }
    public static let knownEfforts: Set<String> = ["low", "medium", "high", "xhigh", "max"]
}

public struct Profile: Sendable, Equatable {
    public var name: String
    public var provider: String = "google"
    public var language: String = "ja-JP"
    public var outputDir: String = "~/Recordings/cappy"
    /// 空き容量がこれを下回ったら警告（MB）
    public var diskWarnMB: Int = 1024
    /// 空き容量がこれを下回ったら録音を停止（MB）
    public var diskStopMB: Int = 300
    public var google = GoogleSettings()
    public var summary = SummarySettings()

    public init(name: String) { self.name = name }

    /// 実際に使う要約プロバイダ
    public var summaryProvider: String {
        if let p = summary.provider { return p }
        return provider == "none" ? "none" : "vertex"
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
            throw CappyError.usage("設定ファイルを読めません: \(url.path): \(error.localizedDescription)")
        }
        return try parse(text, path: url)
    }

    public static func parse(_ text: String, path: URL) throws -> CappyConfig {
        let doc: [String: TOMLValue]
        do {
            doc = try TOML.parse(text)
        } catch {
            throw CappyError.usage("設定ファイルの書式が不正です: \(path.path): \(error)")
        }
        var profiles: [String: Profile] = [:]
        for (name, value) in doc["profiles"]?.table ?? [:] {
            guard let t = value.table else {
                throw CappyError.usage("profiles.\(name) はテーブルである必要があります")
            }
            profiles[name] = try parseProfile(name: name, t)
        }
        return CappyConfig(profiles: profiles, path: path, fileExists: true)
    }

    private static func parseProfile(name: String, _ t: [String: TOMLValue]) throws -> Profile {
        var p = Profile(name: name)
        func str(_ key: String, _ table: [String: TOMLValue], _ ctx: String) throws -> String? {
            guard let v = table[key] else { return nil }
            guard let s = v.string else { throw CappyError.usage("\(ctx).\(key) は文字列である必要があります") }
            return s
        }
        func bool(_ key: String, _ table: [String: TOMLValue], _ ctx: String) throws -> Bool? {
            guard let v = table[key] else { return nil }
            guard let b = v.bool else { throw CappyError.usage("\(ctx).\(key) は true / false である必要があります") }
            return b
        }
        func int(_ key: String, _ table: [String: TOMLValue], _ ctx: String) throws -> Int? {
            guard let v = table[key] else { return nil }
            guard let i = v.int else { throw CappyError.usage("\(ctx).\(key) は整数である必要があります") }
            return Int(i)
        }
        let ctx = "profiles.\(name)"
        if let v = try str("provider", t, ctx) { p.provider = v }
        if let v = try str("language", t, ctx) { p.language = v }
        if let v = try str("output_dir", t, ctx) { p.outputDir = v }
        if let v = try int("disk_warn_mb", t, ctx) { p.diskWarnMB = v }
        if let v = try int("disk_stop_mb", t, ctx) { p.diskStopMB = v }
        if let g = t["google"]?.table {
            let gctx = ctx + ".google"
            p.google.projectID = try str("project_id", g, gctx)
            if let v = try str("location", g, gctx) { p.google.location = v }
            p.google.bucket = try str("bucket", g, gctx)
            if let v = try str("model", g, gctx) { p.google.model = v }
            if let v = try bool("delete_remote_after", g, gctx) { p.google.deleteRemoteAfter = v }
            if let v = try bool("word_timestamps", g, gctx) { p.google.wordTimestamps = v }
            if let v = try bool("diarization", g, gctx) { p.google.diarization = v }
            p.google.chunkMinutes = try int("chunk_minutes", g, gctx)
            p.google.minSpeakers = try int("min_speakers", g, gctx)
            p.google.maxSpeakers = try int("max_speakers", g, gctx)
        }
        if let m = t["summary"]?.table {
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
                throw CappyError.usage("\(sctx).provider が不正です: \(v)（vertex / none）")
            }
            if !SummarySettings.knownEfforts.contains(p.summary.effort) {
                throw CappyError.usage("\(sctx).effort が不正です: \(p.summary.effort)（low / medium / high / xhigh / max）")
            }
            for (key, value) in [("model", p.summary.model), ("fallback_model", p.summary.fallbackModel ?? "")]
            where !value.isEmpty && SummaryModelFamily.of(value) == nil {
                throw CappyError.usage("\(sctx).\(key) が不正です: \(value)（claude- または gemini- で始まるモデル ID）")
            }
            if p.summary.maxTokens < 1024 {
                throw CappyError.usage("\(sctx).max_tokens は 1024 以上にしてください")
            }
            let knownSummary: Set<String> = ["provider", "project_id", "region", "model", "fallback_model", "effort",
                                             "max_tokens", "auto", "instructions_file"]
            for key in m.keys where !knownSummary.contains(key) {
                CappyLog.shared.warning("設定 \(sctx).\(key) は不明なキーのため無視します")
            }
        }
        let known: Set<String> = ["provider", "language", "output_dir", "disk_warn_mb", "disk_stop_mb", "google", "summary"]
        for key in t.keys where !known.contains(key) {
            CappyLog.shared.warning("設定 \(ctx).\(key) は不明なキーのため無視します")
        }
        if !Profile.knownProviders.contains(p.provider) {
            throw CappyError.usage("\(ctx).provider が不正です: \(p.provider)（google / none）")
        }
        return p
    }

    /// プロファイルを取得する。設定ファイルがない場合の "default" は既定値で返す
    public func profile(named name: String?) throws -> Profile {
        let n = name ?? "default"
        if let p = profiles[n] { return p }
        if n == "default" { return Profile(name: "default") }
        let available = profiles.keys.sorted().joined(separator: ", ")
        throw CappyError.usage(
            "プロファイル \(n) が設定ファイルにありません: \(path.path)",
            hint: available.isEmpty ? nil : "利用可能なプロファイル: \(available)")
    }
}

extension Profile {
    public static let knownProviders: Set<String> = ["google", "none"]
}
