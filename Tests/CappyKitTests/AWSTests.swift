import Foundation
import Testing
@testable import CappyKit

@Suite struct SigV4Tests {
    static let date = Date(timeIntervalSince1970: 1_440_938_160) // 2015-08-30T12:36:00Z
    static let s3Date = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z

    /// IAM ユーザーガイドの署名例（GET ?Action=ListUsers）
    @Test func iamExample() {
        let creds = AWSCredentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
        var req = URLRequest(url: URL(string: "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08")!)
        req.httpMethod = "GET"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        SigV4Signer(credentials: creds, region: "us-east-1", service: "iam").sign(&req, date: Self.date)
        #expect(req.value(forHTTPHeaderField: "X-Amz-Date") == "20150830T123600Z")
        #expect(req.value(forHTTPHeaderField: "Authorization") ==
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, "
            + "SignedHeaders=content-type;host;x-amz-date, "
            + "Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7")
    }

    /// S3 の署名例（GET Object、Range ヘッダー付き）
    @Test func s3HeaderExample() {
        let creds = AWSCredentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        var req = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        req.httpMethod = "GET"
        req.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        SigV4Signer(credentials: creds, region: "us-east-1", service: "s3").sign(&req, date: Self.s3Date)
        #expect(req.value(forHTTPHeaderField: "X-Amz-Content-Sha256") == SigV4Signer.emptyPayloadHash)
        #expect(req.value(forHTTPHeaderField: "Authorization") ==
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
            + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
            + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    /// S3 の署名付き URL の例
    @Test func s3PresignExample() {
        let creds = AWSCredentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        let url = SigV4Signer(credentials: creds, region: "us-east-1", service: "s3")
            .presign(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!, expires: 86400,
                     payloadHash: SigV4Signer.unsignedPayload, date: Self.s3Date)
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedQueryItems!
        func item(_ n: String) -> String? { q.first { $0.name == n }?.value }
        #expect(item("X-Amz-Credential") == "AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request")
        #expect(item("X-Amz-SignedHeaders") == "host")
        #expect(item("X-Amz-Signature") == "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
    }

    @Test func presignIncludesSessionTokenAndPort() {
        let creds = AWSCredentials(accessKeyID: "AK", secretAccessKey: "SK", sessionToken: "tok/en+=")
        let url = SigV4Signer(credentials: creds, region: "ap-northeast-1", service: "transcribe")
            .presign(URL(string: "wss://transcribestreaming.ap-northeast-1.amazonaws.com:8443/stream-transcription-websocket?language-code=ja-JP")!,
                     expires: 300, date: Self.date)
        let s = url.absoluteString
        #expect(s.hasPrefix("wss://transcribestreaming.ap-northeast-1.amazonaws.com:8443/stream-transcription-websocket?language-code=ja-JP&"))
        #expect(s.contains("X-Amz-Security-Token=tok%2Fen%2B%3D"))
        #expect(s.contains("X-Amz-Signature="))
        #expect(SigV4Signer.hostHeader(url) == "transcribestreaming.ap-northeast-1.amazonaws.com:8443")
        #expect(SigV4Signer.hostHeader(URL(string: "https://sts.amazonaws.com:443/")!) == "sts.amazonaws.com")
    }

    @Test func canonicalPathAndQuery() {
        let signer = SigV4Signer(credentials: AWSCredentials(accessKeyID: "a", secretAccessKey: "b"), region: "r", service: "bedrock")
        // S3 以外はエンコード済みのパスをもう一度エンコードする
        #expect(signer.canonicalURI(URL(string: "https://x/model/a%3Ab/invoke")!) == "/model/a%253Ab/invoke")
        var s3 = signer
        s3.service = "s3"
        #expect(s3.canonicalURI(URL(string: "https://x/my%20key")!) == "/my%20key")
        #expect(signer.canonicalURI(URL(string: "https://x")!) == "/")
        #expect(SigV4Signer.canonicalQuery(URL(string: "https://x/?b=2&a=1&a=0&c")!) == "a=0&a=1&b=2&c=")
    }

    @Test func credentialsDescriptionHidesSecrets() {
        let c = AWSCredentials(accessKeyID: "AKIAEXAMPLE", secretAccessKey: "secret-value", sessionToken: "token-value")
        #expect(!c.description.contains("secret-value"))
        #expect(!c.description.contains("token-value"))
        #expect(!c.description.contains("AKIAEXAMPLE"))
    }
}

