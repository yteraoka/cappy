import CryptoKit
import Foundation

public struct S3ObjectRef: Sendable, Equatable {
    public var bucket: String
    public var key: String

    public init(bucket: String, key: String) {
        self.bucket = bucket
        self.key = key
    }

    public init?(uri: String) {
        guard uri.hasPrefix("s3://") else { return nil }
        let rest = uri.dropFirst(5)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        bucket = String(rest[..<slash])
        key = String(rest[rest.index(after: slash)...])
    }

    public var uri: String { "s3://\(bucket)/\(key)" }
}

/// S3 の最小クライアント（アップロード・削除と、doctor 用の確認）
public struct S3Client: Sendable {
    let credentials: AWSCredentialsSource
    public let region: String
    let transport: HTTPTransport
    let retry: RetryPolicy

    public init(credentials: AWSCredentialsSource, region: String, transport: HTTPTransport = URLSessionTransport(),
                retry: RetryPolicy = RetryPolicy()) {
        self.credentials = credentials
        self.region = region
        self.transport = transport
        self.retry = retry
    }

    /// 仮想ホスト形式の URL。バケット名に「.」があると TLS の証明書と合わないため、パス形式にする
    func url(bucket: String, key: String = "", query: String? = nil) -> URL {
        let path = key.split(separator: "/", omittingEmptySubsequences: false)
            .map { SigV4Signer.uriEncode(String($0)) }.joined(separator: "/")
        var s: String
        if bucket.contains(".") {
            s = "https://s3.\(region).amazonaws.com/\(SigV4Signer.uriEncode(bucket))/\(path)"
        } else {
            s = "https://\(bucket).s3.\(region).amazonaws.com/\(path)"
        }
        if let query { s += "?\(query)" }
        return URL(string: s)!
    }

    func send(_ method: String, _ url: URL, payloadHash: String = SigV4Signer.emptyPayloadHash,
              headers: [String: String] = [:], file: URL? = nil, what: String) async throws -> HTTPResponse {
        try await retry.run(what) {
            var req = URLRequest(url: url)
            req.httpMethod = method
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            SigV4Signer(credentials: try await credentials.credentials(), region: region, service: "s3")
                .sign(&req, payloadHash: payloadHash)
            let r: HTTPResponse
            if let file {
                r = try await transport.upload(req, fromFile: file)
            } else {
                r = try await transport.send(req)
            }
            if r.status >= 500 || r.status == 429 { throw AWSAPIError.from(r) }
            return r
        }
    }

    static func sha256Hex(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func upload(file: URL, to object: S3ObjectRef, contentType: String) async throws {
        let hash = try Self.sha256Hex(file: file)
        let r = try await send("PUT", url(bucket: object.bucket, key: object.key), payloadHash: hash,
                               headers: ["Content-Type": contentType], file: file, what: tr("Upload \(object.key)", ja: "アップロード \(object.key)"))
        guard r.status == 200 else { throw AWSAPIError.from(r) }
    }

    public func delete(_ object: S3ObjectRef) async throws {
        let r = try await send("DELETE", url(bucket: object.bucket, key: object.key), what: tr("Delete \(object.key)", ja: "削除 \(object.key)"))
        guard r.status == 204 || r.status == 200 || r.status == 404 else { throw AWSAPIError.from(r) }
    }

    /// オブジェクトがあるか（HEAD）
    public func exists(_ object: S3ObjectRef) async throws -> Bool {
        let r = try await send("HEAD", url(bucket: object.bucket, key: object.key), what: tr("Check \(object.key)", ja: "確認 \(object.key)"))
        if r.status == 404 { return false }
        guard r.status == 200 else { throw AWSAPIError(httpStatus: r.status, code: nil, message: "HEAD \(object.key)") }
        return true
    }

    // MARK: doctor

    /// バケットのリージョン（GetBucketLocation。us-east-1 は空で返る）
    public func bucketRegion(_ bucket: String) async throws -> String {
        let r = try await send("GET", url(bucket: bucket, query: "location="), what: "GetBucketLocation")
        guard r.status == 200 else { throw AWSAPIError.from(r) }
        let loc = XMLFields.parse(r.body)["LocationConstraint"] ?? ""
        return loc.isEmpty ? "us-east-1" : (loc == "EU" ? "eu-west-1" : loc)
    }

    public struct LifecycleRule: Sendable, Equatable {
        public var enabled: Bool
        public var prefix: String
        public var expirationDays: Int?
    }

    /// ライフサイクルルール（設定がなければ空）
    public func lifecycleRules(_ bucket: String) async throws -> [LifecycleRule] {
        let r = try await send("GET", url(bucket: bucket, query: "lifecycle="), what: "GetBucketLifecycleConfiguration")
        if r.status == 404 { return [] }
        guard r.status == 200 else { throw AWSAPIError.from(r) }
        return Self.parseLifecycle(r.body)
    }

    static func parseLifecycle(_ data: Data) -> [LifecycleRule] {
        final class Delegate: NSObject, XMLParserDelegate {
            var rules: [LifecycleRule] = []
            var current: LifecycleRule?
            var path: [String] = []
            var text = ""
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                        attributes: [String: String] = [:]) {
                path.append(name)
                text = ""
                if name == "Rule" { current = LifecycleRule(enabled: false, prefix: "", expirationDays: nil) }
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let parent = path.dropLast().last
                switch name {
                case "Status": current?.enabled = value == "Enabled"
                case "Prefix": current?.prefix = value
                case "Days" where parent == "Expiration": current?.expirationDays = Int(value)
                case "Rule":
                    if let c = current { rules.append(c) }
                    current = nil
                default: break
                }
                path.removeLast()
                text = ""
            }
        }
        let d = Delegate()
        let p = XMLParser(data: data)
        p.delegate = d
        _ = p.parse()
        return d.rules
    }
}
