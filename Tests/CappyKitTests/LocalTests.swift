import Foundation
import Testing
@testable import CappyKit

/// 決まった結果を返す偽の端末内認識
struct FakeRecognizer: LocalRecognizer {
    var pieces: [RecognizedPiece]
    var name: String { "whisperkit" }
    var model: String? { "fake" }
    func recognize(_ audio: URL, language: String, vocabulary: [String]) async throws -> [RecognizedPiece] { pieces }
}

struct FakeDiarizer: LocalDiarizer {
    var turns: [SpeakerTurn]
    var fail = false
    func diarize(_ audio: URL, numSpeakers: Int?) async throws -> [SpeakerTurn] {
        if fail { throw CappyError.transcription("diarization failed") }
        return turns
    }
}

@Suite struct LocalTranscriptionTests {
    @Test func assignsSpeakersByOverlap() {
        let pieces = [RecognizedPiece(startMs: 0, endMs: 2000, text: " こんにちは "),
                      RecognizedPiece(startMs: 2000, endMs: 5000, text: "よろしくお願いします"),
                      RecognizedPiece(startMs: 9000, endMs: 9500, text: "はい"),
                      RecognizedPiece(startMs: 20000, endMs: 21000, text: "遠い"),
                      RecognizedPiece(startMs: 30000, endMs: 31000, text: "  ")]
        let turns = [SpeakerTurn(speaker: "spk_0", startMs: 0, endMs: 2500),
                     SpeakerTurn(speaker: "spk_1", startMs: 2500, endMs: 8000),
                     SpeakerTurn(speaker: "spk_0", startMs: 10000, endMs: 12000)]
        let segs = LocalTranscriptionProvider.assemble(pieces, turns: turns, track: .remote, offsetMs: 100)
        #expect(segs.map(\.text) == ["こんにちは", "よろしくお願いします", "はい", "遠い"])
        #expect(segs.map(\.speaker) == ["spk_0", "spk_1", "spk_0", nil])
        #expect(segs[0].startMs == 100)
        #expect(segs[1].endMs == 5100)
        // 話者分離がなければ話者なし
        #expect(LocalTranscriptionProvider.assemble(pieces, turns: [], track: .mic, offsetMs: 0).allSatisfy { $0.speaker == nil })
    }

    func track(_ id: TrackID) throws -> AudioTrack {
        let dir = try TestSupport.tempDir()
        let url = dir.appendingPathComponent("\(id.rawValue).flac")
        try Data().write(to: url)
        return AudioTrack(id: id, url: url, offsetMs: 0, durationMs: 10_000, sessionID: "s")
    }

    @Test func submitWritesResultAndCleansUp() async throws {
        let provider = LocalTranscriptionProvider(
            recognizer: FakeRecognizer(pieces: [RecognizedPiece(startMs: 0, endMs: 1000, text: "あ"),
                                                RecognizedPiece(startMs: 3000, endMs: 4000, text: "い")]),
            diarizer: FakeDiarizer(turns: [SpeakerTurn(speaker: "spk_0", startMs: 0, endMs: 1500),
                                           SpeakerTurn(speaker: "spk_1", startMs: 2900, endMs: 4200)]),
            settings: LocalTranscribeSettings())
        let t = try track(.remote)
        let handle = try await provider.submit(t, options: TranscriptionOptions(language: "ja-JP", diarization: true))
        #expect(handle.provider == "whisperkit")
        #expect(handle.info["diarization"] == "true")
        #expect(try await provider.status(of: handle) == .done)
        let segs = try await provider.result(of: handle)
        #expect(segs.map(\.speaker) == ["spk_0", "spk_1"])
        try await provider.cleanup(handle)
        #expect(!FileManager.default.fileExists(atPath: handle.info["file"]!))
        guard case .failed = try await provider.status(of: handle) else { Issue.record("failed ではありません"); return }
    }

    @Test func diarizationFailureFallsBackToNoSpeakers() async throws {
        let provider = LocalTranscriptionProvider(
            recognizer: FakeRecognizer(pieces: [RecognizedPiece(startMs: 0, endMs: 1000, text: "あ")]),
            diarizer: FakeDiarizer(turns: [], fail: true), settings: LocalTranscribeSettings())
        let handle = try await provider.submit(try track(.remote), options: TranscriptionOptions(language: "ja-JP", diarization: true))
        #expect(handle.info["diarization"] == "false")
        #expect(handle.info["diarization_note"] != nil)
        #expect(try await provider.result(of: handle).map(\.speaker) == [nil])
    }

    @Test func micIsNotDiarized() async throws {
        let provider = LocalTranscriptionProvider(
            recognizer: FakeRecognizer(pieces: [RecognizedPiece(startMs: 0, endMs: 1000, text: "あ")]),
            diarizer: FakeDiarizer(turns: [SpeakerTurn(speaker: "spk_0", startMs: 0, endMs: 1000)]), settings: LocalTranscribeSettings())
        let handle = try await provider.submit(try track(.mic), options: TranscriptionOptions(language: "ja-JP", diarization: false))
        #expect(handle.info["diarization"] == "false")
        #expect(try await provider.result(of: handle).map(\.speaker) == [nil])
    }

    @Test func whisperHelpers() {
        #expect(WhisperKitRecognizer.whisperLanguage("ja-JP") == "ja")
        #expect(WhisperKitRecognizer.whisperLanguage("en") == "en")
        #expect(WhisperKitRecognizer.clean("<|startoftranscript|><|ja|> こんにちは<|0.00|>") == "こんにちは")
    }

