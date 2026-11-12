import Foundation
import Testing
@testable import CappyKit

@Suite struct GeminiConfigTests {
    func parse(_ toml: String) throws -> Profile {
        try CappyConfig.parse(toml, path: URL(fileURLWithPath: "/tmp/c.toml")).profile(named: "default")
    }

    @Test func defaultsToGeminiOnGlobal() throws {
        let p = try parse("[profiles.default.google]\nproject_id = \"p1\"\nbucket = \"b1\"")
        #expect(p.provider == "google")
        #expect(p.transcriptionService == .gemini)
        #expect(p.gemini.model == "gemini-3.5-transcribe")
        #expect(p.gemini.liveModel == "gemini-3.5-transcribe-live")
        #expect(p.gemini.location == "global")
        #expect(p.gemini.chunkMinutes == 14)
        #expect(p.google.projectID == "p1")
        #expect(Profile(name: "x").transcriptionService == .gemini)
    }

    @Test func parsesGeminiSection() throws {
        let p = try parse("""
        [profiles.default.transcribe]
        provider = "google"
        model = "gemini-3.5-transcribe"
        location = "us"
        chunk_minutes = 10
        diarization = false
        custom_vocabulary = ["cappy", "Vertex AI"]
        """)
        #expect(p.gemini.location == "us")
        #expect(p.gemini.chunkSeconds == 600)
        #expect(!p.gemini.diarization)
        #expect(p.gemini.customVocabulary == ["cappy", "Vertex AI"])
        #expect(throws: CappyError.self) { _ = try parse("[profiles.default.transcribe]\nchunk_minutes = 20") }
        #expect(throws: CappyError.self) { _ = try parse("[profiles.default.transcribe]\ncustom_vocabulary = [1, 2]") }
        // Speech-to-Text はモデルで選ぶ
        #expect(try parse("[profiles.default.transcribe]\nmodel = \"chirp_3\"").transcriptionService == .speech)
    }
}

@Suite struct GeminiTranscriptParserTests {
    @Test func partsWithSpeakersAndWords() throws {
        let response: [String: Any] = [
            "candidates": [[
                "finishReason": "STOP",
                "content": ["role": "model", "parts": [
                    ["text": "考え中", "thought": true],
                    ["text": "こんにちは。", "audioTranscription": [
                        "speakerLabel": "spk_1",
                        "words": [["word": "こんにちは。", "startOffset": "1.200s", "endOffset": "2s"]],
                    ]],
                    ["text": "よろしくお願いします", "audioTranscription": [
                        "speakerLabel": "spk_2", "startOffset": "3s", "endOffset": "4.5s",
                    ]],
                ]],
            ]],
        ]
        let segs = try GeminiTranscriptParser.segments(response: response, track: .remote, offsetMs: 60_000,
                                                       chunkDurationMs: 840_000, language: "ja-JP")
        #expect(segs.count == 2)
        #expect(segs[0] == Segment(track: .remote, speaker: "spk_1", startMs: 61_200, endMs: 62_000, text: "こんにちは。", confidence: nil))
        #expect(segs[1].speaker == "spk_2" && segs[1].startMs == 63_000 && segs[1].endMs == 64_500)
    }

    @Test func longPartIsSplitAtSentences() throws {
        // 40 秒の発言（4 秒ごとに句点のある単語）
        var words: [[String: Any]] = []
        for i in 0..<10 {
            words.append(["word": "文\(i)。", "startOffset": "\(i * 4)s", "endOffset": "\(i * 4 + 3)s"])
        }
        let response: [String: Any] = ["candidates": [["content": ["parts": [
            ["text": "長い発言", "audioTranscription": ["words": words]],
        ]]]]]
        let segs = try GeminiTranscriptParser.segments(response: response, track: .mic, offsetMs: 0,
                                                       chunkDurationMs: 60_000, language: "ja-JP")
        #expect(segs.count > 1)
        #expect(segs.allSatisfy { $0.endMs - $0.startMs <= 30_000 })
        #expect(segs.map(\.text).joined() == (0..<10).map { "文\($0)。" }.joined())
    }

    @Test func untimedPartsAreSpreadOverChunk() throws {
        let response: [String: Any] = ["candidates": [["content": ["parts": [
            ["text": "あいう"], ["text": "えお"],
        ]]]]]
        let segs = try GeminiTranscriptParser.segments(response: response, track: .mic, offsetMs: 1_000,
                                                       chunkDurationMs: 10_000, language: "ja-JP")
        #expect(segs.map(\.startMs) == [1_000, 7_000])
        #expect(segs.map(\.endMs) == [7_000, 11_000])
    }

    @Test func blockedResponseThrows() {
        #expect(throws: CappyError.self) {
            _ = try GeminiTranscriptParser.segments(response: ["promptFeedback": ["blockReason": "SAFETY"]], track: .mic,
                                                    offsetMs: 0, chunkDurationMs: 1, language: "ja-JP")
        }
    }
}

@Suite struct GeminiTranscribeProviderTests {
    /// 送信用ファイル（16 kHz・モノラル）を作る
    func makeTrack(seconds: Double) throws -> AudioTrack {
        let dir = try TestSupport.tempDir()
        let caf = dir.appendingPathComponent("remote.caf")
        try TestSupport.writeSineCAF(caf, seconds: seconds, sampleRate: 16_000, channels: 1)
        let r = try SendFileConverter.convert(input: caf, outputBase: dir.appendingPathComponent("remote"))
        return AudioTrack(id: .remote, url: r.url, offsetMs: 0, durationMs: r.durationMs, sessionID: "sid")
    }

