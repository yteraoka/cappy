import CryptoKit
import Foundation

/// AWS の認証情報（ログやエラーには出さない）
public struct AWSCredentials: Sendable, Equatable, CustomStringConvertible {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?
    /// 一時的な認証情報の期限（固定のアクセスキーなら nil）
    public var expiration: Date?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil, expiration: Date? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.expiration = expiration
    }

    /// 秘密情報を含めない
    public var description: String {
        "AWSCredentials(\(accessKeyID.prefix(4))…\(sessionToken == nil ? "" : ", session")\(expiration.map { ", expires \(TimeFormat.iso8601($0))" } ?? ""))"
    }
}

/// Signature Version 4 による署名
/// https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
public struct SigV4Signer: Sendable {
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"
    public static let emptyPayloadHash = hex(SHA256.hash(data: Data()))

    public var credentials: AWSCredentials
    public var region: String
    public var service: String

    public init(credentials: AWSCredentials, region: String, service: String) {
        self.credentials = credentials
        self.region = region
        self.service = service
    }

    /// S3 はパスを 1 回だけエンコードし、x-amz-content-sha256 を必須とする
    var isS3: Bool { service == "s3" }

    /// リクエストに Authorization などのヘッダーを付ける。
    /// payloadHash を省略すると httpBody の SHA-256 を使う（ファイルのアップロードでは呼び出し側で渡す）。
    /// 署名するのは host と、リクエストに設定済みのヘッダー（authorization / user-agent を除く）
    public func sign(_ request: inout URLRequest, payloadHash: String? = nil, date: Date = Date()) {
        guard let url = request.url else { return }
        let amzDate = Self.amzDate(date)
        let hash = payloadHash ?? Self.hex(SHA256.hash(data: request.httpBody ?? Data()))
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let token = credentials.sessionToken {
            request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        if isS3 {
            request.setValue(hash, forHTTPHeaderField: "X-Amz-Content-Sha256")
        }
        var headers: [String: String] = ["host": Self.hostHeader(url)]
        for (k, v) in request.allHTTPHeaderFields ?? [:] {
            let name = k.lowercased()
            if ["authorization", "user-agent", "host"].contains(name) { continue }
            headers[name] = Self.trimHeaderValue(v)
        }
        let (signedHeaders, signature) = signature(method: request.httpMethod ?? "GET", url: url,
                                                   headers: headers, payloadHash: hash, amzDate: amzDate)
        request.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope(amzDate)), "
                         + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }

    /// 署名をクエリに入れた URL（WebSocket の接続や署名付き URL 用）。署名するヘッダーは host だけ
    public func presign(_ url: URL, method: String = "GET", expires: Int, payloadHash: String = SigV4Signer.emptyPayloadHash,
                        date: Date = Date()) -> URL {
        let amzDate = Self.amzDate(date)
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items = comps.percentEncodedQueryItems ?? []
        let add: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(credentials.accessKeyID)/\(scope(amzDate))"),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(expires)),
        ] + (credentials.sessionToken.map { [("X-Amz-Security-Token", $0)] } ?? []) + [
            ("X-Amz-SignedHeaders", "host"),
        ]
        for (k, v) in add { items.append(URLQueryItem(name: k, value: Self.uriEncode(v))) }
        comps.percentEncodedQueryItems = items
        let unsigned = comps.url!
        let (_, signature) = signature(method: method, url: unsigned, headers: ["host": Self.hostHeader(url)],
                                       payloadHash: payloadHash, amzDate: amzDate)
        items.append(URLQueryItem(name: "X-Amz-Signature", value: signature))
        comps.percentEncodedQueryItems = items
        return comps.url!
    }

    // MARK: 署名の計算

    func scope(_ amzDate: String) -> String {
        "\(amzDate.prefix(8))/\(region)/\(service)/aws4_request"
    }

    func signature(method: String, url: URL, headers: [String: String], payloadHash: String, amzDate: String) -> (String, String) {
        let names = headers.keys.sorted()
        let signedHeaders = names.joined(separator: ";")
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!)\n" }.joined()
        let canonical = [
            method.uppercased(),
            canonicalURI(url),
            Self.canonicalQuery(url),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope(amzDate),
            Self.hex(SHA256.hash(data: Data(canonical.utf8))),
        ].joined(separator: "\n")
        let key = signingKey(date: String(amzDate.prefix(8)))
        let sig = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)
        return (signedHeaders, Self.hex(sig))
    }

    func signingKey(date: String) -> SymmetricKey {
        func hmac(_ key: SymmetricKey, _ s: String) -> SymmetricKey {
            SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: key)))
        }
        var k = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [date, region, service, "aws4_request"] { k = hmac(k, part) }
        return k
    }

    /// パスの各部分を URI エンコードする（S3 以外は、エンコード済みのパスをもう一度エンコードする）
    func canonicalURI(_ url: URL) -> String {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = comps?.percentEncodedPath ?? ""
        if path.isEmpty { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false).map { seg in
            let decoded = String(seg).removingPercentEncoding ?? String(seg)
            let once = Self.uriEncode(decoded)
            return isS3 ? once : Self.uriEncode(once)
        }.joined(separator: "/")
    }

    static func canonicalQuery(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems else { return "" }
        var pairs: [(name: String, value: String)] = []
        for item in items {
            let name: String = item.name.removingPercentEncoding ?? item.name
            let raw: String = item.value ?? ""
            let value: String = raw.removingPercentEncoding ?? raw
            pairs.append((uriEncode(name), uriEncode(value)))
        }
        pairs.sort { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
        return pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    /// RFC 3986 の非予約文字（A-Z a-z 0-9 - . _ ~）以外をエンコードする
    public static func uriEncode(_ s: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func hostHeader(_ url: URL) -> String {
        let host = url.host ?? ""
        guard let port = url.port else { return host }
        let scheme = url.scheme?.lowercased()
        let defaultPorts: [String: Int] = ["https": 443, "wss": 443, "http": 80, "ws": 80]
        let isDefault = scheme.flatMap { defaultPorts[$0] } == port
        return isDefault ? host : "\(host):\(port)"
    }

    static func trimHeaderValue(_ v: String) -> String {
        v.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    static func amzDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
