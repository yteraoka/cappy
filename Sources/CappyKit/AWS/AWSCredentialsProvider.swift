import CryptoKit
import Foundation

/// AWS の認証情報の取得元
public protocol AWSCredentialsSource: Sendable {
    func credentials() async throws -> AWSCredentials
    var summary: String { get async }
}

/// 認証情報の解決に使う環境（テストでは差し替える）
public struct AWSEnvironment: Sendable {
    public var variables: [String: String]
    public var homeDirectory: String

    public init(variables: [String: String], homeDirectory: String) {
        self.variables = variables
        self.homeDirectory = homeDirectory
    }

    public static var current: AWSEnvironment {
        AWSEnvironment(variables: ProcessInfo.processInfo.environment, homeDirectory: NSHomeDirectory())
    }

    /// 空文字は未設定として扱う
    public func value(_ name: String) -> String? {
        guard let v = variables[name], !v.isEmpty else { return nil }
        return v
    }

    func expand(_ path: String) -> String {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") { return (homeDirectory as NSString).appendingPathComponent(String(path.dropFirst(2))) }
        return path
    }

    public var configPath: String {
        value("AWS_CONFIG_FILE").map(expand) ?? (homeDirectory as NSString).appendingPathComponent(".aws/config")
    }

    public var credentialsPath: String {
        value("AWS_SHARED_CREDENTIALS_FILE").map(expand) ?? (homeDirectory as NSString).appendingPathComponent(".aws/credentials")
    }

    /// `aws sso login` がトークンを書き込む場所
    public var ssoCacheDirectory: String {
        (homeDirectory as NSString).appendingPathComponent(".aws/sso/cache")
    }
}

/// 外部コマンドの実行（credential_process / aws configure export-credentials 用。テストでは差し替える）
public protocol CommandRunner: Sendable {
    func run(_ arguments: [String]) async throws -> CommandResult
}

public struct CommandResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(_ arguments: [String]) async throws -> CommandResult {
        precondition(!arguments.isEmpty)
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: arguments[0])
                p.arguments = Array(arguments.dropFirst())
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do {
                    try p.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                // 標準エラーは別スレッドで読む（片方のパイプが詰まって止まらないように）
                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: CommandResult(status: p.terminationStatus, stdout: outData, stderr: errBox.data))
            }
        }
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }
}

