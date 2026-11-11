import Foundation

/// Amazon Bedrock の Claude（Claude Opus 4.7 以降）を、bedrock-runtime の Anthropic 形式の Messages API で呼ぶ。
///
/// - URL: `https://bedrock-runtime.<region>.amazonaws.com/anthropic/v1/messages`（SigV4 のサービス名は `bedrock`）
/// - 本文は Messages API と同じで、`model` に推論プロファイルの ID（`jp.anthropic.claude-opus-5-5` など）を入れる
/// - 推論プロファイル（global / jp / us / eu など）が使えるのは bedrock-runtime だけ（bedrock-mantle は単一リージョンのみ）
public struct BedrockClaudeClient: SummaryModelClient {
    public static let apiVersion = ClaudeVertexClient.apiVersion

    /// 呼び出し先のリージョン（推論プロファイルの送信元リージョン）
    public let endpointRegion: String
    /// global / us / eu / jp / au / apac などの推論プロファイルの範囲、またはリージョン名（そのリージョンだけで処理）
    public let routing: String
    let credentials: AWSCredentialsSource
    let transport: HTTPTransport
    let retry: RetryPolicy

    public var providerName: String { "bedrock" }
    public var region: String? { routing }

    /// routing がリージョン名なら、そのリージョンのエンドポイントを使う（推論プロファイルを使わない）
    public init(region awsRegion: String, routing: String, credentials: AWSCredentialsSource,
                transport: HTTPTransport = URLSessionTransport(), retry: RetryPolicy = RetryPolicy()) {
        self.endpointRegion = Self.isAWSRegion(routing) ? routing : awsRegion
        self.routing = routing
        self.credentials = credentials
        self.transport = transport
        self.retry = retry
    }

    /// `ap-northeast-1` のようなリージョン名か（`jp` などの推論プロファイルの範囲と区別する）
    public static func isAWSRegion(_ s: String) -> Bool {
        s.range(of: #"^[a-z]{2}(-gov|-iso[a-z]*)?-[a-z]+-[0-9]+$"#, options: .regularExpression) != nil
    }

    /// cappy のモデル名（claude-opus-5-5）を Bedrock のモデル ID にする。すでに Bedrock の ID ならそのまま
    public static func modelID(_ model: String, routing: String) -> String {
        BedrockModels.modelID(model, routing: routing)
    }

    public var endpoint: URL {
        URL(string: "https://bedrock-runtime.\(endpointRegion).amazonaws.com/anthropic/v1/messages")!
    }

    func makeRequest(url: URL, body: Data, stream: Bool) async throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // 思考中はイベントが途切れることがあるため、無通信タイムアウトを長めにする
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if stream { req.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        req.httpBody = body
        let creds = try await credentials.credentials()
        SigV4Signer(credentials: creds, region: endpointRegion, service: "bedrock").sign(&req)
        return req
    }

    static func messagesBody(_ r: SummaryRequest, modelID: String) -> [String: Any] {
        var body = ClaudeVertexClient.messagesBody(r)
        body.removeValue(forKey: "anthropic_version")
        body["model"] = modelID
        return body
    }

    public func generate(_ request: SummaryRequest, model: String) async throws -> SummaryResponse {
        let id = Self.modelID(model, routing: routing)
        let body = try JSONSerialization.data(withJSONObject: Self.messagesBody(request, modelID: id), options: [.sortedKeys])
        return try await retry.run(tr("Summary (\(id))", ja: "要約（\(id)）")) {
            // 認証情報が更新されることがあるため、試行ごとに署名する
            let req = try await makeRequest(url: endpoint, body: body, stream: true)
            var parser = ClaudeStreamParser(model: model)
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

    /// bedrock-runtime には新しい Claude のトークン数の確認がないため、bedrock-mantle の count_tokens を使う
    /// （bedrock-mantle は推論プロファイルに未対応で、モデルとリージョンの組み合わせによっては使えない）
    public func countTokens(_ request: SummaryRequest, model: String) async throws -> Int {
        let bare = Self.modelID(model, routing: endpointRegion)
            .replacingOccurrences(of: #"^[a-z-]+\.anthropic\."#, with: "anthropic.", options: .regularExpression)
        let url = URL(string: "https://bedrock-mantle.\(endpointRegion).api.aws/anthropic/v1/messages/count_tokens")!
        let body = try JSONSerialization.data(withJSONObject: [
            "model": bare,
            "system": request.system,
            "messages": [["role": "user", "content": request.userText]],
        ] as [String: Any], options: [.sortedKeys])
        let resp = try await retry.run(tr("Counting tokens", ja: "トークン数の確認")) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
            req.httpBody = body
            SigV4Signer(credentials: try await credentials.credentials(), region: endpointRegion, service: "bedrock-mantle").sign(&req)
            let r = try await transport.send(req)
            guard r.status == 200 else { throw AWSAPIError.from(r) }
            return r
        }
        guard let obj = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              let n = obj["input_tokens"] as? Int else {
            throw CappyError.transcription(tr("Invalid token count response", ja: "トークン数の応答が不正です"))
        }
        return n
    }

    /// モデルを使えるかを、課金されない方法で確かめる。
    /// bedrock-runtime はモデルの利用権限を本文の検証より先に確かめるため、わざと不正な本文（max_tokens = 0）を送り、
    /// 403（permission_error）やモデル ID の誤り以外の 400 が返れば使えると判断する
    public func checkAccess(model: String, effort: String) async throws {
        let id = Self.modelID(model, routing: routing)
        let body = try JSONSerialization.data(withJSONObject: [
            "model": id, "max_tokens": 0, "messages": [["role": "user", "content": "ping"]],
        ] as [String: Any], options: [.sortedKeys])
        let resp = try await retry.run(tr("Checking the model", ja: "モデルの確認")) {
            let r = try await transport.send(try await makeRequest(url: endpoint, body: body, stream: false))
            if r.status >= 500 || r.status == 429 { throw AWSAPIError.from(r) }
            return r
        }
        if resp.status == 200 { return }
        let e = AWSAPIError.from(resp)
        if resp.status == 400 && !Self.isModelIdentifierError(e) { return }
        throw e
    }

    static func isModelIdentifierError(_ e: AWSAPIError) -> Bool {
        let m = e.message.lowercased()
        return m.contains("model identifier") || m.contains("model id") || m.contains("inference profile")
    }
}