@Suite struct AWSConfigFileTests {
    @Test func parsesProfilesAndSSOSessions() {
        let text = """
        # comment
        [default]
        region = us-east-1

        [profile dev]
        sso_session = corp
        sso_account_id = 111122223333
        sso_role_name = Admin
        Region = ap-northeast-1
        s3 =
          max_concurrent_requests = 20
        output = json

        [sso-session corp]
        sso_start_url = https://example.awsapps.com/start
        sso_region = ap-northeast-1
        ; another comment
        [services foo]
        x = 1
        [profilex]
        y = 2
        """
        let f = AWSConfigFile.parse(text, kind: .config)
        #expect(f.profiles["default"] == ["region": "us-east-1"])
        #expect(f.profiles["dev"]?["region"] == "ap-northeast-1")
        #expect(f.profiles["dev"]?["output"] == "json")
        #expect(f.profiles["dev"]?["max_concurrent_requests"] == nil)
        #expect(f.profiles["dev"]?["s3"] == "")
        #expect(f.ssoSessions["corp"]?["sso_start_url"] == "https://example.awsapps.com/start")
        #expect(f.profiles.count == 2)
    }

    @Test func credentialsOverrideConfig() throws {
        let dir = try TestSupport.tempDir()
        let config = dir.appendingPathComponent("config")
        let creds = dir.appendingPathComponent("credentials")
        try "[profile a]\nregion = us-west-2\naws_access_key_id = OLD\n".write(to: config, atomically: true, encoding: .utf8)
        try "[a]\naws_access_key_id = NEW\naws_secret_access_key = S\n[b]\naws_access_key_id = B\n".write(to: creds, atomically: true, encoding: .utf8)
        let f = try AWSConfigFile.load(configPath: config.path, credentialsPath: creds.path)
        #expect(f.profiles["a"] == ["region": "us-west-2", "aws_access_key_id": "NEW", "aws_secret_access_key": "S"])
        #expect(f.profiles["b"]?["aws_access_key_id"] == "B")
        let missing = try AWSConfigFile.load(configPath: dir.appendingPathComponent("none").path, credentialsPath: creds.path)
        #expect(missing.profiles.keys.sorted() == ["a", "b"])
    }
}

/// 時刻を進められる時計
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date { lock.withLock { _now } }
    func advance(_ s: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(s) } }
}

/// 外部コマンドのスタブ
final class StubRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    let handler: @Sendable ([String]) -> CommandResult
    init(handler: @escaping @Sendable ([String]) -> CommandResult) { self.handler = handler }
    var calls: [[String]] { lock.withLock { _calls } }
    func run(_ arguments: [String]) async throws -> CommandResult {
        lock.withLock { _calls.append(arguments) }
        return handler(arguments)
    }
}

@Suite struct AWSCredentialsProviderTests {
    static let now = Date(timeIntervalSince1970: 1_794_384_000) // 2026-11-11T08:00:00Z

    static let config = """
    [default]
    region = us-east-1
    aws_access_key_id = DEFAULTKEY
    aws_secret_access_key = DEFAULTSECRET

    [profile dev]
    sso_session = corp
    sso_account_id = 111122223333
    sso_role_name = Admin
    region = ap-northeast-1

    [profile legacy]
    sso_start_url = https://legacy.awsapps.com/start
    sso_region = us-west-2
    sso_account_id = 444455556666
    sso_role_name = ReadOnly

    [profile proc]
    credential_process = /usr/local/bin/get-creds --flag

    [profile assumed]
    role_arn = arn:aws:iam::111122223333:role/x
    source_profile = default

    [profile broken]
    sso_session = nowhere

    [profile empty]
    region = eu-west-1

    [sso-session corp]
    sso_start_url = https://corp.awsapps.com/start
    sso_region = ap-northeast-1
    """

    struct Fixture {
        var home: URL
        var env: AWSEnvironment
        var cacheDir: URL { home.appendingPathComponent(".aws/sso/cache") }
    }

