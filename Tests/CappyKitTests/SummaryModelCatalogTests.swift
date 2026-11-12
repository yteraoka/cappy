import Foundation
import Testing
@testable import CappyKit

@Suite struct SummaryModelCatalogTests {
    static let creds = StaticAWSCredentials(AWSCredentials(accessKeyID: "AK", secretAccessKey: "SK"))

    @Test func vertexListsGeminiAndClaudeTextModels() async throws {
        let stub = StubTransport { call in
            if call.url.contains("/publishers/google/models") {
                if !call.url.contains("pageToken") {
                    return .json(["publisherModels": [
                        ["name": "publishers/google/models/gemini-4-argon", "displayName": "Gemini 4 Argon", "launchStage": "GA"],
                        ["name": "publishers/google/models/gemini-embedding-002"],
                        ["name": "publishers/google/models/gemini-3.5-transcribe"],
                        ["name": "publishers/google/models/gemini-3.5-transcribe-live"],
                        ["name": "publishers/google/models/imagen-5"],
                        ["name": "publishers/google/models/gemini-2.0-flash", "launchStage": "DEPRECATED"],
                    ], "nextPageToken": "p2"])
                }
                return .json(["publisherModels": [["name": "publishers/google/models/gemini-3.5-flash"]]])
            }
            return .json(["publisherModels": [
                ["name": "publishers/anthropic/models/claude-opus-5-5", "displayName": "Claude Opus 5.5"],
                ["name": "publishers/anthropic/models/claude-opus-4-8"],
            ]])
        }
        let list = try await SummaryModelCatalog.listVertex(userProject: "proj", auth: StaticToken(), transport: stub)
        #expect(list.map(\.id) == ["gemini-4-argon", "gemini-3.5-flash", "claude-opus-5-5", "claude-opus-4-8"])
        #expect(list.first?.name == "Gemini 4 Argon")
        #expect(stub.calls.count == 3)
        #expect(stub.calls[0].url.hasPrefix("https://aiplatform.googleapis.com/v1beta1/publishers/google/models?pageSize=100"))
        #expect(stub.calls[1].url.contains("pageToken=p2"))
        #expect(stub.calls[0].headers["Authorization"] == "Bearer test-token")
        #expect(stub.calls[0].headers["x-goog-user-project"] == "proj")
    }

    @Test func vertexErrorIsThrown() async {
        let stub = StubTransport { _ in .json(["error": ["code": 403, "message": "denied", "status": "PERMISSION_DENIED"]], status: 403) }
        await #expect(throws: GoogleAPIError.self) {
            _ = try await SummaryModelCatalog.listVertex(userProject: nil, auth: StaticToken(), transport: stub)
        }
    }

    static func bedrockStub() -> StubTransport {
        StubTransport { call in
            if call.url.contains("/foundation-models") {
                return .json(["modelSummaries": [
                    ["modelId": "anthropic.claude-opus-5-5", "providerName": "Anthropic", "modelName": "Claude Opus 5.5",
                     "outputModalities": ["TEXT"], "inferenceTypesSupported": ["INFERENCE_PROFILE"], "modelLifecycle": ["status": "ACTIVE"]],
                    ["modelId": "moonshotai.kimi-k3.1", "providerName": "Moonshot AI", "modelName": "Kimi K3.1",
                     "outputModalities": ["TEXT"], "inferenceTypesSupported": ["ON_DEMAND", "INFERENCE_PROFILE"], "modelLifecycle": ["status": "ACTIVE"]],
                    ["modelId": "anthropic.claude-3-haiku-20240307-v1:0", "providerName": "Anthropic", "modelName": "Claude 3 Haiku",
                     "outputModalities": ["TEXT"], "inferenceTypesSupported": ["ON_DEMAND"], "modelLifecycle": ["status": "LEGACY"]],
                    ["modelId": "amazon.titan-embed-text-v2:0", "outputModalities": ["EMBEDDING"], "inferenceTypesSupported": ["ON_DEMAND"]],
                ]])
            }
            return .json(["inferenceProfileSummaries": [
                ["inferenceProfileId": "jp.anthropic.claude-opus-5-5", "status": "ACTIVE"],
                ["inferenceProfileId": "global.anthropic.claude-opus-5-5", "status": "ACTIVE"],
                ["inferenceProfileId": "global.moonshotai.kimi-k3.1", "status": "ACTIVE"],
                ["inferenceProfileId": "global.amazon.titan-embed-text-v2:0", "status": "ACTIVE"],
            ]])
        }
    }

    @Test func bedrockInferenceProfilesOfTheScope() async throws {
        let stub = Self.bedrockStub()
        let global = try await SummaryModelCatalog.listBedrock(region: "ap-northeast-1", routing: "global", credentials: Self.creds, transport: stub)
        #expect(global.map(\.id) == ["claude-opus-5-5", "moonshotai.kimi-k3.1"])
        #expect(global[0].name == "Anthropic Claude Opus 5.5")
        #expect(stub.calls[0].url == "https://bedrock.ap-northeast-1.amazonaws.com/foundation-models?byOutputModality=TEXT")
        #expect(stub.calls[1].url.hasPrefix("https://bedrock.ap-northeast-1.amazonaws.com/inference-profiles?typeEquals=SYSTEM_DEFINED"))
        #expect(stub.calls[0].headers["Authorization"]?.contains("/bedrock/aws4_request") == true)

        let jp = try await SummaryModelCatalog.listBedrock(region: "ap-northeast-1", routing: "jp", credentials: Self.creds, transport: Self.bedrockStub())
        #expect(jp.map(\.id) == ["claude-opus-5-5"])
    }

    @Test func bedrockOnDemandModelsInARegion() async throws {
        let stub = Self.bedrockStub()
        let list = try await SummaryModelCatalog.listBedrock(region: "us-east-1", routing: "us-east-1", credentials: Self.creds, transport: stub)
        #expect(list.map(\.id) == ["moonshotai.kimi-k3.1"])
        #expect(stub.calls.count == 1) // 推論プロファイルは取得しない
    }

    @Test func cacheKeyFollowsTheEndpoint() {
        var a = Profile(name: "a")
        a.summary.provider = "aws"
        a.summary.region = "jp"
        var b = a
        b.name = "b"
        #expect(SummaryModelCatalog.cacheKey(for: a) == SummaryModelCatalog.cacheKey(for: b))
        b.summary.region = "global"
        #expect(SummaryModelCatalog.cacheKey(for: a) != SummaryModelCatalog.cacheKey(for: b))
    }
}