/// AWS の認証情報を、SDK と同じ考え方で探して取得する。
///
/// - プロファイル: cappy の設定 → AWS_PROFILE → AWS_DEFAULT_PROFILE → default
/// - cappy の設定でプロファイルを指定していなければ、環境変数のアクセスキー（AWS_ACCESS_KEY_ID など）を優先する
/// - プロファイルの種類: sso_session（トークンの更新つき）/ 旧形式の SSO / アクセスキー / credential_process。
///   role_arn・web_identity_token_file・login_session などは `aws configure export-credentials` に任せる
/// - 一時的な認証情報は期限の 5 分前に取り直す
public actor AWSCredentialsProvider: AWSCredentialsSource {
    public static let refreshMargin: TimeInterval = 5 * 60

    public struct SSOConfig: Sendable, Equatable {
        /// [sso-session] の名前（旧形式の SSO なら nil）
        public var session: String?
        public var startURL: String
        public var ssoRegion: String
        public var accountID: String
        public var roleName: String

        /// トークンのキャッシュのファイル名に使う値
        var cacheKey: String { session ?? startURL }
    }

    public enum Source: Sendable, Equatable {
        case environment(AWSCredentials)
        case staticKeys(AWSCredentials)
        case sso(SSOConfig)
        case process(command: String)
        /// `aws configure export-credentials` に任せる（理由になったキー）
        case awsCLI(reason: String)
    }

    public nonisolated let source: Source
    /// 使うプロファイル（環境変数のアクセスキーなら nil）
    public nonisolated let profileName: String?
    /// cappy の設定 → AWS_REGION → AWS_DEFAULT_REGION → プロファイルの region
    public nonisolated let region: String?
    let environment: AWSEnvironment
    let transport: HTTPTransport
    let runner: CommandRunner
    let now: @Sendable () -> Date
    private var cached: AWSCredentials?

    init(source: Source, profileName: String?, region: String?, environment: AWSEnvironment,
         transport: HTTPTransport, runner: CommandRunner, now: @escaping @Sendable () -> Date) {
        self.source = source
        self.profileName = profileName
        self.region = region
        self.environment = environment
        self.transport = transport
        self.runner = runner
        self.now = now
    }

    public nonisolated var summary: String {
        let p = profileName.map { "profile \($0)" } ?? ""
        switch source {
        case .environment:
            return "環境変数のアクセスキー（AWS_ACCESS_KEY_ID）"
        case .staticKeys:
            return "アクセスキー（\(p)）"
        case .sso(let s):
            let origin = s.session.map { "sso-session \($0)" } ?? "sso_start_url"
            return "SSO（\(origin)、\(p)、アカウント \(s.accountID) / ロール \(s.roleName)）"
        case .process:
            return "credential_process（\(p)）"
        case .awsCLI(let reason):
            return "aws configure export-credentials（\(p)、\(reason)）"
        }
    }

    // MARK: 解決

    public static func resolve(profile explicitProfile: String?, region explicitRegion: String?,
                               environment env: AWSEnvironment = .current,
                               transport: HTTPTransport = URLSessionTransport(),
                               runner: CommandRunner = ProcessCommandRunner(),
                               now: @escaping @Sendable () -> Date = { Date() }) throws -> AWSCredentialsProvider {
        let explicitProfile = explicitProfile.flatMap { $0.isEmpty ? nil : $0 }
        let envProfile = env.value("AWS_PROFILE") ?? env.value("AWS_DEFAULT_PROFILE")
        let name = explicitProfile ?? envProfile ?? "default"
        let files = try AWSConfigFile.load(configPath: env.configPath, credentialsPath: env.credentialsPath)
        let values = files.profiles[name]
        let region = explicitRegion.flatMap { $0.isEmpty ? nil : $0 }
            ?? env.value("AWS_REGION") ?? env.value("AWS_DEFAULT_REGION") ?? values?["region"].flatMap { $0.isEmpty ? nil : $0 }

        if explicitProfile == nil, let id = env.value("AWS_ACCESS_KEY_ID"), let secret = env.value("AWS_SECRET_ACCESS_KEY") {
            let creds = AWSCredentials(accessKeyID: id, secretAccessKey: secret, sessionToken: env.value("AWS_SESSION_TOKEN"))
            return AWSCredentialsProvider(source: .environment(creds), profileName: nil, region: region, environment: env,
                                          transport: transport, runner: runner, now: now)
        }
        guard let values else {
            if explicitProfile == nil && envProfile == nil {
                throw CappyError.usage(
                    "AWS の認証情報が見つかりません（\(env.configPath) に default プロファイルがなく、AWS_PROFILE も未設定です）",
                    hint: "`aws configure sso` でプロファイルを作り、AWS_PROFILE か [profiles.<name>.aws] の profile で指定してください")
            }
            let available = files.profiles.keys.sorted().joined(separator: ", ")
            let origin = explicitProfile != nil ? "cappy の設定" : "AWS_PROFILE"
            throw CappyError.usage(
                "AWS のプロファイル \(name)（\(origin)）が \(env.configPath) にも \(env.credentialsPath) にもありません",
                hint: available.isEmpty ? nil : "利用可能なプロファイル: \(available)")
        }
        let source = try source(profile: name, values: values, files: files, configPath: env.configPath)
        return AWSCredentialsProvider(source: source, profileName: name, region: region, environment: env,
                                      transport: transport, runner: runner, now: now)
    }

    /// botocore と同じ順で、プロファイルの種類を決める
    static func source(profile: String, values: [String: String], files: AWSConfigFile, configPath: String) throws -> Source {
        func v(_ key: String, _ table: [String: String] = values) -> String? {
            guard let s = table[key], !s.isEmpty else { return nil }
            return s
        }
        if v("role_arn") != nil { return .awsCLI(reason: "role_arn") }
        if v("web_identity_token_file") != nil { return .awsCLI(reason: "web_identity_token_file") }
        if let session = v("sso_session") {
            guard let s = files.ssoSessions[session] else {
                throw CappyError.usage("プロファイル \(profile) の sso_session \(session) に対応する [sso-session \(session)] が \(configPath) にありません")
            }
            guard let start = v("sso_start_url", s), let ssoRegion = v("sso_region", s) else {
                throw CappyError.usage("[sso-session \(session)] に sso_start_url と sso_region が必要です（\(configPath)）")
            }
            guard let account = v("sso_account_id"), let role = v("sso_role_name") else {
                throw CappyError.usage("プロファイル \(profile) に sso_account_id と sso_role_name が必要です（\(configPath)）")
            }
            return .sso(SSOConfig(session: session, startURL: start, ssoRegion: ssoRegion, accountID: account, roleName: role))
        }
        if let start = v("sso_start_url") {
            guard let ssoRegion = v("sso_region"), let account = v("sso_account_id"), let role = v("sso_role_name") else {
                throw CappyError.usage("プロファイル \(profile) に sso_region・sso_account_id・sso_role_name が必要です（\(configPath)）")
            }
            return .sso(SSOConfig(session: nil, startURL: start, ssoRegion: ssoRegion, accountID: account, roleName: role))
        }
        if let id = v("aws_access_key_id"), let secret = v("aws_secret_access_key") {
            return .staticKeys(AWSCredentials(accessKeyID: id, secretAccessKey: secret, sessionToken: v("aws_session_token")))
        }
        if let command = v("credential_process") { return .process(command: command) }
        for key in ["login_session", "credential_source"] where v(key) != nil {
            return .awsCLI(reason: key)
        }
        throw CappyError.usage("プロファイル \(profile) に認証情報の設定がありません（\(configPath)）",
                               hint: "sso_session、aws_access_key_id、credential_process のいずれかを設定してください")
    }

    // MARK: 取得

    public func credentials() async throws -> AWSCredentials {
        if let c = cached, isFresh(c) { return c }
        let c = try await fetch()
        cached = c
        return c
    }

    func isFresh(_ c: AWSCredentials) -> Bool {
        guard let exp = c.expiration else { return true }
        return exp.timeIntervalSince(now()) > Self.refreshMargin
    }

    private func fetch() async throws -> AWSCredentials {
        switch source {
        case .environment(let c), .staticKeys(let c):
            return c
        case .sso(let s):
            let token = try await ssoAccessToken(s)
            return try await roleCredentials(s, token: token)
        case .process(let command):
            let r = try await runner.run(["/bin/sh", "-c", command])
            guard r.status == 0 else {
                throw CappyError.transcription("credential_process が失敗しました（終了コード \(r.status)、profile \(profileName ?? "-")）: \(Self.stderrText(r))")
            }
            return try Self.parseProcessOutput(r.stdout, what: "credential_process")
        case .awsCLI(let reason):
            let profile = profileName ?? "default"
            let r = try await runner.run(["/usr/bin/env", "aws", "configure", "export-credentials",
                                          "--profile", profile, "--format", "process"])
            if r.status == 127 {
                throw CappyError.usage(
                    "プロファイル \(profile) は \(reason) を使うため AWS CLI が必要ですが、aws コマンドが見つかりません",
                    hint: "AWS CLI v2 を入れるか、sso_session・アクセスキー・credential_process のプロファイルを使ってください")
            }
            guard r.status == 0 else {
                throw CappyError.transcription("`aws configure export-credentials --profile \(profile)` が失敗しました（終了コード \(r.status)）: \(Self.stderrText(r))")
            }
            return try Self.parseProcessOutput(r.stdout, what: "aws configure export-credentials")
        }
    }

    static func stderrText(_ r: CommandResult) -> String {
        let s = String(decoding: r.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "（出力なし）" : String(s.prefix(500))
    }

    /// credential_process の出力（Version 1 の JSON）
    static func parseProcessOutput(_ data: Data, what: String) throws -> AWSCredentials {
        struct Output: Decodable {
            var Version: Int
            var AccessKeyId: String
            var SecretAccessKey: String
            var SessionToken: String?
            var Expiration: String?
        }
        guard let o = try? JSONDecoder().decode(Output.self, from: data) else {
            throw CappyError.transcription("\(what) の出力を解釈できません（Version・AccessKeyId・SecretAccessKey を含む JSON が必要です）")
        }
        guard o.Version == 1 else {
            throw CappyError.transcription("\(what) の出力の Version が未対応です: \(o.Version)")
        }
        var expiration: Date?
        if let e = o.Expiration {
            guard let d = TimeFormat.parseISO8601(e) else {
                throw CappyError.transcription("\(what) の出力の Expiration を解釈できません: \(e)")
            }
            expiration = d
        }
        return AWSCredentials(accessKeyID: o.AccessKeyId, secretAccessKey: o.SecretAccessKey,
                              sessionToken: o.SessionToken?.isEmpty == false ? o.SessionToken : nil, expiration: expiration)
    }

    // MARK: SSO

    static func sha1Hex(_ s: String) -> String {
        Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func ssoCachePath(_ s: SSOConfig) -> String {
        (environment.ssoCacheDirectory as NSString).appendingPathComponent(Self.sha1Hex(s.cacheKey) + ".json")
    }

    func loginCommand(_ s: SSOConfig) -> String {
        s.session.map { "aws sso login --sso-session \($0)" } ?? "aws sso login --profile \(profileName ?? "default")"
    }

    /// `aws sso login` が保存したアクセストークン。期限が近ければ（sso_session なら）リフレッシュトークンで更新し、キャッシュに書き戻す
    func ssoAccessToken(_ s: SSOConfig) async throws -> String {
        let path = ssoCachePath(s)
        let login = loginCommand(s)
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["accessToken"] as? String,
              let expiresAt = (obj["expiresAt"] as? String).flatMap(TimeFormat.parseISO8601) else {
            throw CappyError.transcription("SSO のログイン情報がありません（\(path)）", hint: "`\(login)` を実行してください")
        }
        let remaining = expiresAt.timeIntervalSince(now())
        if remaining > Self.refreshMargin { return token }
        if s.session != nil {
            do {
                return try await refreshSSOToken(obj, path: path, sso: s)
            } catch {
                CappyLog.shared.warning("SSO のトークンを更新できませんでした: \((error as? CappyError)?.message ?? "\(error)")")
            }
        }
        if remaining > 0 { return token }
        throw CappyError.transcription("SSO のログインの期限が切れています（\(s.session.map { "sso-session \($0)" } ?? s.startURL)）",
                                       hint: "`\(login)` を実行してください")
    }

    /// SSO OIDC の CreateToken（grant_type=refresh_token）
    func refreshSSOToken(_ cache: [String: Any], path: String, sso s: SSOConfig) async throws -> String {
        guard let clientID = cache["clientId"] as? String, let clientSecret = cache["clientSecret"] as? String,
              let refreshToken = cache["refreshToken"] as? String else {
            throw CappyError.transcription("キャッシュにリフレッシュトークンがありません")
        }
        if let reg = (cache["registrationExpiresAt"] as? String).flatMap(TimeFormat.parseISO8601), reg <= now() {
            throw CappyError.transcription("SSO のクライアント登録の期限が切れています")
        }
        var req = URLRequest(url: URL(string: "https://oidc.\(s.ssoRegion).amazonaws.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "clientId": clientID, "clientSecret": clientSecret, "grantType": "refresh_token", "refreshToken": refreshToken,
        ])
        let request = req
        let resp = try await RetryPolicy().run("SSO トークンの更新") { [transport] in
            let r = try await transport.send(request)
            if r.status != 200 { throw AWSAPIError.from(r) }
            return r
        }
        struct R: Decodable { var accessToken: String; var expiresIn: Double; var refreshToken: String? }
        guard let r = try? JSONDecoder().decode(R.self, from: resp.body) else {
            throw CappyError.transcription("SSO トークンの更新の応答を解釈できません")
        }
        var updated = cache
        updated["accessToken"] = r.accessToken
        updated["expiresAt"] = Self.cacheTimestamp(now().addingTimeInterval(r.expiresIn))
        if let rt = r.refreshToken { updated["refreshToken"] = rt }
        do {
            let data = try JSONSerialization.data(withJSONObject: updated, options: [.withoutEscapingSlashes])
            try FileSecurity.writeAtomically(data, to: URL(fileURLWithPath: path))
        } catch {
            // 書き戻せなくても、今回は更新したトークンを使える
            CappyLog.shared.warning("SSO のトークンのキャッシュを書き込めません: \(path)")
        }
        CappyLog.shared.info("SSO のトークンを更新しました（\(s.session ?? s.startURL)）")
        return r.accessToken
    }

    /// AWS CLI と同じ形式（秒まで・UTC）
    static func cacheTimestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// SSO の GetRoleCredentials
    func roleCredentials(_ s: SSOConfig, token: String) async throws -> AWSCredentials {
        var comps = URLComponents(string: "https://portal.sso.\(s.ssoRegion).amazonaws.com/federation/credentials")!
        comps.queryItems = [URLQueryItem(name: "account_id", value: s.accountID), URLQueryItem(name: "role_name", value: s.roleName)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue(token, forHTTPHeaderField: "x-amz-sso_bearer_token")
        let request = req
        let resp: HTTPResponse
        do {
            resp = try await RetryPolicy().run("SSO の認証情報の取得") { [transport] in
                let r = try await transport.send(request)
                if r.status != 200 { throw AWSAPIError.from(r) }
                return r
            }
        } catch let e as AWSAPIError where e.httpStatus == 401 {
            throw CappyError.transcription("SSO のログインが無効です: \(e)", hint: "`\(loginCommand(s))` を実行してください")
        } catch let e as AWSAPIError where e.httpStatus == 403 {
            throw CappyError.transcription("SSO でアカウント \(s.accountID) のロール \(s.roleName) を使えません: \(e)",
                                           hint: "sso_account_id と sso_role_name、IAM Identity Center の割り当てを確認してください")
        } catch let e as AWSAPIError {
            throw CappyError.transcription("SSO の認証情報を取得できません: \(e)")
        }
        struct R: Decodable {
            struct C: Decodable {
                var accessKeyId: String
                var secretAccessKey: String
                var sessionToken: String?
                /// エポックからのミリ秒
                var expiration: Double
            }
            var roleCredentials: C
        }
        guard let r = try? JSONDecoder().decode(R.self, from: resp.body) else {
            throw CappyError.transcription("SSO の認証情報の応答を解釈できません")
        }
        let c = r.roleCredentials
        return AWSCredentials(accessKeyID: c.accessKeyId, secretAccessKey: c.secretAccessKey, sessionToken: c.sessionToken,
                              expiration: Date(timeIntervalSince1970: c.expiration / 1000))
    }
}
