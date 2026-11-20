import Foundation
import Testing
@testable import CappyKit

/// 発言ごとに決まった文字を返す偽の認識
final class FakeUtteranceRecognizer: LocalUtteranceRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [Int] = []
    private var _prepared = 0

    var calls: [Int] { lock.withLock { _calls } }
    var prepared: Int { lock.withLock { _prepared } }

    func prepare() async throws { lock.withLock { _prepared += 1 } }

    func recognize(samples: [Float], language: String) async throws -> [RecognizedPiece] {
        let n = lock.withLock { () -> Int in
            _calls.append(samples.count)
            return _calls.count
        }
        return [RecognizedPiece(startMs: 100, endMs: Int64(samples.count) * 1000 / 16_000, text: " 発言\(n) ")]
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [LiveTranscriber.Event] = []
    func add(_ e: LiveTranscriber.Event) { lock.withLock { _events.append(e) } }
    var segments: [Segment] {
        lock.withLock { _events.compactMap { if case .segment(let s) = $0 { return s } else { return nil } } }
    }
}

@Suite struct LocalLiveTests {
    /// 16 kHz・16 bit の音声（amplitude 0 なら無音）
    static func pcm(ms: Int, amplitude: Float) -> Data {
        let n = ms * 16
        var data = Data(capacity: n * 2)
        for i in 0..<n {
            let v = amplitude * sin(Float(i) * 2 * .pi * 440 / 16_000)
            var s = Int16(max(-1, min(1, v)) * 32767).littleEndian
            withUnsafeBytes(of: &s) { data.append(contentsOf: $0) }
        }
        return data
    }

    @Test func segmenterCutsAtPauses() {
        var seg = UtteranceSegmenter()
        var out: [UtteranceSegmenter.Utterance] = []
        out += seg.feed(Self.pcm(ms: 1000, amplitude: 0))
        out += seg.feed(Self.pcm(ms: 1000, amplitude: 0.3))
        #expect(out.isEmpty)
        #expect(seg.isSpeaking)
        out += seg.feed(Self.pcm(ms: 1000, amplitude: 0))
        #expect(out.count == 1)
        // 話し始めの 300 ms 前から、800 ms の無音まで
        #expect(out[0].startMs == 700)
        #expect(out[0].durationMs == 2100)
        #expect(!seg.isSpeaking)

        // 短い物音は捨てる
        out += seg.feed(Self.pcm(ms: 200, amplitude: 0.3))
        out += seg.feed(Self.pcm(ms: 1000, amplitude: 0))
        #expect(out.count == 1)
    }

    @Test func segmenterSplitsLongSpeechAndFlushes() {
        var seg = UtteranceSegmenter()
        let out = seg.feed(Self.pcm(ms: 30_000, amplitude: 0.3))
        #expect(out.count == 1)
        #expect(out[0].startMs == 0)
        #expect(out[0].durationMs == 25_000)
        let rest = seg.flush()
        #expect(rest?.startMs == 25_000)
        #expect(rest?.durationMs == 5_000)
        #expect(seg.flush() == nil)
    }

    @Test func chunkedBackendEmitsSegmentsAtRecordingTime() async throws {
        let recognizer = FakeUtteranceRecognizer()
        let backend = ChunkedLocalBackend(name: "whisperkit", recognizer: recognizer)
        let log = EventLog()
        var options = LiveTranscriber.Options(model: "", language: "ja-JP", track: .remote)
        options.drainSeconds = 5
        let t = LiveTranscriber(options: options, backend: backend) { log.add($0) }
        t.start()
        // 録音開始から 10 秒の位置から送る。2 回話して、間に無音を挟む
        var at: Int64 = 10_000
        func send(_ ms: Int, _ amplitude: Float) {
            for _ in 0..<(ms / 100) {
                t.enqueue(.init(pcm: Self.pcm(ms: 100, amplitude: amplitude), startMs: at, durationMs: 100))
                at += 100
            }
        }
        send(500, 0)
        send(1000, 0.3)
        send(1000, 0)
        send(800, 0.3)
        await t.finish()
        let segs = log.segments
        #expect(segs.map(\.text) == ["発言1", "発言2"])
        #expect(segs.allSatisfy { $0.track == .remote && $0.speaker == nil })
        // 1 つ目の発言は 10 秒 + 200 ms（無音 500 ms のうち 300 ms を残す）から。認識結果の 100 ms を足す
        #expect(segs[0].startMs == 10_300)
        #expect(recognizer.prepared == 1)
        #expect(recognizer.calls.count == 2)
        #expect(t.sessions == 1)
    }

    @Test func localConfig() {
        var s = LocalTranscribeSettings()
        let w = LiveConfig.local(settings: s)
        #expect(w.provider == "whisperkit")
        #expect(w.location == "local")
        #expect(w.diarizedTracks.isEmpty)
        #expect(w.drainSeconds == 120)
        s.engine = .apple
        #expect(LiveConfig.local(settings: s).provider == "apple")
        #expect(LiveConfig.documentProvider("whisperkit") == "whisperkit-live")
        #expect(LiveConfig.documentProvider("apple") == "apple-live")
        #expect(LiveConfig.documentProvider("transcribe") == "transcribe-streaming")
        #expect(LiveConfig.documentProvider("gemini") == "gemini-live")
    }
}
