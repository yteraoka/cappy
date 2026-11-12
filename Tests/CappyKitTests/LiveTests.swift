import AVFoundation
import Foundation
import Testing
@testable import CappyKit

/// 偽の Live API。setup には setupComplete を返し、送られた音声に応じて script が返事を決める
final class FakeLiveSocket: LiveSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    private let inbox: AsyncStream<String>
    private let inboxCont: AsyncStream<String>.Continuation
    private var iterator: AsyncStream<String>.Iterator
    let index: Int
    let script: @Sendable (FakeLiveSocket, String) -> Void

    init(index: Int, script: @escaping @Sendable (FakeLiveSocket, String) -> Void) {
        self.index = index
        self.script = script
        (inbox, inboxCont) = AsyncStream<String>.makeStream()
        iterator = inbox.makeAsyncIterator()
    }

    var sent: [String] { lock.withLock { _sent } }

    func push(_ obj: [String: Any]) {
        inboxCont.yield(String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self))
    }

    func send(_ text: String) async throws {
        lock.withLock { _sent.append(text) }
        if text.contains("\"setup\"") { push(["setupComplete": [:]]) }
        script(self, text)
    }

    func receive() async throws -> String {
        var it = lock.withLock { iterator }
        let next = await it.next()
        lock.withLock { iterator = it }
        guard let next else { throw LiveConnectionError(message: "closed", permanent: false) }
        return next
    }

    func close() { inboxCont.finish() }
}

final class FakeLiveConnector: LiveConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var _sockets: [FakeLiveSocket] = []
    let failure: Error?
    let script: @Sendable (FakeLiveSocket, String) -> Void

    init(failure: Error? = nil, script: @escaping @Sendable (FakeLiveSocket, String) -> Void = { _, _ in }) {
        self.failure = failure
        self.script = script
    }

    var sockets: [FakeLiveSocket] { lock.withLock { _sockets } }

    func connect() async throws -> LiveSocket {
        if let failure { throw failure }
        return lock.withLock {
            let s = FakeLiveSocket(index: _sockets.count, script: script)
            _sockets.append(s)
            return s
        }
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [LiveTranscriber.Event] = []
    func add(_ e: LiveTranscriber.Event) { lock.withLock { _events.append(e) } }
    var segments: [Segment] {
        lock.withLock { _events.compactMap { if case .segment(let s) = $0 { return s }; return nil } }
    }
    var failures: [String] {
        lock.withLock { _events.compactMap { if case .failed(_, let m) = $0 { return m }; return nil } }
    }
}

@Suite struct LiveTranscriberTests {
    static func chunk(_ i: Int) -> LiveTranscriber.Chunk {
        .init(pcm: Data(repeating: UInt8(i % 256), count: 3200), startMs: Int64(i) * 100, durationMs: 100)
    }

