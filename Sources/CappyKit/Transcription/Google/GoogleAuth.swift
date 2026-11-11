import Foundation
import Security

/// アクセストークンの取得元
public protocol AccessTokenProvider: Sendable {
    func accessToken() async throws -> String
    /// ユーザー認証情報の場合に x-goog-user-project に付けるプロジェクト
    var quotaProjectID: String? { get async }
    var summary: String { get async }
}

/// Google のアプリケーションデフォルト認証情報（ADC）。
/// `gcloud auth application-default login`（authorized_user）、サービスアカウント鍵、
/// サービスアカウントの借用（impersonated_service_account）に対応する。
public actor ApplicationDefaultCredentials: AccessTokenProvider {
    public static let scope = "https://www.googleapis.com/auth/cloud-platform"

    indirect enum Kind: @unchecked Sendable {
        case authorizedUser(clientID: String, clientSecret: String, refreshToken: String, tokenURI: String)
        case serviceAccount(email: String, privateKey: SecKey, keyID: String?, tokenURI: String)
        case impersonated(source: Kind, url: String)
    }

    let kind: Kind
    let path: String
    let quotaProject: String?
    let transport: HTTPTransport
    private var cached: (token: String, expiry: Date)?

    public var quotaProjectID: String? { quotaProject }

    public var summary: String {
        switch kind {
        case .authorizedUser: return tr("authorized_user (\(path))", ja: "authorized_user（\(path)）")
        case .serviceAccount(let email, _, _, _): return tr("service_account \(email) (\(path))", ja: "service_account \(email)（\(path)）")
        case .impersonated(_, let url):
            let email = Self.impersonatedEmail(url) ?? ""
            return tr("impersonated_service_account \(email) (\(path))", ja: "impersonated_service_account \(email)（\(path)）")
        }
    }

    public static func defaultPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let p = env["GOOGLE_APPLICATION_CREDENTIALS"], !p.isEmpty { return FileSecurity.expandTilde(p) }
        let base = env["CLOUDSDK_CONFIG"].map(FileSecurity.expandTilde) ?? FileSecurity.expandTilde("~/.config/gcloud")
        return (base as NSString).appendingPathComponent("application_default_credentials.json")
    }

    public static func load(path: String = defaultPath(), transport: HTTPTransport = URLSessionTransport()) throws -> ApplicationDefaultCredentials {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CappyError.transcription(tr("Google Application Default Credentials not found: \(path)", ja: "Google のアプリケーションデフォルト認証情報が見つかりません: \(path)"),
                                           hint: tr("Run `gcloud auth application-default login` or set GOOGLE_APPLICATION_CREDENTIALS", ja: "`gcloud auth application-default login` を実行するか、GOOGLE_APPLICATION_CREDENTIALS を設定してください"))
        }
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) } catch {
            throw CappyError.transcription(tr("Cannot read the credentials: \(path): \(error.localizedDescription)", ja: "認証情報を読めません: \(path): \(error.localizedDescription)"))
        }
        return try parse(data, path: path, transport: transport)
    }

    public static func parse(_ data: Data, path: String, transport: HTTPTransport) throws -> ApplicationDefaultCredentials {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CappyError.transcription(tr("Invalid credentials JSON: \(path)", ja: "認証情報の JSON が不正です: \(path)"))
        }
        let kind = try parseKind(obj, path: path)
        return ApplicationDefaultCredentials(kind: kind, path: path, quotaProject: obj["quota_project_id"] as? String, transport: transport)
    }

    static func parseKind(_ obj: [String: Any], path: String) throws -> Kind {
        let type = obj["type"] as? String ?? ""
        switch type {
        case "authorized_user":
            guard let id = obj["client_id"] as? String, let secret = obj["client_secret"] as? String,
                  let refresh = obj["refresh_token"] as? String else {
                throw CappyError.transcription(tr("authorized_user credentials are missing required fields: \(path)", ja: "authorized_user の認証情報に必要な項目がありません: \(path)"))
            }
            return .authorizedUser(clientID: id, clientSecret: secret, refreshToken: refresh,
                                   tokenURI: obj["token_uri"] as? String ?? "https://oauth2.googleapis.com/token")
        case "service_account":
            guard let email = obj["client_email"] as? String, let pem = obj["private_key"] as? String else {
                throw CappyError.transcription(tr("service_account credentials are missing required fields: \(path)", ja: "service_account の認証情報に必要な項目がありません: \(path)"))
            }
            let key = try RSAKey.privateKey(fromPEM: pem)
            return .serviceAccount(email: email, privateKey: key, keyID: obj["private_key_id"] as? String,
                                   tokenURI: obj["token_uri"] as? String ?? "https://oauth2.googleapis.com/token")
        case "impersonated_service_account":
            guard let source = obj["source_credentials"] as? [String: Any],
                  let url = obj["service_account_impersonation_url"] as? String else {
                throw CappyError.transcription(tr("impersonated_service_account credentials are missing required fields: \(path)", ja: "impersonated_service_account の認証情報に必要な項目がありません: \(path)"))
            }
            return .impersonated(source: try parseKind(source, path: path), url: url)
        default:
            throw CappyError.transcription(tr("Unsupported credentials type: \(type.isEmpty ? "(unknown)" : type) (\(path))", ja: "未対応の認証情報の種類です: \(type.isEmpty ? "(不明)" : type)（\(path)）"),
                                           hint: tr("Supported types are authorized_user / service_account / impersonated_service_account", ja: "authorized_user / service_account / impersonated_service_account に対応しています"))
        }
    }

    init(kind: Kind, path: String, quotaProject: String?, transport: HTTPTransport) {
        self.kind = kind
        self.path = path
        self.quotaProject = quotaProject
        self.transport = transport
    }

    static func impersonatedEmail(_ url: String) -> String? {
        guard let r = url.range(of: "serviceAccounts/") else { return nil }
        return url[r.upperBound...].components(separatedBy: ":").first
    }

    public func accessToken() async throws -> String {
        if let cached, cached.expiry.timeIntervalSinceNow > 60 { return cached.token }
        let (token, expiresIn) = try await fetch(kind)
        cached = (token, Date().addingTimeInterval(expiresIn))
        return token
    }

    private func fetch(_ kind: Kind) async throws -> (String, TimeInterval) {
        switch kind {
        case .authorizedUser(let id, let secret, let refresh, let uri):
            return try await tokenRequest(uri: uri, form: [
                "grant_type": "refresh_token", "client_id": id, "client_secret": secret, "refresh_token": refresh,
            ])
        case .serviceAccount(let email, let key, let keyID, let uri):
            let jwt = try JWT.sign(email: email, scope: Self.scope, audience: uri, key: key, keyID: keyID)
            return try await tokenRequest(uri: uri, form: [
                "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": jwt,
            ])
        case .impersonated(let source, let url):
            let (sourceToken, _) = try await fetch(source)
            guard let u = URL(string: url) else { throw CappyError.transcription(tr("Invalid impersonation URL: \(url)", ja: "借用 URL が不正です: \(url)")) }
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.setValue("Bearer \(sourceToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["scope": [Self.scope], "lifetime": "3600s"])
            let resp = try await transport.send(req)
            guard resp.status == 200 else {
                throw CappyError.transcription(tr("Service account impersonation failed: \(GoogleAPIError.from(resp))", ja: "サービスアカウントの借用に失敗しました: \(GoogleAPIError.from(resp))"))
            }
            struct R: Decodable { var accessToken: String; var expireTime: String? }
            let r = try JSONDecoder().decode(R.self, from: resp.body)
            let exp = r.expireTime.flatMap(TimeFormat.parseISO8601)?.timeIntervalSinceNow ?? 3000
            return (r.accessToken, exp)
        }
    }

    private func tokenRequest(uri: String, form: [String: String]) async throws -> (String, TimeInterval) {
        guard let url = URL(string: uri) else { throw CappyError.transcription(tr("Invalid token_uri: \(uri)", ja: "token_uri が不正です: \(uri)")) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(FormEncoding.encode(form).utf8)
        let request = req
        let resp = try await RetryPolicy().run(tr("Getting a token", ja: "トークン取得")) { [transport] in
            let r = try await transport.send(request)
            if r.status >= 500 || r.status == 429 { throw GoogleAPIError.from(r) }
            return r
        }
        guard resp.status == 200 else {
            struct E: Decodable { var error: String?; var error_description: String? }
            let e = try? JSONDecoder().decode(E.self, from: resp.body)
            throw CappyError.transcription(
                tr("Cannot get an access token (HTTP \(resp.status)): \(e?.error_description ?? e?.error ?? resp.text)", ja: "アクセストークンを取得できません（HTTP \(resp.status)）: \(e?.error_description ?? e?.error ?? resp.text)"),
                hint: tr("Sign in again with `gcloud auth application-default login`", ja: "`gcloud auth application-default login` で認証し直してください"))
        }
        struct R: Decodable { var access_token: String; var expires_in: Double? }
        let r = try JSONDecoder().decode(R.self, from: resp.body)
        return (r.access_token, r.expires_in ?? 3600)
    }
}

enum FormEncoding {
    static func encode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.keys.sorted().map { k in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(form[k]!.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public enum JWT {
    public static func sign(email: String, scope: String, audience: String, key: SecKey, keyID: String?,
                            now: Date = Date()) throws -> String {
        var header: [String: String] = ["alg": "RS256", "typ": "JWT"]
        if let keyID { header["kid"] = keyID }
        let iat = Int(now.timeIntervalSince1970)
        let claims: [String: Any] = ["iss": email, "scope": scope, "aud": audience, "iat": iat, "exp": iat + 3600]
        let h = Base64URL.encode(try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        let c = Base64URL.encode(try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
        let input = Data("\(h).\(c)".utf8)
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, &error) as Data? else {
            throw CappyError.transcription(tr("Cannot sign the JWT: \(error?.takeRetainedValue().localizedDescription ?? "")", ja: "JWT に署名できません: \(error?.takeRetainedValue().localizedDescription ?? "")"))
        }
        return "\(h).\(c).\(Base64URL.encode(sig))"
    }
}

/// PEM（PKCS#8 / PKCS#1）の RSA 秘密鍵を SecKey にする
public enum RSAKey {
    public static func privateKey(fromPEM pem: String) throws -> SecKey {
        let isPKCS8 = pem.contains("BEGIN PRIVATE KEY")
        let body = pem.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: body) else {
            throw CappyError.transcription(tr("Cannot parse the private key PEM", ja: "秘密鍵の PEM を解釈できません"))
        }
        let pkcs1 = isPKCS8 ? try pkcs1(fromPKCS8: der) : der
        var error: Unmanaged<CFError>?
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) else {
            throw CappyError.transcription(tr("Cannot load the private key: \(error?.takeRetainedValue().localizedDescription ?? "")", ja: "秘密鍵を読み込めません: \(error?.takeRetainedValue().localizedDescription ?? "")"))
        }
        return key
    }

    /// PKCS#8 PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm SEQUENCE, privateKey OCTET STRING }
    public static func pkcs1(fromPKCS8 der: Data) throws -> Data {
        let bytes = [UInt8](der)
        var p = 0
        func readTLV() throws -> (tag: UInt8, start: Int, length: Int) {
            guard p < bytes.count else { throw CappyError.transcription(tr("Failed to parse PKCS#8", ja: "PKCS#8 の解析に失敗しました")) }
            let tag = bytes[p]; p += 1
            guard p < bytes.count else { throw CappyError.transcription(tr("Failed to parse PKCS#8", ja: "PKCS#8 の解析に失敗しました")) }
            var len = Int(bytes[p]); p += 1
            if len & 0x80 != 0 {
                let n = len & 0x7F
                guard n <= 4, p + n <= bytes.count else { throw CappyError.transcription(tr("Failed to parse PKCS#8", ja: "PKCS#8 の解析に失敗しました")) }
                len = 0
                for _ in 0..<n { len = (len << 8) | Int(bytes[p]); p += 1 }
            }
            guard p + len <= bytes.count else { throw CappyError.transcription(tr("Failed to parse PKCS#8", ja: "PKCS#8 の解析に失敗しました")) }
            return (tag, p, len)
        }
        let seq = try readTLV()
        guard seq.tag == 0x30 else { throw CappyError.transcription(tr("Invalid PKCS#8 format", ja: "PKCS#8 の形式が不正です")) }
        let version = try readTLV()
        guard version.tag == 0x02 else { throw CappyError.transcription(tr("Invalid PKCS#8 format", ja: "PKCS#8 の形式が不正です")) }
        p = version.start + version.length
        let alg = try readTLV()
        guard alg.tag == 0x30 else { throw CappyError.transcription(tr("Invalid PKCS#8 format", ja: "PKCS#8 の形式が不正です")) }
        p = alg.start + alg.length
        let octet = try readTLV()
        guard octet.tag == 0x04 else { throw CappyError.transcription(tr("Invalid PKCS#8 format", ja: "PKCS#8 の形式が不正です")) }
        return Data(bytes[octet.start..<(octet.start + octet.length)])
    }
}
