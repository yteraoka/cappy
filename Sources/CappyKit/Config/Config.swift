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

    public init(name: String) { self.name = name }

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
        let known: Set<String> = ["provider", "language", "output_dir", "disk_warn_mb", "disk_stop_mb", "google"]
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
