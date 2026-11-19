import Foundation
import Testing
@testable import CappyKit

@Suite struct SpeakerNamerTests {
    static let segments = [
        Segment(track: .mic, speaker: nil, startMs: 0, endMs: 1000, text: "田中さん、進捗どうですか", confidence: nil),
        Segment(track: .remote, speaker: "spk_0", startMs: 1500, endMs: 3000, text: "はい、田中です。順調です", confidence: nil),
        Segment(track: .remote, speaker: "spk_1", startMs: 3500, endMs: 5000, text: "鈴木です。こちらも問題ありません", confidence: nil),
    ]

    func makeSession(segments: [Segment] = Self.segments, formats: [TranscriptFormat] = [.json, .md, .srt]) throws -> SessionStore {
        let dir = try TestSupport.tempDir()
        var meta = SessionMetadata(id: "sid", name: "test")
        meta.startedAt = "2026-11-11T01:00:00.000Z"
        let store = SessionStore(directory: dir, metadata: meta)
        try store.save()
        let doc = TranscriptDocument(sessionID: "sid", name: "test", startedAt: meta.startedAt, provider: "google",
                                     model: "chirp_3", language: "ja-JP", mix: false, diarization: ["remote": true], segments: segments)
        try TranscriptRenderer.write(doc, formats: formats, to: dir)
        return store
    }

    func options(force: Bool = false, me: String? = nil) -> SpeakerNamer.Options {
        .init(model: "claude-opus-5-5", fallbackModel: "claude-opus-4-8", effort: "low", maxTokens: 32000, me: me, force: force)
    }

    static let response = """
    ```json
    {"speakers": [
      {"label": "自分", "name": null, "confidence": "low", "evidence": "名乗っていない"},
      {"label": "相手 1", "name": "田中さん", "confidence": "high", "evidence": "00:00:01 に名乗っている"},
      {"label": "相手 2", "name": "鈴木", "confidence": "medium", "evidence": "00:00:03 に名乗っている"}
    ]}
    ```
    """

    @Test func namingWithNames() {
        let n = SpeakerNaming(segments: Self.segments, language: .ja, names: ["remote:spk_0": "田中", "mic": "寺岡", "remote:spk_1": " "])
        #expect(Self.segments.map(n.label) == ["寺岡（自分）", "田中（相手 1）", "相手 2"])
        #expect(Self.segments.map(n.key) == ["mic", "remote:spk_0", "remote:spk_1"])
        let en = SpeakerNaming(segments: Self.segments, language: .en, names: ["remote:spk_0": "Tanaka"])
        #expect(en.label(for: Self.segments[1]) == "Tanaka (Remote 1)")
        #expect(n.speakers(in: Self.segments).map { $0.label } == ["自分", "相手 1", "相手 2"])
        // 話者が 1 人だけなら、話者分離のラベルがあってもキーは remote
        let single = [Segment(track: .remote, speaker: "spk_0", startMs: 0, endMs: 1, text: "a", confidence: nil)]
        #expect(SpeakerNaming(segments: single, language: .ja).key(for: single[0]) == "remote")
    }

    @Test func parsesResponse() throws {
        let naming = SpeakerNaming(segments: Self.segments, language: .ja)
        let guesses = try SpeakerPrompt.parse(Self.response, speakers: naming.speakers(in: Self.segments))
        #expect(guesses.map { $0.key } == ["mic", "remote:spk_0", "remote:spk_1"])
        #expect(guesses.map { $0.name } == [nil, "田中", "鈴木"])
        #expect(guesses[1].confidence == "high")
        #expect(guesses[1].label == "相手 1")
        #expect(throws: CappyError.self) { try SpeakerPrompt.parse("わかりません", speakers: naming.speakers(in: Self.segments)) }
    }

    @Test func parseDropsDuplicateNamesAndMissingLabels() throws {
        let naming = SpeakerNaming(segments: Self.segments, language: .ja)
        let text = """
        {"speakers": [
          {"label": "相手1", "name": "田中", "confidence": "medium"},
          {"label": "相手 2", "name": "田中", "confidence": "high"},
          {"label": "相手 9", "name": "佐藤", "confidence": "high"}
        ]}
        """
        let guesses = try SpeakerPrompt.parse(text, speakers: naming.speakers(in: Self.segments))
        #expect(guesses.map { $0.name } == [nil, nil, "田中"])
        #expect(guesses[0].key == "mic")
    }