    func fixture(_ vars: [String: String] = [:], name: String = #function) throws -> Fixture {
        let home = try TestSupport.tempDir(name)
        let aws = home.appendingPathComponent(".aws")
        try FileManager.default.createDirectory(at: aws.appendingPathComponent("sso/cache"), withIntermediateDirectories: true)
        try Self.config.write(to: aws.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "[static]\naws_access_key_id = STATICKEY\naws_secret_access_key = STATICSECRET\naws_session_token = STATICTOKEN\n"
            .write(to: aws.appendingPathComponent("credentials"), atomically: true, encoding: .utf8)
        return Fixture(home: home, env: AWSEnvironment(variables: vars, homeDirectory: home.path))
    }

    func writeToken(_ f: Fixture, key: String, expiresAt: Date, refresh: Bool = true) throws -> URL {
        var obj: [String: Any] = [
            "startUrl": "https://corp.awsapps.com/start", "region": "ap-northeast-1",
            "accessToken": "cached-token", "expiresAt": AWSCredentialsProvider.cacheTimestamp(expiresAt),
        ]
        if refresh {
            obj["clientId"] = "client-id"
            obj["clientSecret"] = "client-secret"
            obj["refreshToken"] = "refresh-1"
            obj["registrationExpiresAt"] = AWSCredentialsProvider.cacheTimestamp(expiresAt.addingTimeInterval(86400 * 30))
        }
        let url = f.cacheDir.appendingPathComponent(AWSCredentialsProvider.sha1Hex(key) + ".json")
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        return url
    }

    static func roleResponse(expiresIn: TimeInterval = 3600, from now: Date = now) -> HTTPResponse {
        .json(["roleCredentials": ["accessKeyId": "ASIAROLE", "secretAccessKey": "rolesecret", "sessionToken": "rolesession",
                                   "expiration": (now.timeIntervalSince1970 + expiresIn) * 1000]])
    }

    func resolve(_ f: Fixture, profile: String? = nil, region: String? = nil,
                 transport: HTTPTransport = StubTransport { _ in .json([:], status: 500) },
                 runner: CommandRunner = StubRunner { _ in CommandResult(status: 1, stdout: Data()) },
                 clock: TestClock = TestClock(now)) throws -> AWSCredentialsProvider {
        try AWSCredentialsProvider.resolve(profile: profile, region: region, environment: f.env, transport: transport,
                                           runner: runner, now: { clock.now })
    }

    @Test func profilePrecedence() throws {
        let f = try fixture(["AWS_PROFILE": "dev", "AWS_DEFAULT_PROFILE": "legacy"])
        #expect(try resolve(f).profileName == "dev")
        #expect(try resolve(f, profile: "static").profileName == "static")
        var g = f
        g.env.variables = ["AWS_DEFAULT_PROFILE": "legacy"]
        #expect(try resolve(g).profileName == "legacy")
        g.env.variables = [:]
        let p = try resolve(g)
        #expect(p.profileName == "default")
        #expect(p.source == .staticKeys(AWSCredentials(accessKeyID: "DEFAULTKEY", secretAccessKey: "DEFAULTSECRET")))
    }

    @Test func regionPrecedence() throws {
        var f = try fixture(["AWS_PROFILE": "dev"])
        #expect(try resolve(f).region == "ap-northeast-1")
        #expect(try resolve(f, region: "us-west-2").region == "us-west-2")
        f.env.variables["AWS_DEFAULT_REGION"] = "eu-west-1"
        #expect(try resolve(f).region == "eu-west-1")
        f.env.variables["AWS_REGION"] = "eu-central-1"
        #expect(try resolve(f).region == "eu-central-1")
        #expect(try resolve(f, profile: "proc").region == "eu-central-1")
    }

    @Test func environmentKeysWinUnlessCappyProfileIsSet() async throws {
        let f = try fixture(["AWS_PROFILE": "dev", "AWS_ACCESS_KEY_ID": "ENVKEY", "AWS_SECRET_ACCESS_KEY": "ENVSECRET",
                             "AWS_SESSION_TOKEN": "ENVTOKEN"])
        let p = try resolve(f)
        #expect(p.profileName == nil)
        let c = try await p.credentials()
        #expect(c == AWSCredentials(accessKeyID: "ENVKEY", secretAccessKey: "ENVSECRET", sessionToken: "ENVTOKEN"))
        #expect(p.summary.contains("環境変数"))
        #expect(try resolve(f, profile: "static").profileName == "static")
    }

    @Test func staticKeysFromCredentialsFile() async throws {
        let f = try fixture()
        let c = try await resolve(f, profile: "static").credentials()
        #expect(c == AWSCredentials(accessKeyID: "STATICKEY", secretAccessKey: "STATICSECRET", sessionToken: "STATICTOKEN"))
    }

    @Test func configFileLocationsFromEnvironment() throws {
        var f = try fixture()
        let alt = f.home.appendingPathComponent("alt-config")
        try "[profile only-here]\naws_access_key_id = X\naws_secret_access_key = Y\n".write(to: alt, atomically: true, encoding: .utf8)
        f.env.variables["AWS_CONFIG_FILE"] = alt.path
        f.env.variables["AWS_SHARED_CREDENTIALS_FILE"] = f.home.appendingPathComponent("none").path
        #expect(try resolve(f, profile: "only-here").profileName == "only-here")
        #expect(throws: CappyError.self) { try resolve(f, profile: "static") }
    }

    @Test func missingProfiles() throws {
        let f = try fixture(["AWS_PROFILE": "nope"])
        do {
            _ = try resolve(f)
            Issue.record("エラーになるはず")
        } catch let e as CappyError {
            #expect(e.status == .usage)
            #expect(e.message.contains("nope"))
            #expect(e.message.contains("AWS_PROFILE"))
            #expect(e.hint?.contains("dev") == true)
        }
        #expect(throws: CappyError.self) { try resolve(f, profile: "broken") }
        #expect(throws: CappyError.self) { try resolve(f, profile: "empty") }

        let home = try TestSupport.tempDir()
        do {
            _ = try AWSCredentialsProvider.resolve(profile: nil, region: nil,
                                                   environment: AWSEnvironment(variables: [:], homeDirectory: home.path))
            Issue.record("エラーになるはず")
        } catch let e as CappyError {
            #expect(e.hint?.contains("aws configure sso") == true)
        }
    }

    @Test func ssoSessionWithValidToken() async throws {
        let f = try fixture()
        _ = try writeToken(f, key: "corp", expiresAt: Self.now.addingTimeInterval(3600))
        let transport = StubTransport { _ in Self.roleResponse() }
        let p = try resolve(f, profile: "dev", transport: transport)
        let c = try await p.credentials()
        #expect(c.accessKeyID == "ASIAROLE")
        #expect(c.sessionToken == "rolesession")
        #expect(c.expiration == Self.now.addingTimeInterval(3600))
        #expect(transport.calls.count == 1)
        let call = transport.calls[0]
        #expect(call.method == "GET")
        #expect(call.url == "https://portal.sso.ap-northeast-1.amazonaws.com/federation/credentials?account_id=111122223333&role_name=Admin")
        #expect(call.headers["x-amz-sso_bearer_token"] == "cached-token")
        #expect(p.summary.contains("sso-session corp"))
    }

    @Test func ssoTokenIsRefreshedAndWrittenBack() async throws {
        let f = try fixture()
        let cache = try writeToken(f, key: "corp", expiresAt: Self.now.addingTimeInterval(-60))
        let transport = StubTransport { call in
            if call.url.hasPrefix("https://oidc.") {
                return .json(["accessToken": "new-token", "expiresIn": 28800, "refreshToken": "refresh-2", "tokenType": "Bearer"])
            }
            return Self.roleResponse()
        }
        let p = try resolve(f, profile: "dev", transport: transport)
        _ = try await p.credentials()
        #expect(transport.calls.count == 2)
        let oidc = transport.calls[0]
        #expect(oidc.url == "https://oidc.ap-northeast-1.amazonaws.com/token")
        #expect(oidc.method == "POST")
        let body = try JSONSerialization.jsonObject(with: oidc.body!) as! [String: String]
        #expect(body == ["clientId": "client-id", "clientSecret": "client-secret", "grantType": "refresh_token", "refreshToken": "refresh-1"])
        #expect(transport.calls[1].headers["x-amz-sso_bearer_token"] == "new-token")

        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! [String: Any]
        #expect(saved["accessToken"] as? String == "new-token")
        #expect(saved["refreshToken"] as? String == "refresh-2")
        #expect(saved["expiresAt"] as? String == AWSCredentialsProvider.cacheTimestamp(Self.now.addingTimeInterval(28800)))
        #expect(saved["startUrl"] as? String == "https://corp.awsapps.com/start")
        let perms = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func expiredTokenWithoutRefreshAsksToLogin() async throws {
        let f = try fixture()
        _ = try writeToken(f, key: "corp", expiresAt: Self.now.addingTimeInterval(-60), refresh: false)
        let transport = StubTransport { _ in Self.roleResponse() }
        let p = try resolve(f, profile: "dev", transport: transport)
        await #expect {
            _ = try await p.credentials()
        } throws: { e in
            (e as? CappyError)?.hint?.contains("aws sso login --sso-session corp") == true
        }
        #expect(transport.calls.isEmpty)
    }

    @Test func failedRefreshFallsBackToStillValidToken() async throws {
        let f = try fixture()
        _ = try writeToken(f, key: "corp", expiresAt: Self.now.addingTimeInterval(120))
        let transport = StubTransport { call in
            call.url.hasPrefix("https://oidc.") ? .json(["error": "invalid_grant"], status: 400) : Self.roleResponse()
        }
        let p = try resolve(f, profile: "dev", transport: transport)
        _ = try await p.credentials()
        #expect(transport.calls.last?.headers["x-amz-sso_bearer_token"] == "cached-token")
    }

    @Test func missingSSOCacheAsksToLogin() async throws {
        let f = try fixture()
        let p = try resolve(f, profile: "legacy")
        await #expect {
            _ = try await p.credentials()
        } throws: { e in
            (e as? CappyError)?.hint?.contains("aws sso login --profile legacy") == true
        }
    }

