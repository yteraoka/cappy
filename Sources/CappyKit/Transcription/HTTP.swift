import Foundation

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var headers: [String: String]

    public init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// HTTP 送受信の抽象（テストではスタブに差し替える）
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
    func upload(_ request: URLRequest, fromFile url: URL) async throws -> HTTPResponse
    /// 応答本文を 1 行ずつ渡す（Server-Sent Events 用。空行は渡さないことがある）。
    /// 戻り値の body は空で、status と headers だけが入る
    func streamLines(_ request: URLRequest, _ onLine: (String) throws -> Void) async throws -> HTTPResponse
}

extension HTTPTransport {
    /// 既定の実装: 本文をまとめて受け取ってから行に分ける（スタブ用）
    public func streamLines(_ request: URLRequest, _ onLine: (String) throws -> Void) async throws -> HTTPResponse {
        let r = try await send(request)
        for line in r.text.split(separator: "\n", omittingEmptySubsequences: true) {
            try onLine(String(line.hasSuffix("\r") ? line.dropLast() : line))
        }
        return HTTPResponse(status: r.status, body: Data(), headers: r.headers)
    }
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, resp) = try await session.data(for: request)
        return Self.wrap(data, resp)
    }

    public func upload(_ request: URLRequest, fromFile url: URL) async throws -> HTTPResponse {
        let (data, resp) = try await session.upload(for: request, fromFile: url)
        return Self.wrap(data, resp)
    }

    public func streamLines(_ request: URLRequest, _ onLine: (String) throws -> Void) async throws -> HTTPResponse {
        let (bytes, resp) = try await session.bytes(for: request)
        for try await line in bytes.lines {
            try onLine(line)
        }
        return Self.wrap(Data(), resp)
    }

    static func wrap(_ data: Data, _ resp: URLResponse) -> HTTPResponse {
        let http = resp as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] {
            if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
        }
        return HTTPResponse(status: http?.statusCode ?? 0, body: data, headers: headers)
    }
}

/// Google API のエラー応答
public struct GoogleAPIError: Error, CustomStringConvertible, Sendable {
    public var httpStatus: Int
    public var status: String?
    public var message: String

    public var description: String {
        "HTTP \(httpStatus)\(status.map { " \($0)" } ?? ""): \(message)"
    }

    /// 一時的エラー（再試行してよい）
    public var isTransient: Bool {
        [408, 429, 500, 502, 503, 504, 529].contains(httpStatus)
    }

    static func from(_ resp: HTTPResponse) -> GoogleAPIError {
        struct Envelope: Decodable {
            struct Inner: Decodable {
                var code: Int?
                var message: String?
                var status: String?
            }
            var error: Inner?
        }
        if let env = try? JSONDecoder().decode(Envelope.self, from: resp.body), let e = env.error {
            return GoogleAPIError(httpStatus: resp.status, status: e.status, message: e.message ?? resp.text)
        }
        // Vertex AI は [{"error": {...}}] の形で返すことがある
        if let list = try? JSONDecoder().decode([Envelope].self, from: resp.body), let e = list.first?.error {
            return GoogleAPIError(httpStatus: resp.status, status: e.status, message: e.message ?? resp.text)
        }
        return GoogleAPIError(httpStatus: resp.status, status: nil, message: String(resp.text.prefix(500)))
    }
}

/// 指数バックオフによる再試行
public struct RetryPolicy: Sendable {
    public var maxAttempts: Int = 5
    public var initialDelay: TimeInterval = 1
    public var maxDelay: TimeInterval = 30
    /// テスト用（実際には待たない）
    public var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }

    public init() {}

    public static let none: RetryPolicy = {
        var p = RetryPolicy()
        p.maxAttempts = 1
        return p
    }()

    public func run<T: Sendable>(_ what: String, _ body: @Sendable () async throws -> T) async throws -> T {
        var delay = initialDelay
        var attempt = 1
        while true {
            do {
                return try await body()
            } catch {
                let transient: Bool
                if let g = error as? GoogleAPIError {
                    transient = g.isTransient
                } else if let u = error as? URLError {
                    transient = [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                                 .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed].contains(u.code)
                } else {
                    transient = false
                }
                guard transient, attempt < maxAttempts else { throw error }
                CappyLog.shared.warning("\(what) が一時的に失敗しました（\(attempt)/\(maxAttempts)、\(Int(delay)) 秒後に再試行）: \(error)")
                try await sleep(delay)
                delay = min(maxDelay, delay * 2)
                attempt += 1
            }
        }
    }
}