    @Test func sendsSetupAudioAndReturnsSegments() async throws {
        let connector = FakeLiveConnector { socket, text in
            // 10 個目の音声を受け取ったら、0.2〜0.9 秒の発言を確定する
            if text.contains("realtimeInput"), socket.sent.filter({ $0.contains("\"audio\"") }).count == 10 {
                socket.push(["serverContent": ["interimInputTranscription": ["text": "こんに"]]])
                socket.push(["serverContent": ["inputTranscription": ["text": "こんにちは", "startOffset": "0.2s", "endOffset": "0.9s"]]])
            }
        }
        let log = EventLog()
        let t = LiveTranscriber(options: .init(model: "projects/p/locations/global/publishers/google/models/gemini-3.5-transcribe-live",
                                               language: "ja-JP", track: .remote),
                                connector: connector) { log.add($0) }
        t.start()
        for i in 0..<20 { t.enqueue(Self.chunk(i)) }
        // 結果が届くのを待つ
        for _ in 0..<100 where log.segments.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        await t.finish()

        #expect(log.segments == [Segment(track: .remote, speaker: nil, startMs: 200, endMs: 900, text: "こんにちは", confidence: nil)])
        let socket = try #require(connector.sockets.first)
        let setup = try #require(JSONSerialization.jsonObject(with: Data(socket.sent[0].utf8)) as? [String: Any])["setup"] as? [String: Any]
        #expect(setup?["model"] as? String == "projects/p/locations/global/publishers/google/models/gemini-3.5-transcribe-live")
        #expect((setup?["generationConfig"] as? [String: Any])?["responseModalities"] as? [String] == ["TEXT"])
        #expect((setup?["inputAudioTranscription"] as? [String: Any])?["languageCodes"] as? [String] == ["ja-JP"])
        let audio = try #require(JSONSerialization.jsonObject(with: Data(socket.sent[1].utf8)) as? [String: Any])
        let blob = (audio["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any]
        #expect(blob?["mimeType"] as? String == "audio/pcm;rate=16000")
        #expect(Data(base64Encoded: blob?["data"] as? String ?? "")?.count == 3200)
        #expect(socket.sent.filter { $0.contains("\"audio\"") }.count == 20)
        #expect(socket.sent.last == "{\"realtimeInput\":{\"audioStreamEnd\":true}}")
        #expect(t.sessions == 1)
    }

    @Test func rotatesSessionsAndOffsetsTimes() async throws {
        let connector = FakeLiveConnector { socket, text in
            // 各セッションの 3 個目の音声で、セッション内 0.1〜0.2 秒の発言を確定する
            if text.contains("\"audio\""), socket.sent.filter({ $0.contains("\"audio\"") }).count == 3 {
                socket.push(["serverContent": ["inputTranscription": ["text": "s\(socket.index)", "startOffset": "0.1s", "endOffset": "0.2s"]]])
            }
        }
        let log = EventLog()
        var opts = LiveTranscriber.Options(model: "m", language: "ja-JP", track: .mic)
        opts.softLimitMs = 1_000
        opts.hardLimitMs = 1_500
        opts.quietMs = 0
        opts.drainSeconds = 1
        let t = LiveTranscriber(options: opts, connector: connector) { log.add($0) }
        t.start()
        for i in 0..<25 {
            t.enqueue(Self.chunk(i))
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await t.finish()
        #expect(connector.sockets.count >= 2)
        let segs = log.segments.sorted { $0.startMs < $1.startMs }
        #expect(segs.first == Segment(track: .mic, speaker: nil, startMs: 100, endMs: 200, text: "s0", confidence: nil))
        // 2 つ目のセッションは 1 秒の時点から始まるので、時刻はその分ずれる
        let second = try #require(segs.first { $0.text == "s1" })
        #expect(second.startMs >= 1_100 && second.startMs <= 1_700)
        // 古いセッションは音声の終わりを伝えてから閉じる
        #expect(connector.sockets[0].sent.last == "{\"realtimeInput\":{\"audioStreamEnd\":true}}")
    }

    /// 相手が話し続けてサーバーが話の切れ目を見つけない場合（認識途中の文字だけが届き、audioStreamEnd でやっと確定する）
    @Test func flushesLongUtterancesWithinTheSession() async throws {
        let connector = FakeLiveConnector { socket, text in
            let audio = socket.sent.filter { $0.contains("\"audio\"") }.count
            if text.contains("audioStreamEnd") {
                socket.push(["serverContent": ["inputTranscription": ["text": "発言\(audio)"]]])
            } else if text.contains("\"audio\"") {
                socket.push(["serverContent": ["interimInputTranscription": ["text": "途中\(audio)"]]])
            }
        }
        let log = EventLog()
        var opts = LiveTranscriber.Options(model: "m", language: "ja-JP", track: .remote)
        opts.targetUtteranceMs = 1_000
        opts.quietUtteranceMs = 1_000
        opts.maxUtteranceMs = 2_000
        opts.drainSeconds = 1
        let t = LiveTranscriber(options: opts, connector: connector) { log.add($0) }
        t.start()
        for i in 0..<100 {
            t.enqueue(Self.chunk(i))
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        await t.finish()

        // 止める前に、同じセッションのまま何度も確定している
        let socket = try #require(connector.sockets.first)
        #expect(connector.sockets.count == 1)
        let ends = socket.sent.indices.filter { socket.sent[$0].contains("audioStreamEnd") }
        #expect(ends.count >= 4)
        #expect(ends.dropLast().allSatisfy { socket.sent[$0 + 1].contains("\"audio\"") }) // 区切った後も音声を送り続ける
        #expect(log.segments.count >= 4)
        // 1 つの発言は maxUtteranceMs（とその前後の余裕）を超えない
        #expect(log.segments.allSatisfy { $0.endMs - $0.startMs <= 2_000 + 1_500 + 200 })
        #expect(socket.sent.filter { $0.contains("\"audio\"") }.count == 100)
    }

    /// targetUtteranceMs を超えたら、音の大きさより文の終わりを優先して区切る
    @Test func flushesAtTheEndOfASentence() async throws {
        let connector = FakeLiveConnector { socket, text in
            let audio = socket.sent.filter { $0.contains("\"audio\"") }.count
            if text.contains("audioStreamEnd") {
                socket.push(["serverContent": ["inputTranscription": ["text": "確定\(audio)"]]])
            } else if text.contains("\"audio\"") {
                // 25 個目（2.5 秒）の音声で文が終わる。それ以外は文の途中
                let interim = audio == 25 ? "ここで文が終わる。 " : "文の途中\(audio)"
                socket.push(["serverContent": ["interimInputTranscription": ["text": interim]]])
            }
        }
        let log = EventLog()
        var opts = LiveTranscriber.Options(model: "m", language: "ja-JP", track: .remote)
        opts.targetUtteranceMs = 1_000
        opts.quietUtteranceMs = 3_000
        opts.maxUtteranceMs = 4_000
        opts.drainSeconds = 1
        let t = LiveTranscriber(options: opts, connector: connector) { log.add($0) }
        t.start()
        for i in 0..<40 {
            t.enqueue(Self.chunk(i))
            try await Task.sleep(nanoseconds: 3_000_000)
        }
        await t.finish()
        let socket = try #require(connector.sockets.first)
        // 最初の区切りは、文が終わった直後（26 個目の音声の前）
        let audioBeforeFirstEnd = socket.sent.prefix { !$0.contains("audioStreamEnd") }.filter { $0.contains("\"audio\"") }.count
        #expect(audioBeforeFirstEnd == 25)
    }

    @Test func splitsAtTheLastSentenceEnd() {
        func split(_ s: String) -> [String]? { LiveSessionHandle.splitAtSentenceEnd(s).map { [$0.head, $0.tail] } }
        #expect(split("考えてます。僕ね、今の") == ["考えてます。", "僕ね、今の"])
        #expect(split("そうです。") == ["そうです。", ""])
        #expect(split("本当ですか？ ") == ["本当ですか？", ""])
        #expect(split("「やります！」それで") == ["「やります！」", "それで"])
        #expect(split("That's it. And then") == ["That's it.", "And then"])
        #expect(split("version 3.5 is") == nil) // 小数点では分けない
        #expect(split("望月さんはね、") == nil)
        #expect(split("") == nil)
        #expect(LiveSessionHandle.join("And", "then") == "And then")
        #expect(LiveSessionHandle.join("僕ね、", "今の") == "僕ね、今の")
    }

    /// 区切って確定させた発言の、最後の文の終わりより後ろは次の発言の頭に回す
    @Test func carriesTheTailOfAFlushedUtterance() async throws {
        let connector = FakeLiveConnector { socket, text in
            let audio = socket.sent.filter { $0.contains("\"audio\"") }.count
            let ends = socket.sent.filter { $0.contains("audioStreamEnd") }.count
            if text.contains("audioStreamEnd") {
                // 1 回目（区切り）は文の途中まで、2 回目（終了）は残りを確定する
                let final = ends == 1 ? "最初の文です。次の文は" : "ここで終わります。"
                socket.push(["serverContent": ["inputTranscription": ["text": final]]])
            } else if text.contains("\"audio\""), ends == 0 {
                socket.push(["serverContent": ["interimInputTranscription": ["text": "最初の文\(audio)"]]])
            }
        }
        let log = EventLog()
        var opts = LiveTranscriber.Options(model: "m", language: "ja-JP", track: .remote)
        opts.targetUtteranceMs = 500
        opts.quietUtteranceMs = 500
        opts.maxUtteranceMs = 1_000
        opts.drainSeconds = 1
        let t = LiveTranscriber(options: opts, connector: connector) { log.add($0) }
        t.start()
        for i in 0..<30 {
            t.enqueue(Self.chunk(i))
            try await Task.sleep(nanoseconds: 3_000_000)
        }
        await t.finish()
        #expect(log.segments.map(\.text) == ["最初の文です。", "次の文はここで終わります。"])
        let segs = log.segments
        #expect(segs.count == 2 && segs[1].startMs <= segs[0].endMs)
    }

    @Test func emitsTheCarriedTailWhenTheSessionEnds() async throws {
        let connector = FakeLiveConnector { socket, text in
            let audio = socket.sent.filter { $0.contains("\"audio\"") }.count
            let ends = socket.sent.filter { $0.contains("audioStreamEnd") }.count
            if text.contains("audioStreamEnd"), ends == 1 {
                socket.push(["serverContent": ["inputTranscription": ["text": "文です。続き"]]])
            } else if text.contains("\"audio\""), ends == 0 {
                socket.push(["serverContent": ["interimInputTranscription": ["text": "文\(audio)"]]])
            }
        }
        let log = EventLog()
        var opts = LiveTranscriber.Options(model: "m", language: "ja-JP", track: .remote)
        opts.targetUtteranceMs = 500
        opts.quietUtteranceMs = 500
        opts.maxUtteranceMs = 1_000
        opts.drainSeconds = 0.3
        let t = LiveTranscriber(options: opts, connector: connector) { log.add($0) }
        t.start()
        for i in 0..<20 {
            t.enqueue(Self.chunk(i))
            try await Task.sleep(nanoseconds: 3_000_000)
        }
        await t.finish()
        #expect(log.segments.map(\.text) == ["文です。", "続き"])
    }

    @Test func keepsUnconfirmedTextWhenTheSessionEnds() async throws {
        // 認識途中の文字は届くが、audioStreamEnd を送っても確定しない
        let connector = FakeLiveConnector { socket, text in
            if text.contains("\"audio\""), socket.sent.filter({ $0.contains("\"audio\"") }).count == 5 {
                socket.push(["serverContent": ["interimInputTranscription": ["text": "最後まで確定しなかった発言"]]])
            }
        }
        let log = EventLog()
        var opts = LiveTranscriber.Options(model: "m", language: "ja-JP", track: .remote)
        opts.drainSeconds = 0.3
        let t = LiveTranscriber(options: opts, connector: connector) { log.add($0) }
        t.start()
        for i in 0..<10 { t.enqueue(Self.chunk(i)) }
        await t.finish()
        let seg = try #require(log.segments.first)
        #expect(log.segments.count == 1)
        #expect(seg.text == "最後まで確定しなかった発言")
        #expect(seg.endMs == 1_000)
    }

    @Test func levelIsRMS() {
        var pcm = Data()
        for v: Int16 in [1_000, -1_000, 1_000, -1_000] { withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) } }
        #expect(LiveSessionHandle.level(pcm) == 1_000)
        #expect(LiveSessionHandle.level(Data()) == 0)
    }

    @Test func permanentFailureStopsSending() async throws {
        let connector = FakeLiveConnector(failure: LiveConnectionError(message: "HTTP 403", permanent: true))
        let log = EventLog()
        let t = LiveTranscriber(options: .init(model: "m", language: "ja-JP", track: .remote), connector: connector) { log.add($0) }
        t.start()
        for i in 0..<10 { t.enqueue(Self.chunk(i)) }
        await t.finish()
        #expect(log.failures == ["HTTP 403"])
        #expect(t.failed)
        #expect(t.droppedMs == 1_000)
    }
}

@Suite struct LiveAudioSinkTests {
    @Test func convertsTo16kMonoChunks() async throws {
        let connector = FakeLiveConnector()
        let t = LiveTranscriber(options: .init(model: "m", language: "ja-JP", track: .remote), connector: connector) { _ in }
        let sink = LiveAudioSink(transcriber: t)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        try sink.start(format: format, track: .remote)
        // 1 秒分を 10 ms ずつ渡す
        for _ in 0..<100 {
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            buf.frameLength = 480
            let p = buf.floatChannelData![0]
            for i in 0..<960 { p[i] = 0.25 }
            sink.consume(buf, at: 0)
        }
        try await sink.finish()
        let audio = try #require(connector.sockets.first).sent.filter { $0.contains("\"audio\"") }
        let bytes = audio.compactMap { msg -> Int? in
            let obj = try? JSONSerialization.jsonObject(with: Data(msg.utf8)) as? [String: Any]
            let b64 = ((obj?["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any])?["data"] as? String
            return b64.flatMap { Data(base64Encoded: $0)?.count }
        }
        let total = bytes.reduce(0, +)
        // 16 kHz・16 bit・モノラルで約 1 秒（変換器の遅延で少し短くなる）
        #expect(total > 30_000 && total <= 32_000)
        #expect(bytes.dropLast().allSatisfy { $0 == 3200 })
    }
}

@Suite struct LiveTranscriptionTests {
    @Test func writesLiveTranscriptAndState() async throws {
        let dir = try TestSupport.tempDir()
        var meta = SessionMetadata(id: "sid", name: "live")
        meta.startedAt = "2026-11-11T01:00:00.000Z"
        let store = SessionStore(directory: dir, metadata: meta)
        try store.save()
        let connector = FakeLiveConnector { socket, text in
            if text.contains("\"audio\""), socket.sent.filter({ $0.contains("\"audio\"") }).count == 2 {
                socket.push(["serverContent": ["inputTranscription": ["text": "確定した発言", "startOffset": "0s", "endOffset": "0.2s"]]])
            }
        }
        var settings = GeminiSettings()
        settings.location = "global"
        let live = LiveTranscription(store: store, settings: settings, projectID: "p1", language: "ja-JP", connector: connector)
        #expect(live.modelResource == "projects/p1/locations/global/publishers/google/models/gemini-3.5-transcribe-live")
        try live.begin()
        let sink = live.sink(for: .mic)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: true)!
        try sink.start(format: format, track: .mic)
        for _ in 0..<5 {
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            buf.frameLength = 1600
            sink.consume(buf, at: 0)
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: dir.appendingPathComponent("live-transcript.jsonl").path)
            || (try? Data(contentsOf: dir.appendingPathComponent("live-transcript.jsonl")))?.isEmpty != false {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await sink.finish()
        let urls = try live.finish(formats: [.md])
        #expect(urls.map(\.lastPathComponent) == ["live-transcript.md"])
        let md = try String(contentsOf: dir.appendingPathComponent("live-transcript.md"), encoding: .utf8)
        #expect(md.contains("**[00:00:00] 自分**: 確定した発言"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("live-transcript.json").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("live-transcript.jsonl").path))
        let state = try #require(SessionStore.open(dir).metadata.live)
        #expect(state.state == .done && state.segments == 1 && state.sessions == 1)
        #expect(state.model == "gemini-3.5-transcribe-live")
    }

    @Test func recoversJournal() throws {
        let dir = try TestSupport.tempDir()
        let store = SessionStore(directory: dir, metadata: SessionMetadata(id: "sid", name: nil))
        try store.save()
        let seg = Segment(track: .remote, speaker: nil, startMs: 1_000, endMs: 2_000, text: "途中まで", confidence: nil)
        try (try JSONEncoder().encode(seg) + Data("\n".utf8)).write(to: dir.appendingPathComponent("live-transcript.jsonl"))
        let urls = try LiveTranscription.recoverJournal(store)
        #expect(urls.count == 3)
        let doc = try JSONDecoder().decode(TranscriptDocument.self, from: Data(contentsOf: dir.appendingPathComponent("live-transcript.json")))
        #expect(doc.segments == [seg])
    }

    @Test func summarizerFallsBackToLiveTranscript() async throws {
        let dir = try TestSupport.tempDir()
        let store = SessionStore(directory: dir, metadata: SessionMetadata(id: "sid", name: "m"))
        try store.save()
        let doc = TranscriptDocument(sessionID: "sid", name: "m", startedAt: nil, provider: "gemini-live", model: nil,
                                     language: "ja-JP", mix: false, diarization: [:],
                                     segments: [Segment(track: .mic, speaker: nil, startMs: 0, endMs: 1, text: "a", confidence: nil)])
        try TranscriptRenderer.write(doc, formats: [.json], to: dir, baseName: "live-transcript")
        let client = FakeSummaryClient { SummaryResponse(text: "## 概要\nx", model: $0, stopReason: "end_turn") }
        let outcome = try await Summarizer(store: store, client: client, options: .init(
            model: "gemini-4-argon", fallbackModel: nil, effort: "high", maxTokens: 32000, language: "ja-JP")).run()
        let md = try String(contentsOf: outcome.url, encoding: .utf8)
        #expect(md.contains("リアルタイム文字起こし（live-transcript.json）から作成しました"))
    }
}
