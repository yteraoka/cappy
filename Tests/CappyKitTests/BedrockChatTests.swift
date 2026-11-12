import Foundation
import Testing
@testable import CappyKit

@Suite struct BedrockModelsTests {
    @Test func families() {
        #expect(SummaryModelFamily.of("moonshotai.kimi-k3.1") == .bedrockChat)
        #expect(SummaryModelFamily.of("global.zai.glm-5.3") == .bedrockChat)
        #expect(SummaryModelFamily.of("claude-opus-5-5") == .claude)
        #expect(SummaryModelFamily.of("jp.anthropic.claude-opus-5-5") == .claude)
        #expect(SummaryModelFamily.of("gemini-3.5-flash") == .gemini)
        #expect(SummaryModelFamily.of("kimi") == nil)
        #expect(SummaryModelFamily.bedrockChat.defaultFallback == nil)
    }

    @Test func modelIDs() {
        #expect(BedrockModels.modelID("moonshotai.kimi-k3.1", routing: "global") == "global.moonshotai.kimi-k3.1")
        #expect(BedrockModels.modelID("moonshotai.kimi-k3.1", routing: "jp") == "jp.moonshotai.kimi-k3.1")
        #expect(BedrockModels.modelID("global.zai.glm-5.3", routing: "jp") == "global.zai.glm-5.3")
        #expect(BedrockModels.modelID("zai.glm-5.3", routing: "us-east-1") == "zai.glm-5.3")
        #expect(BedrockModels.modelID("claude-opus-5-5", routing: "jp") == "jp.anthropic.claude-opus-5-5")
        #expect(BedrockModels.modelID("claude-opus-5-5", routing: "eu-west-2") == "anthropic.claude-opus-5-5")
        #expect(BedrockModels.modelID("us.anthropic.claude-opus-5-5", routing: "jp") == "us.anthropic.claude-opus-5-5")
    }
}

@Suite struct ChatCompletionsStreamParserTests {
    /// 実際の Kimi K3.1 の応答（Bedrock、2026-11-12）を短くしたもの
    static let sse = """
    data: {"choices":[{"delta":{"content":"","role":"assistant","refusal":null},"finish_reason":null,"index":0}],"model":"global.moonshotai.kimi-k3.1","object":"chat.completion.chunk","usage":null}

    data: {"choices":[{"delta":{"reasoning_content":"ユーザーは"},"finish_reason":null,"index":0}],"model":"global.moonshotai.kimi-k3.1","usage":null}

    data: {"choices":[{"delta":{"content":"## 概要\\n"},"finish_reason":null,"index":0}],"model":"global.moonshotai.kimi-k3.1","usage":null}

    data: {"choices":[{"delta":{"content":"予算を決めた。"},"finish_reason":null,"index":0}],"model":"global.moonshotai.kimi-k3.1","usage":null}

    data: {"choices":[{"delta":{},"finish_reason":"stop","index":0}],"model":"global.moonshotai.kimi-k3.1","usage":null}

    data: {"choices":[],"model":"global.moonshotai.kimi-k3.1","usage":{"completion_tokens":92,"completion_tokens_details":{"reasoning_tokens":70},"prompt_tokens":109,"total_tokens":201}}

    data: [DONE]

    """

    @Test func textUsageAndStop() throws {
        var p = ChatCompletionsStreamParser(model: "m")
        for line in Self.sse.components(separatedBy: "\n") { try p.feed(line) }
        let r = try p.finish()
        #expect(r.text == "## 概要\n予算を決めた。")
        #expect(r.stopReason == "end_turn")
        #expect(r.inputTokens == 109)
        #expect(r.outputTokens == 92)
        #expect(r.model == "global.moonshotai.kimi-k3.1")
    }

    @Test func stopReasons() {
        #expect(ChatCompletionsStreamParser.stopReason("length", refused: false) == "max_tokens")
        #expect(ChatCompletionsStreamParser.stopReason("content_filter", refused: false) == "refusal")
        #expect(ChatCompletionsStreamParser.stopReason("stop", refused: true) == "refusal")
    }