    @Test func resolvePriority() {
        let guesses = [SpeakerGuess(key: "mic", label: "自分", name: "推定", confidence: "high"),
                       SpeakerGuess(key: "remote:a", label: "相手 1", name: "田中", confidence: "high"),
                       SpeakerGuess(key: "remote:b", label: "相手 2", name: "鈴木", confidence: "low"),
                       SpeakerGuess(key: "remote:c", label: "相手 3", name: "佐藤", confidence: "medium")]
        let names = SpeakerNamer.resolve(guesses: guesses, manual: ["remote:c": "", "remote:x": "幽霊"], me: "寺岡",
                                         keys: ["mic", "remote:a", "remote:b", "remote:c"])
        #expect(names == ["mic": "寺岡", "remote:a": "田中"])
    }

    @Test func infersAppliesAndSkipsWhenUpToDate() async throws {
        let store = try makeSession()
        let client = FakeSummaryClient { SummaryResponse(text: Self.response, model: $0, stopReason: "end_turn") }
        let outcome = try await SpeakerNamer(store: store, client: client, options: options(me: "寺岡")).infer()
        guard case .inferred(let guesses) = outcome else { Issue.record("inferred ではありません: \(outcome)"); return }
        #expect(guesses.count == 3)
        let req = client.requests[0].0
        #expect(req.userText.contains("<speakers>\n自分\n相手 1\n相手 2\n</speakers>"))
        #expect(req.userText.contains("この録音をした本人（自分）の名前: 寺岡"))
        #expect(req.userText.contains("[00:00:01] 相手 1: はい、田中です。順調です"))
        #expect(req.system.contains("JSON"))
        #expect(store.metadata.speakers?.state == .done)

        let names = try SpeakerNamer.apply(store, me: "寺岡")
        #expect(names == ["mic": "寺岡", "remote:spk_0": "田中", "remote:spk_1": "鈴木"])
        let md = try String(contentsOf: store.url(for: "transcript.md"), encoding: .utf8)
        #expect(md.contains("**[00:00:01] 田中（相手 1）**: はい、田中です。順調です"))
        #expect(md.contains("**[00:00:00] 寺岡（自分）**:"))
        let srt = try String(contentsOf: store.url(for: "transcript.srt"), encoding: .utf8)
        #expect(srt.contains("鈴木（相手 2）: 鈴木です。"))
        let doc = try SpeakerNamer.load(store).doc
        #expect(doc.speakerNames == names)
        // 要約にも名前が渡る
        #expect(SummaryPrompt.user(doc: doc, meta: store.metadata).contains("話者: 寺岡（自分）, 田中（相手 1）, 鈴木（相手 2）"))

        // 名前を書き込んでも、同じ発言なら推定し直さない
        let again = try await SpeakerNamer(store: store, client: client, options: options()).infer()
        guard case .upToDate = again else { Issue.record("upToDate ではありません: \(again)"); return }
        #expect(client.requests.count == 1)
        _ = try await SpeakerNamer(store: store, client: client, options: options(force: true)).infer()
        #expect(client.requests.count == 2)
    }

    @Test func applyDoesNotRewriteWhenUnchanged() async throws {
        let store = try makeSession(formats: [.json])
        let client = FakeSummaryClient { SummaryResponse(text: Self.response, model: $0, stopReason: "end_turn") }
        _ = try await SpeakerNamer(store: store, client: client, options: options()).infer()
        try SpeakerNamer.apply(store, me: nil)
        let url = store.url(for: "transcript.json")
        let before = try Data(contentsOf: url)
        try SpeakerNamer.apply(store, me: nil)
        #expect(try Data(contentsOf: url) == before)
        // 書いていない形式は作らない
        #expect(!FileManager.default.fileExists(atPath: store.url(for: "transcript.md").path))
    }

