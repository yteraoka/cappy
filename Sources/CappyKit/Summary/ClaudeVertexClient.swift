import Foundation

/// 要約モデルへの 1 回分の依頼
public struct SummaryRequest: Sendable, Equatable {
    public var system: String
    public var userText: String
    public var maxTokens: Int
    /// low / medium / high / xhigh / max
    public var effort: String

    public init(system: String, userText: String, maxTokens: Int, effort: String) {
        self.system = system
        self.userText = userText
        self.maxTokens = maxTokens
        self.effort = effort
    }
}

/// 要約モデルの応答
public struct SummaryResponse: Sendable, Equatable {
    public var text: String
    public var model: String
    public var stopReason: String?
    /// stop_reason が refusal のときの分類
    public var refusalCategory: String?
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(text: String, model: String, stopReason: String?, refusalCategory: String? = nil,
                inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.text = text
        self.model = model
        self.stopReason = stopReason
        self.refusalCategory = refusalCategory
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// 要約に使うモデルの呼び出し（テストではスタブに差し替える）
public protocol SummaryModelClient: Sendable {
    var providerName: String { get }
    var region: String? { get }
    func generate(_ request: SummaryRequest, model: String) async throws -> SummaryResponse
    /// 入力トークン数を数える（課金されない。doctor でアクセス確認に使う）
    func countTokens(_ request: SummaryRequest, model: String) async throws -> Int
    /// モデルにアクセスできるかを、課金されない方法で確かめる（doctor 用）
    func checkAccess(model: String, effort: String) async throws
}

extension SummaryModelClient {
    /// 既定: トークン数の確認で代用する
    public func checkAccess(model: String, effort: String) async throws {
        _ = try await countTokens(SummaryRequest(system: "ping", userText: "ping", maxTokens: 1024, effort: effort), model: model)
    }
}

/// Claude on Vertex AI（Claude Models on Google Cloud, Google managed）を REST で呼ぶ。
/// 認証は Google の ADC。リクエスト本文は Messages API とほぼ同じで、モデルは URL で指定し、
/// anthropic_version を本文に入れる。
public struct ClaudeVertexClient: SummaryModelClient {
    public static let apiVersion = "2026-10-21"

    public let projectID: String
    public let location: String
    let auth: AccessTokenProvider
    let transport: HTTPTransport
    let retry: RetryPolicy
    let userProject: String?

    public var providerName: String { "vertex" }
    public var region: String? { location }

    public init(projectID: String, region: String, auth: AccessTokenProvider,
                transport: HTTPTransport = URLSessionTransport(), retry: RetryPolicy = RetryPolicy(),
                userProject: String? = nil) {
        self.projectID = projectID
        self.location = region
        self.auth = auth
        self.transport = transport
        self.retry = retry
        self.userProject = userProject ?? projectID
    }

    public static func host(region: String) -> String { VertexAI.host(region: region) }

    public func endpoint(model: String, method: String) -> String {
        "https://\(Self.host(region: location))/v1/projects/\(projectID)/locations/\(location)/publishers/anthropic/models/\(model):\(method)"
    }

    func makeRequest(url: String, body: Data) async throws -> URLRequest {
        guard let u = URL(string: url) else { throw CappyError.transcription(tr("Invalid URL: \(url)", ja: "URL が不正です: \(url)")) }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        // 思考中はイベントが途切れることがあるため、無通信タイムアウトを長めにする
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        if let userProject { req.setValue(userProject, forHTTPHeaderField: "x-goog-user-project") }
        req.httpBody = body
        return req
    }

    static func messagesBody(_ r: SummaryRequest) -> [String: Any] {
        [
            "anthropic_version": apiVersion,
            "max_tokens": r.maxTokens,
            "stream": true,
            "system": r.system,
            "messages": [["role": "user", "content": r.userText]],
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": r.effort],
        ]
    }

    public func generate(_ request: SummaryRequest, model: String) async throws -> SummaryResponse {
        let url = endpoint(model: model, method: "streamRawPredict")
        let body = try JSONSerialization.data(withJSONObject: Self.messagesBody(request), options: [.sortedKeys])
        return try await retry.run(tr("Summary (\(model))", ja: "要約（\(model)）")) {
            let req = try await makeRequest(url: url, body: body)
            var parser = ClaudeStreamParser(model: model)
            // エラー応答（JSON）を読むために先頭だけ保持する
            var head = ""
            let resp = try await transport.streamLines(req) { line in
                if head.utf8.count < 8192 { head += line + "\n" }
                try parser.feed(line)
            }
            guard resp.status == 200 else {
                throw GoogleAPIError.from(HTTPResponse(status: resp.status, body: Data(head.utf8)))
            }
            return try parser.finish()
        }
    }

    public func countTokens(_ request: SummaryRequest, model: String) async throws -> Int {
        let url = endpoint(model: "count-tokens", method: "rawPredict")
        let body = try JSONSerialization.data(withJSONObject: [
            "anthropic_version": Self.apiVersion,
            "model": model,
            "system": request.system,
            "messages": [["role": "user", "content": request.userText]],
        ] as [String: Any], options: [.sortedKeys])
        let resp = try await retry.run(tr("Counting tokens", ja: "トークン数の確認")) {
            let r = try await transport.send(try await makeRequest(url: url, body: body))
            guard r.status == 200 else { throw GoogleAPIError.from(r) }
            return r
        }
        guard let obj = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              let n = obj["input_tokens"] as? Int else {
            throw CappyError.transcription(tr("Invalid token count response", ja: "トークン数の応答が不正です"))
        }
        return n
    }
}

/// Messages API のストリーミング（Server-Sent Events）を組み立てる
public struct ClaudeStreamParser {
    public private(set) var sawEvent = false
    private var model: String
    private var text = ""
    private var textBlocks: Set<Int> = []
    private var stopReason: String?
    private var refusalCategory: String?
    private var inputTokens: Int?
    private var outputTokens: Int?
    private var stopped = false

    public init(model: String) { self.model = model }

    /// 1 行を処理する。data: 行以外（event: 行、コメント、空行）は読み飛ばす
    public mutating func feed(_ line: String) throws {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        sawEvent = true
        switch type {
        case "message_start":
            if let msg = obj["message"] as? [String: Any] {
                if let m = msg["model"] as? String, !m.isEmpty { model = m }
                if let usage = msg["usage"] as? [String: Any] {
                    inputTokens = Self.totalInput(usage)
                    if let o = usage["output_tokens"] as? Int { outputTokens = o }
                }
            }
        case "content_block_start":
            if let index = obj["index"] as? Int, let block = obj["content_block"] as? [String: Any],
               block["type"] as? String == "text" {
                textBlocks.insert(index)
                if let t = block["text"] as? String { text += t }
            }
        case "content_block_delta":
            if let index = obj["index"] as? Int, textBlocks.contains(index),
               let delta = obj["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let t = delta["text"] as? String {
                text += t
            }
        case "message_delta":
            if let delta = obj["delta"] as? [String: Any] {
                if let r = delta["stop_reason"] as? String { stopReason = r }
                if let d = delta["stop_details"] as? [String: Any], let c = d["category"] as? String { refusalCategory = c }
            }
            if let usage = obj["usage"] as? [String: Any] {
                if let o = usage["output_tokens"] as? Int { outputTokens = o }
                if let i = Self.totalInput(usage) { inputTokens = i }
            }
        case "message_stop":
            stopped = true
        case "error":
            let err = obj["error"] as? [String: Any]
            let errType = err?["type"] as? String ?? "error"
            let message = err?["message"] as? String ?? tr("unknown error", ja: "不明なエラー")
            let status: Int
            switch errType {
            case "overloaded_error": status = 529
            case "rate_limit_error": status = 429
            case "api_error": status = 500
            case "timeout_error": status = 504
            default: status = 400
            }
            throw GoogleAPIError(httpStatus: status, status: errType, message: message)
        default:
            break // ping, content_block_stop など
        }
    }

    public func finish() throws -> SummaryResponse {
        guard sawEvent else {
            throw CappyError.transcription(tr("The summary response is empty", ja: "要約の応答が空です"))
        }
        guard stopped || stopReason != nil else {
            // 途中で接続が切れた（一時的なエラーとして再試行させる）
            throw GoogleAPIError(httpStatus: 503, status: "incomplete_stream", message: tr("The response was cut off", ja: "応答が途中で切れました"))
        }
        return SummaryResponse(text: text.trimmingCharacters(in: .whitespacesAndNewlines), model: model,
                               stopReason: stopReason, refusalCategory: refusalCategory,
                               inputTokens: inputTokens, outputTokens: outputTokens)
    }

    static func totalInput(_ usage: [String: Any]) -> Int? {
        guard let i = usage["input_tokens"] as? Int else { return nil }
        return i + (usage["cache_creation_input_tokens"] as? Int ?? 0) + (usage["cache_read_input_tokens"] as? Int ?? 0)
    }
}
