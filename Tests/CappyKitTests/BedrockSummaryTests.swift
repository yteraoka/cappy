import Foundation
import Testing
@testable import CappyKit

@Suite struct BedrockClaudeClientTests {
    static let creds = StaticAWSCredentials(AWSCredentials(accessKeyID: "AK", secretAccessKey: "SK", sessionToken: "ST"))
    static let request = SummaryRequest(system: "sys", userText: "hello", maxTokens: 32000, effort: "high")

    func client(_ stub: StubTransport, routing: String = "jp", region: String = "ap-northeast-1") -> BedrockClaudeClient {
        BedrockClaudeClient(region: region, routing: routing, credentials: Self.creds, transport: stub, retry: .none)
    }

    @Test func modelIDs() {
        #expect(BedrockClaudeClient.modelID("claude-opus-5-5", routing: "jp") == "jp.anthropic.claude-opus-5-5")
        #expect(BedrockClaudeClient.modelID("claude-opus-5-5", routing: "global") == "global.anthropic.claude-opus-5-5")
        #expect(BedrockClaudeClient.modelID("claude-opus-5-5", routing: "eu-west-2") == "anthropic.claude-opus-5-5")
        #expect(BedrockClaudeClient.modelID("us.anthropic.claude-opus-5-5", routing: "jp") == "us.anthropic.claude-opus-5-5")
        #expect(BedrockClaudeClient.isAWSRegion("ap-northeast-1"))
        #expect(BedrockClaudeClient.isAWSRegion("us-gov-west-1"))
        #expect(!BedrockClaudeClient.isAWSRegion("us-gov"))
        #expect(!BedrockClaudeClient.isAWSRegion("global"))
        #expect(SummaryModelFamily.of("jp.anthropic.claude-opus-5-5") == .claude)
        #expect(SummaryModelFamily.of("anthropic.claude-haiku-5-5") == .claude)
        #expect(SummaryModelFamily.of("amazon.nova-pro") == .bedrockChat)
    }

    @Test func streamsThroughRuntimeMessagesAPI() async throws {
        let stub = StubTransport { _ in HTTPResponse(status: 200, body: Data(ClaudeVertexClientTests.sse.utf8)) }
        let c = client(stub)
        let r = try await c.generate(Self.request, model: "claude-opus-5-5")
        #expect(r.text == "## 概要\n予算を決めた。")
        #expect(r.stopReason == "end_turn")
        #expect(r.inputTokens == 1200)
        #expect(c.providerName == "bedrock")
        #expect(c.region == "jp")

        let call = try #require(stub.calls.first)
        #expect(call.method == "POST")
        #expect(call.url == "https://bedrock-runtime.ap-northeast-1.amazonaws.com/anthropic/v1/messages")
        #expect(call.headers["anthropic-version"] == BedrockClaudeClient.apiVersion)
        #expect(call.headers["X-Amz-Security-Token"] == "ST")
        let auth = try #require(call.headers["Authorization"])
        #expect(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AK/"))
        #expect(auth.contains("/ap-northeast-1/bedrock/aws4_request"))
        #expect(auth.contains("anthropic-version"))
        let body = try #require(try JSONSerialization.jsonObject(with: call.body ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "jp.anthropic.claude-opus-5-5")
        #expect(body["anthropic_version"] == nil)
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_tokens"] as? Int == 32000)
        #expect(body["system"] as? String == "sys")
        #expect((body["thinking"] as? [String: String]) == ["type": "adaptive"])
        #expect((body["output_config"] as? [String: String]) == ["effort": "high"])
    }

    @Test func inRegionRoutingUsesThatRegion() async throws {
        let stub = StubTransport { _ in HTTPResponse(status: 200, body: Data(ClaudeVertexClientTests.sse.utf8)) }
        let c = client(stub, routing: "eu-west-2", region: "ap-northeast-1")
        #expect(c.endpointRegion == "eu-west-2")
        _ = try await c.generate(Self.request, model: "claude-opus-5-5")
        let call = try #require(stub.calls.first)
        #expect(call.url == "https://bedrock-runtime.eu-west-2.amazonaws.com/anthropic/v1/messages")
        let body = try #require(try JSONSerialization.jsonObject(with: call.body ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "anthropic.claude-opus-5-5")
    }