@Suite struct RecordLauncherSummaryModelTests {
    private func profile(_ name: String, summary: String = "google", model: String = "gemini-4-argon") -> Profile {
        var p = Profile(name: name)
        p.provider = "google"
        p.summary.provider = summary
        p.summary.model = model
        p.summary.auto = true
        return p
    }

    private let zoom = LaunchTarget(kind: .app("us.zoom.xos"), name: "zoom.us", isPlaying: true, processCount: 1)

    @Test func rowIsShownOnlyWhenSummarizing() {
        var l = RecordLauncher(profiles: [profile("default")])
        #expect(l.operation == .summarize)
        #expect(l.fields == [.profile, .operation, .summaryModel, .mic, .duration, .name])
        _ = l.handle(.home)
        _ = l.handle(.down)
        _ = l.handle(.left) // 録音 → 文字起こし
        #expect(l.operation == .transcribe)
        #expect(l.fields == [.profile, .operation, .mic, .duration, .name])
    }

    @Test func loadsTheListWhenTheRowIsReachedAndChoosesAModel() {
        var l = RecordLauncher(profiles: [profile("default")])
        l.update(targets: [zoom])
        _ = l.handle(.home)
        _ = l.handle(.down)
        _ = l.handle(.down)
        #expect(l.row == .field(.summaryModel))
        guard case .loadModels(let key, let p)? = l.pendingModelLoad() else {
            Issue.record("no load")
            return
        }
        #expect(p.name == "default")
        #expect(l.pendingModelLoad() == nil) // 取得中は 2 回目を出さない
        // 取得中も既定のモデルで始められ、取得中の行は選べない
        #expect(l.handle(.enter) == nil)
        #expect(L10n.$override.withValue(.en) { l.options(for: .summaryModel) }
            == ["gemini-4-argon (profile default)", "Getting the available models…"])
        _ = l.handle(.down)
        _ = l.handle(.enter)
        #expect(l.summaryModel == nil)

        l.setModelList(key: key, .success([SummaryModelOption(id: "gemini-4-argon"), SummaryModelOption(id: "claude-opus-5-5", name: "Claude Opus 5.5"),
                                           SummaryModelOption(id: "gemini-3.5-flash")]))
        #expect(L10n.$override.withValue(.en) { l.options(for: .summaryModel) }
            == ["gemini-4-argon (profile default)", "claude-opus-5-5  (Claude Opus 5.5)", "gemini-3.5-flash"])
        _ = l.handle(.right)
        #expect(l.summaryModel == "claude-opus-5-5")
        #expect(l.arguments(for: zoom) == ["--app", "us.zoom.xos", "--profile", "default", "--transcribe", "--summarize",
                                            "--summary-model", "claude-opus-5-5"])
        let rows = L10n.$override.withValue(.en) { l.summary(for: zoom) }
        #expect(rows.map(\.label) == ["Target", "Profile", "Operation", "Summary model", "Mic"])
        #expect(rows[3].value == "claude-opus-5-5")

        // 要約しない操作にすると渡さない
        _ = l.handle(.up)
        _ = l.handle(.left)
        #expect(l.operation == .transcribe)
        #expect(!l.arguments(for: zoom).contains("--summary-model"))
    }

    @Test func failureCanBeRetried() {
        var l = RecordLauncher(profiles: [profile("default")])
        _ = l.handle(.home)
        _ = l.handle(.down)
        _ = l.handle(.down)
        guard case .loadModels(let key, _)? = l.pendingModelLoad() else {
            Issue.record("no load")
            return
        }
        l.setModelList(key: key, .failure(CappyError.usage("denied")))
        #expect(L10n.$override.withValue(.en) { l.options(for: .summaryModel) }.last == "✗ Cannot get the models: denied")
        // 開き直すと取り直す
        if case .loadModels(_, _)? = l.handle(.enter) {} else { Issue.record("no retry") }
        #expect(l.modelList == .loading)
    }

    @Test func changingTheEndpointResetsTheModel() {
        var other = profile("bedrock", summary: "aws", model: "claude-opus-5-5")
        other.summary.region = "jp"
        var l = RecordLauncher(profiles: [profile("default"), other])
        _ = l.handle(.home)
        _ = l.handle(.down)
        _ = l.handle(.down)
        guard case .loadModels(let key, _)? = l.pendingModelLoad() else {
            Issue.record("no load")
            return
        }
        l.setModelList(key: key, .success([SummaryModelOption(id: "gemini-3.5-flash")]))
        _ = l.handle(.right)
        #expect(l.summaryModel == "gemini-3.5-flash")
        _ = l.handle(.home)
        _ = l.handle(.right) // プロファイル → bedrock
        #expect(l.profile.name == "bedrock")
        #expect(l.summaryModel == nil)
        #expect(l.effectiveSummaryModel == "claude-opus-5-5")
    }
}
