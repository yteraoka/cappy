import Foundation

/// 手元で動かす LLM サーバー（Ollama・LM Studio・llama.cpp の server・mlx-lm の server など）の
/// OpenAI 互換 Chat Completions（`<base_url>/chat/completions`）で要約する。認証はしない
public struct LocalChatClient: SummaryModelClient {
    public let baseURL: URL
    let transport: HTTPTransport
    let retry: RetryPolicy

    public var providerName: String { "local" }
    public var region: String? { baseURL.absoluteString }

    /// サーバーが起動していないときに長く待たせない
    public static let defaultRetry: RetryPolicy = {
        var r = RetryPolicy()
        r.maxAttempts = 2
        return r
    }()

    public init(baseURL: URL, transport: HTTPTransport = URLSessionTransport(), retry: RetryPolicy = LocalChatClient.defaultRetry) {
        self.baseURL = baseURL
        self.transport = transport
        self.retry = retry
    }

    public static func make(baseURL: String, transport: HTTPTransport = URLSessionTransport()) throws -> LocalChatClient {
        guard let url = URL(string: baseURL) else {
            throw CappyError.usage(tr("Invalid summary.base_url: \(baseURL)", ja: "summary.base_url が不正です: \(baseURL)"))
        }
        return LocalChatClient(baseURL: url, transport: transport)
    }

    var chatURL: URL { baseURL.appendingPathComponent("chat/completions") }
    var modelsURL: URL { baseURL.appendingPathComponent("models") }

    /// 思考の深さ（reasoning_effort）は送らない。対応していないサーバー・モデルがあるため
    static func body(_ r: SummaryRequest, model: String) -> [String: Any] {
        [
            "model": model,
            "max_tokens": r.maxTokens,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": [
                ["role": "system", "content": r.system],
                ["role": "user", "content": r.userText],
            ],
        ]
    }

    public func generate(_ request: SummaryRequest, model: String) async throws -> SummaryResponse {
        guard !model.isEmpty else { throw Self.noModelError }
        let body = try JSONSerialization.data(withJSONObject: Self.body(request, model: model), options: [.sortedKeys])
        var req = URLRequest(url: chatURL)
        req.httpMethod = "POST"
        // 長い文字起こしは、最初の出力までに時間がかかる（入力の処理）
        req.timeoutInterval = 1800
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = body
        let request = req
        do {
            return try await retry.run(tr("Summary (\(model))", ja: "要約（\(model)）")) {
                var parser = ChatCompletionsStreamParser(model: model)
                var head = ""
                let resp = try await transport.streamLines(request) { line in
                    if head.utf8.count < 8192 { head += line + "\n" }
                    try parser.feed(line)
                }
                guard resp.status == 200 else {
                    throw Self.httpError(status: resp.status, body: head, model: model, baseURL: baseURL)
                }
                return try parser.finish()
            }
        } catch let e as URLError {
            throw Self.connectionError(e, baseURL: baseURL)
        }
    }

    public func countTokens(_ request: SummaryRequest, model: String) async throws -> Int {
        throw CappyError.usage(tr("Counting tokens is not supported for local models", ja: "手元のモデルのトークン数の確認には対応していません"))
    }

    /// サーバーにつながり、モデルが入っているかを `<base_url>/models` で確かめる（doctor 用）
    public func checkAccess(model: String, effort: String) async throws {
        guard !model.isEmpty else { throw Self.noModelError }
        let ids = try await availableModels()
        guard ids.isEmpty || ids.contains(model) else {
            throw CappyError.usage(tr("The local server does not have the model \(model) (available: \(ids.prefix(10).joined(separator: ", ")))", ja: "手元のサーバーにモデル \(model) がありません（あるもの: \(ids.prefix(10).joined(separator: ", "))）"),
                                   hint: tr("For Ollama, run `ollama pull \(model)`", ja: "Ollama なら `ollama pull \(model)` で入れてください"))
        }
    }

    /// サーバーにあるモデルの ID
    public func availableModels() async throws -> [String] {
        var req = URLRequest(url: modelsURL)
        req.timeoutInterval = 10
        let r: HTTPResponse
        do {
            r = try await transport.send(req)
        } catch let e as URLError {
            throw Self.connectionError(e, baseURL: baseURL)
        }
        guard r.status == 200 else { throw Self.httpError(status: r.status, body: String(decoding: r.body, as: UTF8.self), model: nil, baseURL: baseURL) }
        let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]
        return (obj?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    public static var noModelError: CappyError {
        CappyError.usage(tr("summary.model is not set for provider = \"local\"", ja: "provider = \"local\" の summary.model が設定されていません"),
                         hint: tr("Set the model name on the local server, e.g. model = \"qwen3:30b\" in [profiles.<name>.summary]", ja: "[profiles.<name>.summary] に、手元のサーバーのモデル名を model = \"qwen3:30b\" のように書いてください"))
    }

    static func connectionError(_ e: URLError, baseURL: URL) -> CappyError {
        CappyError.transcription(tr("Cannot connect to the local LLM server (\(baseURL.absoluteString)): \(e.localizedDescription)", ja: "手元の LLM サーバー（\(baseURL.absoluteString)）につながりません: \(e.localizedDescription)"),
                                 hint: tr("Start the server (e.g. `ollama serve`, or the server in LM Studio) and check summary.base_url", ja: "サーバー（`ollama serve` や LM Studio のサーバーなど）を起動し、summary.base_url を確認してください"))
    }

    static func httpError(status: Int, body: String, model: String?, baseURL: URL) -> Error {
        let message = Self.errorMessage(body) ?? String(body.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
        if status >= 500 || status == 429 {
            // 一時的なものとして再試行させる
            return AWSAPIError(httpStatus: status, code: nil, message: message)
        }
        var hint: String?
        if status == 404, let model {
            hint = tr("Check that the model \(model) is on the server (for Ollama, `ollama pull \(model)`) and that summary.base_url ends with /v1",
                      ja: "サーバーにモデル \(model) があるか（Ollama なら `ollama pull \(model)`）と、summary.base_url が /v1 で終わっているかを確認してください")
        }
        return CappyError.transcription(tr("The local LLM server returned an error (HTTP \(status), \(baseURL.absoluteString)): \(message)", ja: "手元の LLM サーバーがエラーを返しました（HTTP \(status)、\(baseURL.absoluteString)）: \(message)"), hint: hint)
    }

    /// {"error": {"message": ...}} / {"error": "..."} から本文を取り出す
    static func errorMessage(_ body: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return nil }
        if let e = obj["error"] as? [String: Any] { return e["message"] as? String }
        return obj["error"] as? String
    }
}