    static func transcript(_ text: String, at seconds: Int) -> HTTPResponse {
        .json(["candidates": [["finishReason": "STOP", "content": ["parts": [
            ["text": text, "audioTranscription": ["speakerLabel": "spk_1", "startOffset": "\(seconds)s", "endOffset": "\(seconds + 1)s"]],
        ]]]]])
    }

    func provider(_ stub: StubTransport, chunkMinutes: Int = 14) throws -> GeminiTranscribeProvider {
        var s = GeminiSettings()
        s.chunkMinutes = chunkMinutes
        s.customVocabulary = ["cappy"]
        return try GeminiTranscribeProvider(settings: s, projectID: "p1", bucket: "b1", auth: StaticToken(),
                                            transport: stub, retry: .none, concurrency: 1)
    }

    @Test func requestAndResult() async throws {
        let track = try makeTrack(seconds: 2)
        let stub = StubTransport { call in
            if call.uploadedFile != nil { return .json([:]) }
            if call.method == "DELETE" { return HTTPResponse(status: 204, body: Data()) }
            return Self.transcript("こんにちは", at: 1)
        }
        let p = try provider(stub)
        let job = try await p.submit(track, options: TranscriptionOptions(language: "ja-JP", diarization: true))
        #expect(job.info["diarization"] == "true")
        #expect(try await p.status(of: job) == .done)
        let segs = try await p.result(of: job)
        #expect(segs == [Segment(track: .remote, speaker: "spk_1", startMs: 1_000, endMs: 2_000, text: "こんにちは", confidence: nil)])

        let gen = try #require(stub.calls.first { $0.url.contains(":generateContent") })
        #expect(gen.url == "https://aiplatform.googleapis.com/v1beta1/projects/p1/locations/global/publishers/google/models/gemini-3.5-transcribe:generateContent")
        #expect(gen.headers["x-goog-user-project"] == "p1")
        let body = try #require(try JSONSerialization.jsonObject(with: gen.body ?? Data()) as? [String: Any])
        let part = ((body["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])?.first
        let file = part?["fileData"] as? [String: Any]
        #expect(file?["fileUri"] as? String == "gs://b1/cappy/sid/gemini/remote.flac")
        #expect(file?["mimeType"] as? String == "audio/flac")
        let config = (body["generationConfig"] as? [String: Any])?["audioTranscriptionConfig"] as? [String: Any]
        #expect(config?["languageCodes"] as? [String] == ["ja-JP"])
        #expect(config?["wordTimestamp"] as? Bool == true)
        #expect(config?["diarization"] as? Bool == true)
        #expect(config?["customVocabulary"] as? [String] == ["cappy"])

        try await p.cleanup(job)
        #expect(stub.calls.contains { $0.method == "DELETE" && $0.url.contains("gemini%2Fremote.flac") })
        // 一時ファイルは残さない
        let dir = track.url.deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".gemini-remote").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".chunks-gemini-remote").path))
    }

    @Test func diarizationRejectedFallsBack() async throws {
        let track = try makeTrack(seconds: 1)
        let stub = StubTransport { call in
            if call.uploadedFile != nil { return .json([:]) }
            let body = (try? JSONSerialization.jsonObject(with: call.body ?? Data())) as? [String: Any]
            let config = (body?["generationConfig"] as? [String: Any])?["audioTranscriptionConfig"] as? [String: Any]
            if config?["diarization"] as? Bool == true {
                return .json(["error": ["code": 400, "message": "Speaker diarization is not supported", "status": "INVALID_ARGUMENT"]], status: 400)
            }
            return Self.transcript("a", at: 0)
        }
        let job = try await provider(stub).submit(track, options: TranscriptionOptions(language: "ja-JP", diarization: true))
        #expect(job.info["diarization"] == "false")
        #expect(job.info["diarization_note"] != nil)
    }

    @Test func resumesCompletedChunks() async throws {
        // 1 分ごとに分割される 61 秒の音声（2 分割）
        let track = try makeTrack(seconds: 61)
        let failSecond = Counter()
        let attempt = AttemptFlag()
        let stub = StubTransport { call in
            if call.uploadedFile != nil { return .json([:]) }
            let uri = (((try? JSONSerialization.jsonObject(with: call.body ?? Data())) as? [String: Any])
                .flatMap { ($0["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]] }?.first?["fileData"]
                as? [String: Any])?["fileUri"] as? String ?? ""
            if uri.hasSuffix("-001.flac") && !attempt.second {
                _ = failSecond.next()
                return .json(["error": ["code": 400, "message": "bad audio", "status": "INVALID_ARGUMENT"]], status: 400)
            }
            return Self.transcript(uri.hasSuffix("-000.flac") ? "前半" : "後半", at: 1)
        }
        let p = try provider(stub, chunkMinutes: 1)
        await #expect(throws: (any Error).self) {
            _ = try await p.submit(track, options: TranscriptionOptions(language: "ja-JP", diarization: false))
        }
        let firstRunCalls = stub.calls.filter { $0.url.contains(":generateContent") }.count
        attempt.second = true
        let job = try await p.submit(track, options: TranscriptionOptions(language: "ja-JP", diarization: false))
        let generate = stub.calls.filter { $0.url.contains(":generateContent") }
        // 2 回目は失敗した分割だけを送る
        #expect(generate.count == firstRunCalls + 1)
        let segs = try await p.result(of: job)
        #expect(segs.map(\.text) == ["前半", "後半"])
        #expect(segs[1].startMs == 61_000)
    }
}

final class AttemptFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _second = false
    var second: Bool {
        get { lock.withLock { _second } }
        set { lock.withLock { _second = newValue } }
    }
}