    @Test func legacySSOUsesStartURLCacheKey() async throws {
        let f = try fixture()
        _ = try writeToken(f, key: "https://legacy.awsapps.com/start", expiresAt: Self.now.addingTimeInterval(3600), refresh: false)
        let transport = StubTransport { _ in Self.roleResponse() }
        _ = try await resolve(f, profile: "legacy", transport: transport).credentials()
        #expect(transport.calls.first?.url.hasPrefix("https://portal.sso.us-west-2.amazonaws.com/") == true)
    }

    @Test func unauthorizedRoleCredentials() async throws {
        let f = try fixture()
        _ = try writeToken(f, key: "corp", expiresAt: Self.now.addingTimeInterval(3600))
        let transport = StubTransport { _ in .json(["message": "Session token not found or invalid"], status: 401) }
        let p = try resolve(f, profile: "dev", transport: transport)
        await #expect {
            _ = try await p.credentials()
        } throws: { e in
            (e as? CappyError)?.hint?.contains("aws sso login") == true
        }
    }

    @Test func credentialsAreCachedUntilNearExpiry() async throws {
        let f = try fixture()
        let clock = TestClock(Self.now)
        _ = try writeToken(f, key: "corp", expiresAt: Self.now.addingTimeInterval(8 * 3600))
        let transport = StubTransport { _ in Self.roleResponse(expiresIn: 3600, from: clock.now) }
        let p = try resolve(f, profile: "dev", transport: transport, clock: clock)
        _ = try await p.credentials()
        clock.advance(3600 - AWSCredentialsProvider.refreshMargin - 10)
        _ = try await p.credentials()
        #expect(transport.calls.count == 1)
        clock.advance(20)
        _ = try await p.credentials()
        #expect(transport.calls.count == 2)
    }

    @Test func credentialProcess() async throws {
        let f = try fixture()
        let runner = StubRunner { _ in
            CommandResult(status: 0, stdout: Data("""
            {"Version": 1, "AccessKeyId": "PROCKEY", "SecretAccessKey": "PROCSECRET", "SessionToken": "PROCTOKEN",
             "Expiration": "2026-11-11T09:00:00Z"}
            """.utf8))
        }
        let c = try await resolve(f, profile: "proc", runner: runner).credentials()
        #expect(runner.calls == [["/bin/sh", "-c", "/usr/local/bin/get-creds --flag"]])
        #expect(c.accessKeyID == "PROCKEY")
        #expect(c.expiration == Self.now.addingTimeInterval(3600))

        let failing = StubRunner { _ in CommandResult(status: 2, stdout: Data(), stderr: Data("boom\n".utf8)) }
        await #expect {
            _ = try await resolve(f, profile: "proc", runner: failing).credentials()
        } throws: { e in
            (e as? CappyError)?.message.contains("boom") == true
        }
        let bad = StubRunner { _ in CommandResult(status: 0, stdout: Data(#"{"Version": 2, "AccessKeyId": "a", "SecretAccessKey": "b"}"#.utf8)) }
        await #expect(throws: CappyError.self) { _ = try await resolve(f, profile: "proc", runner: bad).credentials() }
    }

    @Test func otherProfileTypesUseAWSCLI() async throws {
        let f = try fixture()
        let runner = StubRunner { _ in
            CommandResult(status: 0, stdout: Data(#"{"Version": 1, "AccessKeyId": "CLIKEY", "SecretAccessKey": "CLISECRET"}"#.utf8))
        }
        let p = try resolve(f, profile: "assumed", runner: runner)
        #expect(p.source == .awsCLI(reason: "role_arn"))
        let c = try await p.credentials()
        #expect(c.accessKeyID == "CLIKEY")
        #expect(runner.calls == [["/usr/bin/env", "aws", "configure", "export-credentials", "--profile", "assumed", "--format", "process"]])

        let missing = StubRunner { _ in CommandResult(status: 127, stdout: Data()) }
        await #expect {
            _ = try await resolve(f, profile: "assumed", runner: missing).credentials()
        } throws: { e in
            (e as? CappyError)?.status == .usage
        }
    }
}

@Suite struct AWSAPITests {
    @Test func getCallerIdentity() async throws {
        let xml = """
        <GetCallerIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
          <GetCallerIdentityResult>
            <Arn>arn:aws:sts::111122223333:assumed-role/Admin/user</Arn>
            <UserId>AROAEXAMPLE:user</UserId>
            <Account>111122223333</Account>
          </GetCallerIdentityResult>
          <ResponseMetadata><RequestId>abc</RequestId></ResponseMetadata>
        </GetCallerIdentityResponse>
        """
        let transport = StubTransport { _ in HTTPResponse(status: 200, body: Data(xml.utf8)) }
        let creds = StaticAWSCredentials(AWSCredentials(accessKeyID: "AK", secretAccessKey: "SK", sessionToken: "ST"))
        let id = try await STSClient(credentials: creds, region: "ap-northeast-1", transport: transport).getCallerIdentity()
        #expect(id == STSClient.Identity(account: "111122223333", arn: "arn:aws:sts::111122223333:assumed-role/Admin/user",
                                         userID: "AROAEXAMPLE:user"))
        let call = transport.calls[0]
        #expect(call.url == "https://sts.ap-northeast-1.amazonaws.com/")
        #expect(call.method == "POST")
        #expect(String(decoding: call.body!, as: UTF8.self) == "Action=GetCallerIdentity&Version=2011-06-15")
        #expect(call.headers["Authorization"]?.contains("/ap-northeast-1/sts/aws4_request") == true)
        #expect(call.headers["X-Amz-Security-Token"] == "ST")
    }

    @Test func errorParsing() {
        let xml = """
        <ErrorResponse><Error><Type>Sender</Type><Code>ExpiredToken</Code><Message>The security token included in the request is expired</Message></Error></ErrorResponse>
        """
        let x = AWSAPIError.from(HTTPResponse(status: 403, body: Data(xml.utf8)))
        #expect(x.code == "ExpiredToken")
        #expect(x.message.contains("expired"))
        #expect(!x.isTransient)

        let j = AWSAPIError.from(.json(["__type": "com.amazon.coral.service#ThrottlingException", "message": "slow down"], status: 400))
        #expect(j.code == "ThrottlingException")
        #expect(j.isTransient)

        let h = AWSAPIError.from(HTTPResponse(status: 403, body: Data(#"{"Message": "denied"}"#.utf8),
                                              headers: ["x-amzn-errortype": "AccessDeniedException:http://internal"]))
        #expect(h.code == "AccessDeniedException")
        #expect(h.message == "denied")
        #expect(AWSAPIError.from(HTTPResponse(status: 503, body: Data("oops".utf8))).isTransient)
    }

    @Test func configAWSSection() throws {
        let c = try CappyConfig.parse("""
        [profiles.a.aws]
        profile = "teraoka-app-admin"
        region = "ap-northeast-1"
        [profiles.b]
        provider = "none"
        """, path: URL(fileURLWithPath: "/tmp/x.toml"))
        #expect(c.profiles["a"]?.aws == AWSSettings(profile: "teraoka-app-admin", region: "ap-northeast-1"))
        #expect(c.profiles["b"]?.aws == nil)
        #expect(throws: CappyError.self) {
            try CappyConfig.parse("[profiles.a.aws]\nprofile = 1\n", path: URL(fileURLWithPath: "/tmp/x.toml"))
        }
    }
}

/// 固定の AWS 認証情報
struct StaticAWSCredentials: AWSCredentialsSource {
    let value: AWSCredentials
    init(_ value: AWSCredentials) { self.value = value }
    func credentials() async throws -> AWSCredentials { value }
    var summary: String { "static" }
}