    @Test func refusalIsReported() async throws {
        let sse = """
        data: {"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":10}}}
        data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}},"usage":{"output_tokens":3}}
        data: {"type":"message_stop"}
        """
        let stub = StubTransport { _ in HTTPResponse(status: 200, body: Data(sse.utf8)) }
        let r = try await client(stub).generate(Self.request, model: "claude-opus-5-5")
        #expect(r.stopReason == "refusal")
        #expect(r.refusalCategory == "cyber")
    }

    @Test func permissionErrorHasModelAccessHint() async throws {
        let stub = StubTransport { _ in
            .json(["type": "error", "error": ["type": "permission_error", "message": "anthropic.claude-opus-5-5 is not available for this account."]],
                  status: 403)
        }
        await #expect {
            _ = try await client(stub).generate(Self.request, model: "claude-opus-5-5")
        } throws: { e in
            guard let a = e as? AWSAPIError else { return false }
            let hint = L10n.$override.withValue(.en) { Summarizer.hint(for: a, model: "claude-opus-5-5", region: "jp", provider: "bedrock") } ?? ""
            return a.httpStatus == 403 && a.code == "permission_error" && a.message.contains("not available") && hint.contains("Model access")
        }
        let iam = AWSAPIError(httpStatus: 403, code: "AccessDeniedException", message: "not authorized to perform: bedrock:InvokeModel")
        #expect(Summarizer.bedrockHint(iam, model: "claude-opus-5-5", routing: "jp")?.contains("bedrock:InvokeModel") == true)
        let badID = AWSAPIError(httpStatus: 400, code: "invalid_request_error", message: "The provided model identifier is invalid.")
        #expect(Summarizer.bedrockHint(badID, model: "claude-x", routing: "jp")?.contains("jp.anthropic.claude-x") == true)
        // ストリームの途中のエラーも Bedrock の案内にする
        let stream = GoogleAPIError(httpStatus: 429, status: "rate_limit_error", message: "slow")
        #expect(Summarizer.hint(for: stream, model: "m", region: "jp", provider: "bedrock")?.contains("Bedrock") == true)
    }

    @Test func overloadedIsRetried() async throws {
        let attempts = Counter()
        let stub = StubTransport { _ in
            if attempts.next() == 1 {
                return .json(["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]], status: 529)
            }
            return HTTPResponse(status: 200, body: Data(ClaudeVertexClientTests.sse.utf8))
        }
        var retry = RetryPolicy()
        retry.sleep = { _ in }
        let c = BedrockClaudeClient(region: "ap-northeast-1", routing: "jp", credentials: Self.creds, transport: stub, retry: retry)
        let r = try await c.generate(Self.request, model: "claude-opus-5-5")
        #expect(r.stopReason == "end_turn")
        #expect(stub.calls.count == 2)
    }

    @Test func checkAccessUsesInvalidRequest() async throws {
        let ok = StubTransport { _ in
            .json(["type": "error", "error": ["type": "invalid_request_error", "message": "max_tokens: must be greater than or equal to 1"]], status: 400)
        }
        try await client(ok).checkAccess(model: "claude-opus-5-5", effort: "high")
        let call = try #require(ok.calls.first)
        #expect(call.url == "https://bedrock-runtime.ap-northeast-1.amazonaws.com/anthropic/v1/messages")
        let body = try #require(try JSONSerialization.jsonObject(with: call.body ?? Data()) as? [String: Any])
        #expect(body["max_tokens"] as? Int == 0)
        #expect(body["stream"] == nil)
        #expect(body["model"] as? String == "jp.anthropic.claude-opus-5-5")

        let badID = StubTransport { _ in
            .json(["type": "error", "error": ["type": "invalid_request_error", "message": "The provided model identifier is invalid."]], status: 400)
        }
        await #expect(throws: AWSAPIError.self) { try await client(badID).checkAccess(model: "claude-x", effort: "high") }
        let denied = StubTransport { _ in .json(["type": "error", "error": ["type": "permission_error", "message": "no"]], status: 403) }
        await #expect(throws: AWSAPIError.self) { try await client(denied).checkAccess(model: "claude-opus-5-5", effort: "high") }
    }

    @Test func countTokensUsesMantle() async throws {
        let stub = StubTransport { _ in .json(["input_tokens": 21]) }
        let n = try await client(stub).countTokens(Self.request, model: "claude-opus-5-5")
        #expect(n == 21)
        let call = try #require(stub.calls.first)
        #expect(call.url == "https://bedrock-mantle.ap-northeast-1.api.aws/anthropic/v1/messages/count_tokens")
        #expect(call.headers["Authorization"]?.contains("/ap-northeast-1/bedrock-mantle/aws4_request") == true)
        let body = try #require(try JSONSerialization.jsonObject(with: call.body ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "anthropic.claude-opus-5-5")
        _ = try await client(stub).countTokens(Self.request, model: "global.anthropic.claude-opus-5-5")
        let body2 = try #require(try JSONSerialization.jsonObject(with: stub.calls[1].body ?? Data()) as? [String: Any])
        #expect(body2["model"] as? String == "anthropic.claude-opus-5-5")
    }

    @Test func summaryMarkdownNamesBedrock() {
        let doc = TranscriptDocument(sessionID: "s", name: "n", startedAt: nil, provider: "gemini", model: nil,
                                     language: "ja-JP", mix: false, diarization: [:], segments: [])
        let md = Summarizer.render(body: "本文", doc: doc, meta: SessionMetadata(id: "s", name: "n"),
                                   response: SummaryResponse(text: "本文", model: "claude-opus-5-5", stopReason: "end_turn"),
                                   providerName: "bedrock", notes: [])
        #expect(md.contains("claude-opus-5-5（Amazon Bedrock）"))
    }
}

@Suite struct BedrockSummaryConfigTests {
    func parse(_ text: String) throws -> Profile {
        try CappyConfig.parse(text, path: URL(fileURLWithPath: "/tmp/x.toml")).profile(named: "a")
    }

    @Test func bedrockDefaults() throws {
        let p = try parse("""
        [profiles.a.summary]
        provider = "aws"
        region = "jp"
        """)
        #expect(p.summaryProvider == "aws")
        #expect(p.summary.model == "claude-opus-5-5")
        #expect(p.summary.region == "jp")
        #expect(p.summary.effectiveFallback(for: p.summary.model) == "claude-opus-4-8")
        let v = try parse("[profiles.a.summary]\nprovider = \"google\"\n")
        #expect(v.summary.model == SummarySettings.defaultModel)
    }

    @Test func bedrockRejectsGemini() {
        #expect(throws: CappyError.self) {
            try parse("[profiles.a.summary]\nprovider = \"aws\"\nmodel = \"gemini-4-argon\"\n")
        }
        #expect(throws: CappyError.self) {
            try parse("[profiles.a.summary]\nprovider = \"aws\"\nfallback_model = \"gemini-3.5-flash\"\n")
        }
    }

    @Test func bedrockModelIDsOnlyForBedrock() throws {
        let p = try parse("[profiles.a.summary]\nprovider = \"aws\"\nmodel = \"us.anthropic.claude-opus-5-5\"\n")
        #expect(p.summary.model == "us.anthropic.claude-opus-5-5")
        #expect(throws: CappyError.self) {
            try parse("[profiles.a.summary]\nmodel = \"jp.anthropic.claude-opus-5-5\"\n")
        }
    }
}