    @Test func configForLocalProfiles() throws {
        let c = try CappyConfig.parse("""
        [profiles.w.transcribe]
        provider = "local"
        whisper_model = "large-v3-v20240930_turbo"
        model_dir = "~/models"
        num_speakers = 3
        diarization = false
        custom_vocabulary = ["cappy"]

        [profiles.w.summary]
        base_url = "http://localhost:1234/v1"
        model = "qwen3:30b"

        [profiles.a.transcribe]
        provider = "local"
        model = "apple"

        [profiles.g.summary]
        provider = "local"
        """, path: URL(fileURLWithPath: "/tmp/c.toml"))
        let w = try c.profile(named: "w")
        #expect(w.transcriptionService == .whisperKit)
        #expect(w.transcriptionService.isLocal)
        #expect(w.local.engine == .whisperKit)
        #expect(w.local.whisperModel == "large-v3-v20240930_turbo")
        #expect(w.local.modelDir == "~/models")
        #expect(w.local.numSpeakers == 3)
        #expect(!w.local.diarization)
        #expect(w.local.customVocabulary == ["cappy"])
        #expect(w.summaryProvider == "local")
        #expect(w.summary.baseURL == "http://localhost:1234/v1")
        #expect(w.summary.model == "qwen3:30b")
        let a = try c.profile(named: "a")
        #expect(a.transcriptionService == .apple)
        #expect(a.local.engine == .apple)
        #expect(a.summaryProvider == "local")
        // 手元のサーバーのモデルは既定がない
        #expect(a.summary.model == "")
        #expect(try c.profile(named: "g").summary.baseURL == SummarySettings.defaultLocalBaseURL)
        #expect(Profile.transcriptionService(provider: "local", model: nil) == .whisperKit)

        #expect(throws: CappyError.self) {
            _ = try CappyConfig.parse("[profiles.p.transcribe]\nprovider = \"local\"\nmodel = \"chirp_3\"\n", path: URL(fileURLWithPath: "/tmp/c.toml"))
        }
        #expect(throws: CappyError.self) {
            _ = try CappyConfig.parse("[profiles.p.transcribe]\nprovider = \"local\"\nnum_speakers = 0\n", path: URL(fileURLWithPath: "/tmp/c.toml"))
        }
        #expect(throws: CappyError.self) {
            _ = try CappyConfig.parse("[profiles.p.summary]\nprovider = \"local\"\nbase_url = \"localhost\"\n", path: URL(fileURLWithPath: "/tmp/c.toml"))
        }
    }
}

@Suite struct LocalChatClientTests {
    static let sse = """
    data: {"id":"1","model":"qwen3:30b","choices":[{"index":0,"delta":{"role":"assistant","content":"## 概要"}}]}

    data: {"id":"1","model":"qwen3:30b","choices":[{"index":0,"delta":{"content":"\\n本文"},"finish_reason":"stop"}]}

    data: {"id":"1","model":"qwen3:30b","choices":[],"usage":{"prompt_tokens":1200,"completion_tokens":30}}

    data: [DONE]

    """

    @Test func generatesFromChatCompletions() async throws {
        let transport = StubTransport { _ in HTTPResponse(status: 200, body: Data(Self.sse.utf8)) }
        let client = LocalChatClient(baseURL: URL(string: "http://localhost:11434/v1")!, transport: transport, retry: .none)
        let r = try await client.generate(SummaryRequest(system: "sys", userText: "user", maxTokens: 4096, effort: "high"), model: "qwen3:30b")
        #expect(r.text == "## 概要\n本文")
        #expect(r.stopReason == "end_turn")
        #expect(r.inputTokens == 1200)
        let call = transport.calls[0]
        #expect(call.url == "http://localhost:11434/v1/chat/completions")
        let body = try JSONSerialization.jsonObject(with: call.body!) as! [String: Any]
        #expect(body["model"] as? String == "qwen3:30b")
        #expect(body["stream"] as? Bool == true)
        #expect(body["reasoning_effort"] == nil)
        #expect(call.headers["Authorization"] == nil)
    }

    @Test func reportsErrors() async throws {
        let notFound = StubTransport { _ in .json(["error": ["message": "model \"x\" not found"]], status: 404) }
        let client = LocalChatClient(baseURL: URL(string: "http://localhost:11434/v1")!, transport: notFound, retry: .none)
        do {
            _ = try await client.generate(SummaryRequest(system: "s", userText: "u", maxTokens: 1024, effort: "low"), model: "x")
            Issue.record("エラーになりません")
        } catch let e as CappyError {
            #expect(e.message.contains("HTTP 404"))
            #expect(e.message.contains("not found"))
            #expect(e.hint?.contains("ollama pull x") == true)
        }
        await #expect(throws: CappyError.self) {
            _ = try await client.generate(SummaryRequest(system: "s", userText: "u", maxTokens: 1024, effort: "low"), model: "")
        }
    }

    @Test func checksModels() async throws {
        let transport = StubTransport { _ in .json(["object": "list", "data": [["id": "qwen3:30b"], ["id": "gpt-oss:20b"]]]) }
        let client = LocalChatClient(baseURL: URL(string: "http://localhost:11434/v1")!, transport: transport, retry: .none)
        try await client.checkAccess(model: "qwen3:30b", effort: "high")
        #expect(transport.calls[0].url == "http://localhost:11434/v1/models")
        await #expect(throws: CappyError.self) { try await client.checkAccess(model: "llama", effort: "high") }
    }

    @Test func factoryMakesLocalClient() throws {
        var p = Profile(name: "x")
        p.provider = "local"
        p.summary.baseURL = "http://127.0.0.1:1234/v1"
        let client = try SummaryClientFactory.make(profile: p)
        #expect(client.providerName == "local")
        #expect((client as? LocalChatClient)?.baseURL.absoluteString == "http://127.0.0.1:1234/v1")
    }
}
