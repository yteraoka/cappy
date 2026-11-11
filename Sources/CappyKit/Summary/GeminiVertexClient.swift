import Foundation

/// Vertex AI の Gemini（publishers/google）を REST で呼ぶ。認証は Google の ADC。
public struct GeminiVertexClient: SummaryModelClient {
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

    public func endpoint(model: String, method: String) -> String {
        "https://\(VertexAI.host(region: location))/v1/projects/\(projectID)/locations/\(location)/publishers/google/models/\(model):\(method)"
    }

    /// Gemini 3 以降は thinkingLevel、2.5 以前は thinkingBudget（cappy では指定せず動的に任せる）
    public static func usesThinkingLevel(_ model: String) -> Bool {
        let rest = model.lowercased().dropFirst("gemini-".count)
        let digits = rest.prefix { $0.isNumber }
        guard let major = Int(digits) else { return true } // 不明な名前は新しい世代とみなす
        return major >= 3
    }

    /// cappy の effort → Gemini の thinkingLevel
    public static func thinkingLevel(effort: String) -> String {
        switch effort {
        case "low": return "LOW"
        case "medium": return "MEDIUM"
        default: return "HIGH" // high / xhigh / max
        }
    }

    static func body(_ r: SummaryRequest, model: String, thinking: Bool) -> [String: Any] {
        var generation: [String: Any] = ["maxOutputTokens": r.maxTokens]
        if thinking && usesThinkingLevel(model) {
            generation["thinkingConfig"] = ["thinkingLevel": thinkingLevel(effort: r.effort)]
        }
        return [
            "systemInstruction": ["parts": [["text": r.system]]],
            "contents": [["role": "user", "parts": [["text": r.userText]]]],
            "generationConfig": generation,
        ]
    }

    func makeRequest(url: String, body: Data) async throws -> URLRequest {
        guard let u = URL(string: url) else { throw CappyError.transcription("URL が不正です: \(url)") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        if let userProject { req.setValue(userProject, forHTTPHeaderField: "x-goog-user-project") }
        req.httpBody = body
        return req
    }

    public func generate(_ request: SummaryRequest, model: String) async throws -> SummaryResponse {
        do {
            return try await generate(request, model: model, thinking: true)
        } catch let e as GoogleAPIError where e.httpStatus == 400 && e.message.lowercased().contains("thinking") {
            // モデルが指定した thinkingLevel に対応していない場合は、既定の思考設定でやり直す
            CappyLog.shared.warning("\(model) が思考の設定を受け付けませんでした。既定の設定で再試行します: \(e.message)")
            return try await generate(request, model: model, thinking: false)
        }
    }

    func generate(_ request: SummaryRequest, model: String, thinking: Bool) async throws -> SummaryResponse {
        let url = endpoint(model: model, method: "streamGenerateContent") + "?alt=sse"
        let body = try JSONSerialization.data(withJSONObject: Self.body(request, model: model, thinking: thinking),
                                              options: [.sortedKeys])
        return try await retry.run("要約（\(model)）") {
            let req = try await makeRequest(url: url, body: body)
            var parser = GeminiStreamParser(model: model)
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
        let url = endpoint(model: model, method: "countTokens")
        let body = try JSONSerialization.data(withJSONObject: [
            "contents": [["role": "user", "parts": [["text": request.userText]]]],
        ] as [String: Any], options: [.sortedKeys])
        let resp = try await retry.run("トークン数の確認") {
            let r = try await transport.send(try await makeRequest(url: url, body: body))
            guard r.status == 200 else { throw GoogleAPIError.from(r) }
            return r
        }
        guard let obj = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              let n = obj["totalTokens"] as? Int else {
            throw CappyError.transcription("トークン数の応答が不正です")
        }
        return n
    }
}

/// streamGenerateContent?alt=sse の応答（data: 行ごとに GenerateContentResponse）を組み立てる
public struct GeminiStreamParser {
    /// 安全性などの理由で出力が止められた finishReason
    static let blockedReasons: Set<String> = ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII",
                                              "IMAGE_SAFETY", "MODEL_ARMOR"]

    public private(set) var sawEvent = false
    private var model: String
    private var text = ""
    private var finishReason: String?
    private var blockReason: String?
    private var inputTokens: Int?
    private var outputTokens: Int?

    public init(model: String) { self.model = model }

    public mutating func feed(_ line: String) throws {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            return
        }
        if let err = obj["error"] as? [String: Any] {
            throw GoogleAPIError(httpStatus: err["code"] as? Int ?? 500, status: err["status"] as? String,
                                 message: err["message"] as? String ?? "不明なエラー")
        }
        sawEvent = true
        if let v = obj["modelVersion"] as? String, !v.isEmpty { model = v }
        if let fb = obj["promptFeedback"] as? [String: Any], let r = fb["blockReason"] as? String {
            blockReason = r
        }
        if let candidates = obj["candidates"] as? [[String: Any]], let c = candidates.first {
            if let parts = (c["content"] as? [String: Any])?["parts"] as? [[String: Any]] {
                for p in parts where p["thought"] as? Bool != true {
                    if let t = p["text"] as? String { text += t }
                }
            }
            if let r = c["finishReason"] as? String, r != "FINISH_REASON_UNSPECIFIED" { finishReason = r }
        }
        if let u = obj["usageMetadata"] as? [String: Any] {
            if let p = u["promptTokenCount"] as? Int { inputTokens = p }
            let out = (u["candidatesTokenCount"] as? Int ?? 0) + (u["thoughtsTokenCount"] as? Int ?? 0)
            if out > 0 { outputTokens = out }
        }
    }