    @Test func manualOverridesAndClear() async throws {
        let store = try makeSession()
        let client = FakeSummaryClient { SummaryResponse(text: Self.response, model: $0, stopReason: "end_turn") }
        _ = try await SpeakerNamer(store: store, client: client, options: options()).infer()
        try SpeakerNamer.apply(store, me: nil)

        // 表示名・英語の表示名・今の名前のどれでも指定できる
        try SpeakerNamer.setManual(store, [(label: "相手 2", name: "鈴木一郎"), (label: "Me", name: "寺岡"), (label: "田中", name: "")])
        var names = try SpeakerNamer.apply(store, me: nil)
        #expect(names == ["mic": "寺岡", "remote:spk_1": "鈴木一郎"])

        // 指定を取り消すと推定に戻る
        try SpeakerNamer.setManual(store, [(label: "相手 1", name: nil)])
        names = try SpeakerNamer.apply(store, me: nil)
        #expect(names["remote:spk_0"] == "田中")

        #expect(throws: CappyError.self) { try SpeakerNamer.setManual(store, [(label: "相手 5", name: "x")]) }

        try SpeakerNamer.clear(store)
        names = try SpeakerNamer.apply(store, me: nil)
        #expect(names.isEmpty)
        // 設定の自分の名前（speakers.me）も付けない
        #expect(try SpeakerNamer.apply(store, me: "寺岡").isEmpty)
        #expect(try SpeakerNamer.load(store).doc.speakerNames == nil)
        // 取り消した後は、要約の前の自動実行で推定し直さない
        let again = try await SpeakerNamer(store: store, client: client, options: options()).infer()
        guard case .upToDate = again else { Issue.record("upToDate ではありません: \(again)"); return }
    }

    @Test func staleNamesAreNotAppliedAfterRetranscription() async throws {
        let store = try makeSession()
        let client = FakeSummaryClient { SummaryResponse(text: Self.response, model: $0, stopReason: "end_turn") }
        _ = try await SpeakerNamer(store: store, client: client, options: options()).infer()
        try SpeakerNamer.apply(store, me: nil)

        // 文字起こしをやり直した（ラベルの付き方が変わった）
        let redone = [Segment(track: .remote, speaker: "spk_1", startMs: 1500, endMs: 3000, text: "はい、田中です", confidence: nil),
                      Segment(track: .remote, speaker: "spk_0", startMs: 3500, endMs: 5000, text: "鈴木です", confidence: nil)]
        let doc = TranscriptDocument(sessionID: "sid", name: "test", startedAt: nil, provider: "google", model: nil,
                                     language: "ja-JP", mix: false, diarization: ["remote": true], segments: redone)
        try TranscriptRenderer.write(doc, formats: [.json], to: store.directory)
        #expect(try SpeakerNamer.apply(store, me: nil).isEmpty)
        let outcome = try await SpeakerNamer(store: store, client: client, options: options()).infer()
        guard case .inferred = outcome else { Issue.record("inferred ではありません: \(outcome)"); return }
    }

    @Test func mixWithoutDiarizationHasNothingToName() async throws {
        let segs = [Segment(track: .mix, speaker: nil, startMs: 0, endMs: 1000, text: "こんにちは", confidence: nil)]
        let store = try makeSession(segments: segs)
        let client = FakeSummaryClient { SummaryResponse(text: Self.response, model: $0, stopReason: "end_turn") }
        let outcome = try await SpeakerNamer(store: store, client: client, options: options()).infer()
        #expect(outcome == .nothingToName)
        #expect(client.requests.isEmpty)
    }

    @Test func failureIsRecorded() async throws {
        let store = try makeSession()
        let client = FakeSummaryClient { SummaryResponse(text: "名前は分かりません", model: $0, stopReason: "end_turn") }
        await #expect(throws: CappyError.self) {
            _ = try await SpeakerNamer(store: store, client: client, options: options()).infer()
        }
        #expect(store.metadata.speakers?.state == .failed)
    }

    @Test func configSection() throws {
        let c = try CappyConfig.parse("""
        [profiles.default.speakers]
        auto = false
        me = " 寺岡 "
        model = "claude-opus-5-5"
        effort = "medium"
        """, path: URL(fileURLWithPath: "/tmp/c.toml"))
        let p = try c.profile(named: "default")
        #expect(!p.speakers.auto)
        #expect(p.speakers.me == "寺岡")
        #expect(p.speakers.model == "claude-opus-5-5")
        #expect(p.speakers.effort == "medium")
        #expect(Profile(name: "x").speakers.auto)
        #expect(Profile(name: "x").speakers.effort == "low")
        #expect(throws: CappyError.self) {
            _ = try CappyConfig.parse("[profiles.default.speakers]\neffort = \"extreme\"", path: URL(fileURLWithPath: "/tmp/c.toml"))
        }
    }
}
