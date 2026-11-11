import Foundation

/// Bedrock のモデル ID の扱い
public enum BedrockModels {
    /// 推論プロファイルの範囲として ID の先頭に付くもの
    public static let routingPrefixes: Set<String> = ["global", "us", "eu", "jp", "au", "apac", "ca", "in", "us-gov"]

    /// `moonshotai.kimi-k3.1` / `global.zai.glm-5.3` のような、Anthropic 以外の Bedrock のモデル ID か
    public static func isChatModel(_ model: String) -> Bool {
        let m = model.lowercased()
        guard m.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)?\.[a-z0-9][a-z0-9._:-]*$"#, options: .regularExpression) != nil else { return false }
        return !m.contains("anthropic.") && !m.hasPrefix("claude-") && !m.hasPrefix("gemini-")
    }

    /// 推論プロファイルの範囲が付いているか（`global.zai.glm-5.3` など）
    static func hasRoutingPrefix(_ model: String) -> Bool {
        let parts = model.split(separator: ".")
        return parts.count >= 3 && routingPrefixes.contains(String(parts[0]))
    }

    /// cappy のモデル名を Bedrock のモデル ID にする。
    /// - `claude-opus-5-5` → `<routing>.anthropic.claude-opus-5-5`（routing がリージョン名なら `anthropic.claude-opus-5-5`）
    /// - `moonshotai.kimi-k3.1` → `<routing>.moonshotai.kimi-k3.1`（routing がリージョン名ならそのまま）
    /// - 範囲が付いた ID（`global.zai.glm-5.3`）と、`anthropic.` で始まる ID はそのまま
    public static func modelID(_ model: String, routing: String) -> String {
        if model.contains("anthropic.") || hasRoutingPrefix(model) { return model }
        let inRegion = BedrockClaudeClient.isAWSRegion(routing)
        if model.lowercased().hasPrefix("claude-") {
            return inRegion ? "anthropic.\(model)" : "\(routing).anthropic.\(model)"
        }
        return inRegion ? model : "\(routing).\(model)"
    }
}

/// Amazon Bedrock の OpenAI 互換 Chat Completions（`/openai/v1/chat/completions`）で、
/// Anthropic 以外のモデル（Kimi K3.1、GLM-5.3 など）を呼ぶ。SigV4 のサービス名は `bedrock`
public struct BedrockChatClient: SummaryModelClient {
    public let endpointRegion: String
    public let routing: String
    let credentials: AWSCredentialsSource
    let transport: HTTPTransport
    let retry: RetryPolicy

    public var providerName: String { "bedrock" }
    public var region: String? { routing }

    public init(region awsRegion: String, routing: String, credentials: AWSCredentialsSource,
                transport: HTTPTransport = URLSessionTransport(), retry: RetryPolicy = RetryPolicy()) {
        self.endpointRegion = BedrockClaudeClient.isAWSRegion(routing) ? routing : awsRegion
        self.routing = routing
        self.credentials = credentials
        self.transport = transport
        self.retry = retry
    }

    public var endpoint: URL {
        URL(string: "https://bedrock-runtime.\(endpointRegion).amazonaws.com/openai/v1/chat/completions")!
    }

    func makeRequest(body: Data, stream: Bool) async throws -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream { req.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        req.httpBody = body
        SigV4Signer(credentials: try await credentials.credentials(), region: endpointRegion, service: "bedrock").sign(&req)
        return req
    }

    /// cappy の effort（low〜max）をそのまま reasoning_effort にする
    static func body(_ r: SummaryRequest, modelID: String) -> [String: Any] {
        [
            "model": modelID,
            "max_tokens": r.maxTokens,
            "stream": true,
            "stream_options": ["include_usage": true],
            "reasoning_effort": r.effort,
            "messages": [
                ["role": "system", "content": r.system],
                ["role": "user", "content": r.userText],
            ],
        ]
    }

    public func generate(_ request: SummaryRequest, model: String) async throws -> SummaryResponse {
        let id = BedrockModels.modelID(model, routing: routing)
        let body = try JSONSerialization.data(withJSONObject: Self.body(request, modelID: id), options: [.sortedKeys])
        return try await retry.run("要約（\(id)）") {
            let req = try await makeRequest(body: body, stream: true)
            var parser = ChatCompletionsStreamParser(model: id)
            var head = ""
            let resp = try await transport.streamLines(req) { line in
                if head.utf8.count < 8192 { head += line + "\n" }
                try parser.feed(line)
            }
            guard resp.status == 200 else {
                throw AWSAPIError.from(HTTPResponse(status: resp.status, body: Data(head.utf8), headers: resp.headers))
            }
            return try parser.finish()
        }
    }

    public func countTokens(_ request: SummaryRequest, model: String) async throws -> Int {
        throw CappyError.usage("\(model) のトークン数の確認には対応していません")
    }

