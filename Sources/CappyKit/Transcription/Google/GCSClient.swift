import Foundation

public struct GCSObjectRef: Sendable, Equatable {
    public var bucket: String
    public var name: String

    public init(bucket: String, name: String) {
        self.bucket = bucket
        self.name = name
    }

    public init?(uri: String) {
        guard uri.hasPrefix("gs://") else { return nil }
        let rest = uri.dropFirst(5)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        bucket = String(rest[..<slash])
        name = String(rest[rest.index(after: slash)...])
    }

    public var uri: String { "gs://\(bucket)/\(name)" }
}

/// Cloud Storage JSON API の最小クライアント
public struct GCSClient: Sendable {
    let auth: AccessTokenProvider
    let transport: HTTPTransport
    let userProject: String?
    let retry: RetryPolicy

    public init(auth: AccessTokenProvider, transport: HTTPTransport, userProject: String?, retry: RetryPolicy = RetryPolicy()) {
        self.auth = auth
        self.transport = transport
        self.userProject = userProject
        self.retry = retry
    }

    static func encodeObject(_ name: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }

    private func request(_ url: String, method: String = "GET") async throws -> URLRequest {
        guard let u = URL(string: url) else { throw CappyError.transcription(tr("Invalid URL: \(url)", ja: "URL が不正です: \(url)")) }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        if let userProject { req.setValue(userProject, forHTTPHeaderField: "x-goog-user-project") }
        return req
    }

    private func check(_ resp: HTTPResponse, allow: Set<Int> = [200]) throws -> HTTPResponse {
        guard allow.contains(resp.status) else { throw GoogleAPIError.from(resp) }
        return resp
    }

    public func upload(file: URL, to object: GCSObjectRef, contentType: String) async throws {
        let url = "https://storage.googleapis.com/upload/storage/v1/b/\(Self.encodeObject(object.bucket))/o?uploadType=media&name=\(Self.encodeObject(object.name))"
        _ = try await retry.run(tr("Upload \(object.name)", ja: "アップロード \(object.name)")) {
            var req = try await request(url, method: "POST")
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 600
            return try check(try await transport.upload(req, fromFile: file))
        }
    }

    public func download(_ object: GCSObjectRef) async throws -> Data {
        let url = "https://storage.googleapis.com/storage/v1/b/\(Self.encodeObject(object.bucket))/o/\(Self.encodeObject(object.name))?alt=media"
        return try await retry.run(tr("Download \(object.name)", ja: "ダウンロード \(object.name)")) {
            try check(try await transport.send(try await request(url))).body
        }
    }

    /// 削除（存在しなければ何もしない）
    public func delete(_ object: GCSObjectRef) async throws {
        let url = "https://storage.googleapis.com/storage/v1/b/\(Self.encodeObject(object.bucket))/o/\(Self.encodeObject(object.name))"
        _ = try await retry.run(tr("Delete \(object.name)", ja: "削除 \(object.name)")) {
            try check(try await transport.send(try await request(url, method: "DELETE")), allow: [200, 204, 404])
        }
    }

    public func list(bucket: String, prefix: String) async throws -> [GCSObjectRef] {
        var result: [GCSObjectRef] = []
        var pageToken: String?
        repeat {
            var url = "https://storage.googleapis.com/storage/v1/b/\(Self.encodeObject(bucket))/o?prefix=\(Self.encodeObject(prefix))&fields=items(name),nextPageToken"
            if let pageToken { url += "&pageToken=\(Self.encodeObject(pageToken))" }
            let pageURL = url
            let resp = try await retry.run(tr("List \(prefix)", ja: "一覧 \(prefix)")) {
                try check(try await transport.send(try await request(pageURL)))
            }
            struct Page: Decodable {
                struct Item: Decodable { var name: String }
                var items: [Item]?
                var nextPageToken: String?
            }
            let page = try JSONDecoder().decode(Page.self, from: resp.body)
            result += (page.items ?? []).map { GCSObjectRef(bucket: bucket, name: $0.name) }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return result
    }

    /// 呼び出し元が持っている権限を返す（バケットへの書き込み可否の確認用）
    public func testPermissions(bucket: String, permissions: [String]) async throws -> [String] {
        let q = permissions.map { "permissions=\(Self.encodeObject($0))" }.joined(separator: "&")
        let url = "https://storage.googleapis.com/storage/v1/b/\(Self.encodeObject(bucket))/iam/testPermissions?\(q)"
        let resp = try check(try await transport.send(try await request(url)))
        struct R: Decodable { var permissions: [String]? }
        return try JSONDecoder().decode(R.self, from: resp.body).permissions ?? []
    }

    public struct BucketInfo: Sendable {
        public var location: String?
        public var uniformAccess: Bool
        /// 削除ルールの最小 age（日）
        public var deleteAgeDays: Int?
    }

    public func bucketInfo(_ bucket: String) async throws -> BucketInfo {
        let url = "https://storage.googleapis.com/storage/v1/b/\(Self.encodeObject(bucket))?fields=location,iamConfiguration,lifecycle"
        let resp = try check(try await transport.send(try await request(url)))
        let obj = (try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any]) ?? [:]
        let iam = obj["iamConfiguration"] as? [String: Any]
        let ubla = (iam?["uniformBucketLevelAccess"] as? [String: Any])?["enabled"] as? Bool ?? false
        var minAge: Int?
        for rule in ((obj["lifecycle"] as? [String: Any])?["rule"] as? [[String: Any]]) ?? [] {
            guard (rule["action"] as? [String: Any])?["type"] as? String == "Delete" else { continue }
            if let age = (rule["condition"] as? [String: Any])?["age"] as? Int {
                minAge = min(minAge ?? age, age)
            }
        }
        return BucketInfo(location: obj["location"] as? String, uniformAccess: ubla, deleteAgeDays: minAge)
    }
}