    @Test func refusalAndErrors() throws {
        var p = ChatCompletionsStreamParser(model: "m")
        try p.feed(#"data: {"choices":[{"delta":{"refusal":"I can't help with that."},"finish_reason":"stop","index":0}]}"#)
        try p.feed("data: [DONE]")
        let r = try p.finish()
        #expect(r.stopReason == "refusal")
        #expect(r.refusalCategory == "I can't help with that.")

        var e = ChatCompletionsStreamParser(model: "m")
        #expect(throws: AWSAPIError.self) {
            try e.feed(#"data: {"error":{"type":"rate_limit_error","message":"slow down"}}"#)
        }
        var cut = ChatCompletionsStreamParser(model: "m")
        try cut.feed(#"data: {"choices":[{"delta":{"content":"途中"},"finish_reason":null,"index":0}]}"#)
        #expect(throws: AWSAPIError.self) { _ = try cut.finish() }
        #expect(throws: CappyError.self) { _ = try ChatCompletionsStreamParser(model: "m").finish() }
    }
}

@Suite struct BedrockChatClientTests {
    static let creds = StaticAWSCredentials(AWSCredentials(accessKeyID: "AK", secretAccessKey: "SK"))
    static let request = SummaryRequest(system: "sys", userText: "hello", maxTokens: 32000, effort: "high")

    @Test func generateUsesChatCompletions() async throws {
        let stub = StubTransport { _ in HTTPResponse(status: 200, body: Data(ChatCompletionsStreamParserTests.sse.utf8)) }
        let c = BedrockChatClient(region: "ap-northeast-1", routing: "global", credentials: Self.creds, transport: stub, retry: .none)
        let r = try await c.generate(Self.request, model: "moonshotai.kimi-k3.1")
        #expect(r.text.hasPrefix("## 概要"))
        let call = try #require(stub.calls.first)
        #expect(call.url == "https://bedrock-runtime.ap-northeast-1.amazonaws.com/openai/v1/chat/completions")
        #expect(call.headers["Authorization"]?.contains("/ap-northeast-1/bedrock/aws4_request") == true)
        let body = try #require(try JSONSerialization.jsonObject(with: call.body ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "global.moonshotai.kimi-k3.1")
        #expect(body["reasoning_effort"] as? String == "high")
        #expect(body["max_tokens"] as? Int == 32000)
        #expect(body["stream"] as? Bool == true)
        #expect((body["stream_options"] as? [String: Bool]) == ["include_usage": true])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "sys"], ["role": "user", "content": "hello"]])
    }

    @Test func checkAccess() async throws {
        func client(_ status: Int, _ obj: [String: Any]) -> BedrockChatClient {
            let resp = HTTPResponse.json(obj, status: status)
            return BedrockChatClient(region: "ap-northeast-1", routing: "global", credentials: Self.creds,
                                     transport: StubTransport { _ in resp }, retry: .none)
        }
        // 実際の応答: 権限があれば max_tokens の検証エラー
        try await client(400, ["error": ["type": "invalid_request_error", "code": "integer_below_min_value",
                                         "message": "Invalid 'max_tokens': integer below minimum value."]])
            .checkAccess(model: "moonshotai.kimi-k3.1", effort: "high")
        await #expect(throws: AWSAPIError.self) {
            try await client(403, ["error": ["type": "permission_denied_error", "message": "zai.glm-5.3 is not available for this account."]])
                .checkAccess(model: "zai.glm-5.3", effort: "high")
        }
        await #expect(throws: AWSAPIError.self) {
            try await client(400, ["error": ["type": "invalid_request_error",
                                             "message": "Invocation of model ID moonshotai.kimi-k3.1 with on-demand throughput isn’t supported. Retry your request with the ID or ARN of an inference profile that contains this model."]])
                .checkAccess(model: "moonshotai.kimi-k3.1", effort: "high")
        }
        let denied = AWSAPIError(httpStatus: 403, code: "permission_denied_error", message: "no")
        L10n.$override.withValue(.en) {
            #expect(Summarizer.bedrockHint(denied, model: "zai.glm-5.3", routing: "global")?.contains("Model access") == true)
        }
        L10n.$override.withValue(.ja) {
            #expect(Summarizer.bedrockHint(denied, model: "zai.glm-5.3", routing: "global")?.contains("モデルアクセス") == true)
        }
        let badID = AWSAPIError(httpStatus: 400, code: "invalid_request_error", message: "The provided model identifier is invalid.")
        #expect(Summarizer.bedrockHint(badID, model: "moonshotai.kimi-k3.1", routing: "jp")?.contains("global") == true)
    }

    @Test func routerDispatchesByModel() async throws {
        let stub = StubTransport { call in
            call.url.hasSuffix("/openai/v1/chat/completions")
                ? HTTPResponse(status: 200, body: Data(ChatCompletionsStreamParserTests.sse.utf8))
                : HTTPResponse(status: 200, body: Data(ClaudeVertexClientTests.sse.utf8))
        }
        let c = BedrockSummaryClient(region: "ap-northeast-1", routing: "jp", credentials: Self.creds, transport: stub, retry: .none)
        _ = try await c.generate(Self.request, model: "global.moonshotai.kimi-k3.1")
        _ = try await c.generate(Self.request, model: "claude-opus-5-5")
        #expect(stub.calls.map(\.url) == ["https://bedrock-runtime.ap-northeast-1.amazonaws.com/openai/v1/chat/completions",
                                          "https://bedrock-runtime.ap-northeast-1.amazonaws.com/anthropic/v1/messages"])
        await #expect(throws: CappyError.self) { _ = try await c.generate(Self.request, model: "gemini-3.5-flash") }
    }

    @Test func config() throws {
        func parse(_ t: String) throws -> Profile {
            try CappyConfig.parse(t, path: URL(fileURLWithPath: "/tmp/x.toml")).profile(named: "a")
        }
        let p = try parse("[profiles.a.summary]\nprovider = \"aws\"\nmodel = \"global.moonshotai.kimi-k3.1\"\n")
        #expect(p.summary.model == "global.moonshotai.kimi-k3.1")
        #expect(p.summary.effectiveFallback(for: p.summary.model) == nil)
        let q = try parse("[profiles.a.summary]\nprovider = \"aws\"\nmodel = \"zai.glm-5.3\"\nfallback_model = \"global.moonshotai.kimi-k3.1\"\n")
        #expect(q.summary.effectiveFallback(for: q.summary.model) == "global.moonshotai.kimi-k3.1")
        #expect(throws: CappyError.self) { try parse("[profiles.a.summary]\nmodel = \"moonshotai.kimi-k3.1\"\n") }
    }
}