    public func finish() throws -> SummaryResponse {
        guard sawEvent else { throw CappyError.transcription("要約の応答が空です") }
        // Claude と同じ stop_reason の語彙にそろえる（refusal / max_tokens / end_turn）
        let stop: String
        var category: String?
        if let blockReason {
            stop = "refusal"
            category = blockReason.lowercased()
        } else if let r = finishReason {
            switch r {
            case "STOP": stop = "end_turn"
            case "MAX_TOKENS": stop = "max_tokens"
            case let r where Self.blockedReasons.contains(r):
                stop = "refusal"
                category = r.lowercased()
            default: stop = r.lowercased()
            }
        } else {
            throw GoogleAPIError(httpStatus: 503, status: "incomplete_stream", message: "応答が途中で切れました")
        }
        return SummaryResponse(text: text.trimmingCharacters(in: .whitespacesAndNewlines), model: model,
                               stopReason: stop, refusalCategory: category,
                               inputTokens: inputTokens, outputTokens: outputTokens)
    }
}

/// Vertex AI 共通
public enum VertexAI {
    /// global → aiplatform.googleapis.com、us / eu → マルチリージョン、それ以外 → リージョン
    public static func host(region: String) -> String {
        switch region {
        case "global": return "aiplatform.googleapis.com"
        case "us", "eu": return "aiplatform.\(region).rep.googleapis.com"
        default: return "\(region)-aiplatform.googleapis.com"
        }
    }
}

/// モデル名から呼び出し先（Claude / Gemini）を決める
public enum SummaryModelFamily: String, Sendable {
    case claude, gemini

    public static func of(_ model: String) -> SummaryModelFamily? {
        let m = model.lowercased()
        if m.hasPrefix("claude-") { return .claude }
        if m.hasPrefix("gemini-") { return .gemini }
        return nil
    }

    /// refusal 時の既定の再試行先（Gemini は既定では再試行しない）
    public var defaultFallback: String? {
        switch self {
        case .claude: return "claude-opus-4-8"
        case .gemini: return nil
        }
    }
}

/// Vertex AI 上の Claude と Gemini をモデル名で振り分ける
public struct VertexSummaryClient: SummaryModelClient {
    let claude: SummaryModelClient
    let gemini: SummaryModelClient
    public let location: String

    public var providerName: String { "vertex" }
    public var region: String? { location }

    public init(projectID: String, region: String, auth: AccessTokenProvider,
                transport: HTTPTransport = URLSessionTransport(), retry: RetryPolicy = RetryPolicy()) {
        self.claude = ClaudeVertexClient(projectID: projectID, region: region, auth: auth, transport: transport, retry: retry)
        self.gemini = GeminiVertexClient(projectID: projectID, region: region, auth: auth, transport: transport, retry: retry)
        self.location = region
    }

    func client(for model: String) throws -> SummaryModelClient {
        switch SummaryModelFamily.of(model) {
        case .claude: return claude
        case .gemini: return gemini
        case nil:
            throw CappyError.usage("要約のモデル名が不正です: \(model)（claude- または gemini- で始まる Vertex AI のモデル ID）")
        }
    }

    public func generate(_ request: SummaryRequest, model: String) async throws -> SummaryResponse {
        try await client(for: model).generate(request, model: model)
    }

    public func countTokens(_ request: SummaryRequest, model: String) async throws -> Int {
        try await client(for: model).countTokens(request, model: model)
    }
}