    /// 課金されない確認: max_tokens = 0 の不正なリクエストを送る。
    /// モデルの利用権限は本文の検証より先に確かめられるため、403 やモデル ID の誤り以外の 400 なら使える
    public func checkAccess(model: String, effort: String) async throws {
        let id = BedrockModels.modelID(model, routing: routing)
        let body = try JSONSerialization.data(withJSONObject: [
            "model": id, "max_tokens": 0, "messages": [["role": "user", "content": "ping"]],
        ] as [String: Any], options: [.sortedKeys])
        let resp = try await retry.run("モデルの確認") {
            let r = try await transport.send(try await makeRequest(body: body, stream: false))
            if r.status >= 500 || r.status == 429 { throw AWSAPIError.from(r) }
            return r
        }
        if resp.status == 200 { return }
        let e = AWSAPIError.from(resp)
        if resp.status == 400 && !BedrockClaudeClient.isModelIdentifierError(e) { return }
        throw e
    }
}

/// Chat Completions のストリーミング（`data: {...}` と `data: [DONE]`）を組み立てる。
/// 思考の部分（delta.reasoning_content）は出力に含めない
public struct ChatCompletionsStreamParser {
    private var model: String
    private var text = ""
    private var refusal = ""
    private var finishReason: String?
    private var inputTokens: Int?
    private var outputTokens: Int?
    private var sawChunk = false
    private var done = false

    public init(model: String) { self.model = model }

    public mutating func feed(_ line: String) throws {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            done = true
            return
        }
        guard !payload.isEmpty, let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return }
        if let err = obj["error"] as? [String: Any] {
            let type = err["type"] as? String ?? err["code"] as? String
            let message = err["message"] as? String ?? "不明なエラー"
            let status = ["rate_limit_error": 429, "overloaded_error": 529, "server_error": 500, "api_error": 500][type ?? ""] ?? 400
            throw AWSAPIError(httpStatus: status, code: type, message: message)
        }
        sawChunk = true
        if let m = obj["model"] as? String, !m.isEmpty { model = m }
        if let usage = obj["usage"] as? [String: Any] {
            if let i = usage["prompt_tokens"] as? Int { inputTokens = i }
            if let o = usage["completion_tokens"] as? Int { outputTokens = o }
        }
        for choice in obj["choices"] as? [[String: Any]] ?? [] {
            if let delta = choice["delta"] as? [String: Any] {
                if let t = delta["content"] as? String { text += t }
                if let r = delta["refusal"] as? String { refusal += r }
            }
            if let r = choice["finish_reason"] as? String { finishReason = r }
        }
    }

    /// finish_reason を Claude と同じ stop_reason にそろえる（Summarizer が max_tokens / refusal を見る）
    static func stopReason(_ finish: String?, refused: Bool) -> String? {
        if refused { return "refusal" }
        switch finish {
        case "stop": return "end_turn"
        case "length": return "max_tokens"
        case "content_filter": return "refusal"
        default: return finish
        }
    }

    public func finish() throws -> SummaryResponse {
        guard sawChunk else { throw CappyError.transcription("要約の応答が空です") }
        guard done || finishReason != nil else {
            throw AWSAPIError(httpStatus: 503, code: "incomplete_stream", message: "応答が途中で切れました")
        }
        let refused = !refusal.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return SummaryResponse(text: text.trimmingCharacters(in: .whitespacesAndNewlines), model: model,
                               stopReason: Self.stopReason(finishReason, refused: refused),
                               refusalCategory: refused ? refusal : nil,
                               inputTokens: inputTokens, outputTokens: outputTokens)
    }
}

/// Bedrock 上の Claude（Messages API）と、それ以外のモデル（Chat Completions）をモデル名で振り分ける
public struct BedrockSummaryClient: SummaryModelClient {
    public let claude: BedrockClaudeClient
    public let chat: BedrockChatClient

    public var providerName: String { "bedrock" }
    public var region: String? { claude.routing }
    public var endpointRegion: String { claude.endpointRegion }

    public init(region: String, routing: String, credentials: AWSCredentialsSource,
                transport: HTTPTransport = URLSessionTransport(), retry: RetryPolicy = RetryPolicy()) {
        claude = BedrockClaudeClient(region: region, routing: routing, credentials: credentials, transport: transport, retry: retry)
        chat = BedrockChatClient(region: region, routing: routing, credentials: credentials, transport: transport, retry: retry)
    }

    func client(for model: String) throws -> SummaryModelClient {
        switch SummaryModelFamily.of(model) {
        case .claude: return claude
        case .bedrockChat: return chat
        case .gemini, nil:
            throw CappyError.usage("Bedrock では使えないモデルです: \(model)（claude- で始まるモデル、または moonshotai.kimi-k3.1 のような Bedrock のモデル ID）")
        }
    }

    public func generate(_ request: SummaryRequest, model: String) async throws -> SummaryResponse {
        try await client(for: model).generate(request, model: model)
    }

    public func countTokens(_ request: SummaryRequest, model: String) async throws -> Int {
        try await client(for: model).countTokens(request, model: model)
    }

    public func checkAccess(model: String, effort: String) async throws {
        try await client(for: model).checkAccess(model: model, effort: effort)
    }
}
