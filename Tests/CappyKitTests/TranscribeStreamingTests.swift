import AVFoundation
import Foundation
import Testing
@testable import CappyKit

@Suite struct EventStreamTests {
    @Test func crc32() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test func roundTrip() throws {
        let m = EventStreamMessage(headers: [
            ":message-type": .string("event"), "b": .bool(true), "f": .bool(false), "i": .int(-7), "l": .long(1 << 40),
            "s": .short(300), "y": .byte(-1), "d": .bytes(Data([1, 2, 3])), "t": .timestamp(1_700_000_000_000),
            "u": .uuid(Data(repeating: 9, count: 16)),
        ], payload: Data("hello".utf8))
        let data = m.encode()
        #expect(try EventStreamMessage.decode(data) == m)
        // 長さ・CRC の誤りを検出する
        var bad = data
        bad[bad.count - 1] ^= 0xFF
        #expect(throws: EventStreamMessage.DecodeError.messageCRC) { try EventStreamMessage.decode(bad) }
        var badPrelude = data
        badPrelude[9] ^= 0xFF
        #expect(throws: EventStreamMessage.DecodeError.preludeCRC) { try EventStreamMessage.decode(badPrelude) }
        #expect(throws: EventStreamMessage.DecodeError.self) { try EventStreamMessage.decode(data.prefix(20)) }
    }

    /// AudioEvent の形（前半 12 バイト + ヘッダー + 本文 + CRC）
    @Test func audioEventLayout() throws {
        let pcm = Data(repeating: 0x11, count: 3200)
        let data = TranscribeStreamingBackend.audioEvent(pcm)
        let m = try EventStreamMessage.decode(data)
        #expect(m.payload == pcm)
        #expect(m.string(":event-type") == "AudioEvent")
        #expect(m.string(":message-type") == "event")
        #expect(m.string(":content-type") == "application/octet-stream")
        #expect(EventStreamMessage.readU32([UInt8](data), 0) == UInt32(data.count))
        #expect(try EventStreamMessage.decode(TranscribeStreamingBackend.audioEvent(Data())).payload.isEmpty)
    }
}

@Suite struct TranscribeStreamParserTests {
    @Test func finalResultSplitBySpeaker() {
        let json = """
        {"Transcript": {"Results": [{"ResultId": "r1", "StartTime": 0.5, "EndTime": 3.2, "IsPartial": false,
          "Alternatives": [{"Transcript": "こんにちは。 はい", "Items": [
            {"Content": "こんにちは", "StartTime": 0.5, "EndTime": 1.2, "Type": "pronunciation", "Speaker": "0", "Confidence": 0.9},
            {"Content": "。", "StartTime": 1.2, "EndTime": 1.2, "Type": "punctuation", "Speaker": "0"},
            {"Content": "はい", "StartTime": 2.0, "EndTime": 3.2, "Type": "pronunciation", "Speaker": "1", "Confidence": 0.7}
          ]}]}]}}
        """
        let rs = TranscribeStreamParser.results(Data(json.utf8), language: "ja-JP")
        #expect(rs.count == 1)
        #expect(rs[0].isPartial == false)
        #expect(rs[0].parts == [
            .init(speaker: "0", startMs: 500, endMs: 1200, text: "こんにちは。", confidence: 0.9),
            .init(speaker: "1", startMs: 2000, endMs: 3200, text: "はい", confidence: 0.7),
        ])
        #expect(rs[0].text == "こんにちは。はい")
    }

    @Test func partialAndEnglish() {
        let json = """
        {"Transcript": {"Results": [{"StartTime": 1.0, "EndTime": 1.5, "IsPartial": true,
          "Alternatives": [{"Transcript": "hello wor", "Items": [
            {"Content": "hello", "StartTime": 1.0, "EndTime": 1.2, "Type": "pronunciation"},
            {"Content": "wor", "StartTime": 1.2, "EndTime": 1.5, "Type": "pronunciation"}]}]}]}}
        """
        let rs = TranscribeStreamParser.results(Data(json.utf8), language: "en-US")
        #expect(rs.first?.isPartial == true)
        #expect(rs.first?.text == "hello wor")
        #expect(rs.first?.parts.first?.speaker == nil)
        // Items がなければ Transcript を使う
        let noItems = #"{"Transcript":{"Results":[{"StartTime":0,"EndTime":2,"IsPartial":false,"Alternatives":[{"Transcript":" はい "}]}]}}"#
        #expect(TranscribeStreamParser.results(Data(noItems.utf8), language: "ja-JP").first?.parts ==
            [.init(speaker: nil, startMs: 0, endMs: 2000, text: "はい", confidence: nil)])
        #expect(TranscribeStreamParser.results(Data(#"{"Transcript":{"Results":[]}}"#.utf8), language: "ja-JP").isEmpty)
    }
}

/// Transcribe Streaming の偽物のソケット。送られた AudioEvent を数え、指定した応答を返す
final class FakeDataSocket: LiveDataSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [Data] = []
    private var queue: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var closed = false
    /// 空の AudioEvent（終わり）を受け取ったら閉じる
    var closeOnEnd = true

    var sent: [Data] { lock.withLock { _sent } }

    func send(_ data: Data) async throws {
        let isEnd = (try? EventStreamMessage.decode(data))?.payload.isEmpty ?? false
        lock.withLock { _sent.append(data) }
        if isEnd && closeOnEnd { close() }
    }

    func push(_ data: Data) {
        let w: CheckedContinuation<Data, Error>? = lock.withLock {
            if waiters.isEmpty { queue.append(data); return nil }
            return waiters.removeFirst()
        }
        w?.resume(returning: data)
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            let ready: Result<Data, Error>? = lock.withLock {
                if !queue.isEmpty { return .success(queue.removeFirst()) }
                if closed { return .failure(LiveConnectionError(message: "closed", permanent: false)) }
                waiters.append(cont)
                return nil
            }
            if let ready { cont.resume(with: ready) }
        }
    }

    func close() {
        let ws: [CheckedContinuation<Data, Error>] = lock.withLock {
            closed = true
            let w = waiters
            waiters = []
            return w
        }
        for w in ws { w.resume(throwing: LiveConnectionError(message: "closed", permanent: false)) }
    }

    static func transcriptEvent(_ json: String) -> Data {
        EventStreamMessage(headers: [":message-type": .string("event"), ":event-type": .string("TranscriptEvent"),
                                     ":content-type": .string("application/json")], payload: Data(json.utf8)).encode()
    }

    static func exception(_ type: String, _ message: String) -> Data {
        EventStreamMessage(headers: [":message-type": .string("exception"), ":exception-type": .string(type),
                                     ":content-type": .string("application/json")],
                           payload: Data(#"{"Message": "\#(message)"}"#.utf8)).encode()
    }
}

final class FakeDataConnector: LiveDataConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    private var _sockets: [FakeDataSocket] = []
    let onConnect: @Sendable (FakeDataSocket, Int) -> Void

    init(onConnect: @escaping @Sendable (FakeDataSocket, Int) -> Void = { _, _ in }) { self.onConnect = onConnect }

    var urls: [URL] { lock.withLock { _urls } }
    var sockets: [FakeDataSocket] { lock.withLock { _sockets } }

    func connect(_ url: URL) async throws -> LiveDataSocket {
        let s = FakeDataSocket()
        let n = lock.withLock { _urls.append(url); _sockets.append(s); return _sockets.count }
        onConnect(s, n)
        return s
    }
}

@Suite struct TranscribeStreamingBackendTests {
    static let creds = StaticAWSCredentials(AWSCredentials(accessKeyID: "AK", secretAccessKey: "SK", sessionToken: "ST"))

    func chunk(_ i: Int) -> LiveTranscriber.Chunk {
        .init(pcm: Data(repeating: 0, count: 3200), startMs: Int64(i) * 100, durationMs: 100)
    }

    @Test func presignedURL() {
        var settings = TranscribeSettings()
        settings.vocabularyName = "terms"
        let b = TranscribeStreamingBackend(region: "ap-northeast-1", settings: settings, credentials: Self.creds,
                                           connector: FakeDataConnector())
        let u = b.url(language: "ja-JP", speakerLabels: true).absoluteString
        #expect(u == "wss://transcribestreaming.ap-northeast-1.amazonaws.com:8443/stream-transcription-websocket"
            + "?language-code=ja-JP&media-encoding=pcm&sample-rate=16000&show-speaker-label=true&vocabulary-name=terms")
        #expect(b.speakerLabels(for: .remote))
        #expect(!b.speakerLabels(for: .mic))
    }

    @Test func streamsAudioAndEmitsSegments() async throws {
        let connector = FakeDataConnector { socket, _ in
            socket.push(FakeDataSocket.transcriptEvent(#"{"Transcript":{"Results":[{"StartTime":0.2,"EndTime":0.6,"IsPartial":true,"Alternatives":[{"Transcript":"こん","Items":[]}]}]}}"#))
            socket.push(FakeDataSocket.transcriptEvent(#"{"Transcript":{"Results":[{"StartTime":0.2,"EndTime":1.0,"IsPartial":false,"Alternatives":[{"Transcript":"こんにちは","Items":[{"Content":"こんにちは","StartTime":0.2,"EndTime":1.0,"Type":"pronunciation","Speaker":"0"}]}]}]}}"#))
        }
        let backend = TranscribeStreamingBackend(region: "ap-northeast-1", settings: TranscribeSettings(), credentials: Self.creds,
                                                 connector: connector)
        let log = EventLog()
        var opts = LiveTranscriber.Options(model: "", language: "ja-JP", track: .remote)
        opts.drainSeconds = 2
        let t = LiveTranscriber(options: opts, backend: backend) { log.add($0) }
        t.start()
        for i in 0..<10 { t.enqueue(chunk(i)) }
        await t.finish()

        #expect(log.segments == [Segment(track: .remote, speaker: "0", startMs: 200, endMs: 1000, text: "こんにちは", confidence: nil)])
        let url = try #require(connector.urls.first).absoluteString
        #expect(url.contains("X-Amz-Security-Token=ST"))
        #expect(url.contains("show-speaker-label=true"))
        #expect(url.contains("%2Fap-northeast-1%2Ftranscribe%2Faws4_request"))
        let sent = try #require(connector.sockets.first).sent.map { try EventStreamMessage.decode($0) }
        #expect(sent.count == 11)
        #expect(sent.prefix(10).allSatisfy { $0.payload.count == 3200 })
        #expect(sent.last?.payload.isEmpty == true)
    }

    @Test func speakerLabelRejectionReconnectsWithout() async throws {
        let connector = FakeDataConnector { socket, n in
            if n == 1 { socket.push(FakeDataSocket.exception("BadRequestException", "Speaker partitioning isn't supported for xx-XX.")) }
        }
        let backend = TranscribeStreamingBackend(region: "us-east-1", settings: TranscribeSettings(), credentials: Self.creds,
                                                 connector: connector)
        let log = EventLog()
        var opts = LiveTranscriber.Options(model: "", language: "xx-XX", track: .remote)
        opts.drainSeconds = 1
        let t = LiveTranscriber(options: opts, backend: backend) { log.add($0) }
        t.start()
        t.enqueue(chunk(0))
        try await Task.sleep(nanoseconds: 200_000_000)
        for i in 1..<20 { t.enqueue(chunk(i)) }
        try await Task.sleep(nanoseconds: 1_300_000_000)
        for i in 20..<30 { t.enqueue(chunk(i)) }
        await t.finish()
        #expect(connector.urls.count >= 2)
        #expect(connector.urls[0].absoluteString.contains("show-speaker-label=true"))
        #expect(!connector.urls[1].absoluteString.contains("show-speaker-label"))
        #expect(log.failures.isEmpty)
    }

    @Test func badRequestStopsLiveTranscription() async throws {
        let connector = FakeDataConnector { socket, _ in
            socket.push(FakeDataSocket.exception("BadRequestException", "The requested vocabulary couldn't be found."))
        }
        let backend = TranscribeStreamingBackend(region: "us-east-1", settings: TranscribeSettings(), credentials: Self.creds,
                                                 connector: connector)
        let log = EventLog()
        var opts = LiveTranscriber.Options(model: "", language: "ja-JP", track: .mic)
        opts.drainSeconds = 1
        let t = LiveTranscriber(options: opts, backend: backend) { log.add($0) }
        t.start()
        t.enqueue(chunk(0))
        try await Task.sleep(nanoseconds: 200_000_000)
        for i in 1..<10 { t.enqueue(chunk(i)) }
        await t.finish()
        #expect(t.failed)
        #expect(log.failures.first?.contains("vocabulary") == true)
        #expect(connector.urls.count == 1)
        #expect(t.droppedMs >= 800)
    }
}

/// 実際の Amazon Transcribe Streaming に、FLAC の音声を実時間で送る（CAPPY_AWS_LIVE_TEST=<16 kHz の音声ファイル> のときだけ）
@Suite struct TranscribeStreamingIntegrationTests {
    static let file = ProcessInfo.processInfo.environment["CAPPY_AWS_LIVE_TEST"]

    @Test(.enabled(if: file != nil)) func realStream() async throws {
        let url = URL(fileURLWithPath: Self.file!)
        let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let pcm = Data(bytes: buf.int16ChannelData![0], count: Int(buf.frameLength) * 2)

        let creds = try AWSCredentialsProvider.resolve(profile: nil, region: nil)
        var settings = TranscribeSettings()
        settings.diarization = ProcessInfo.processInfo.environment["CAPPY_AWS_LIVE_SPEAKERS"] != "0"
        let backend = TranscribeStreamingBackend(region: creds.region ?? "ap-northeast-1", settings: settings, credentials: creds)
        let log = EventLog()
        let t = LiveTranscriber(options: .init(model: "", language: "ja-JP", track: .remote), backend: backend) { e in
            log.add(e)
            print("event: \(e)")
        }
        t.start()
        let chunkBytes = 3200
        var offset = 0
        var ms: Int64 = 0
        while offset < pcm.count {
            let piece = pcm.subdata(in: offset..<min(pcm.count, offset + chunkBytes))
            t.enqueue(.init(pcm: piece, startMs: ms, durationMs: Int64(piece.count / 32)))
            offset += chunkBytes
            ms += 100
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // 最後の発言が確定するよう、無音を少し送る
        for _ in 0..<20 {
            t.enqueue(.init(pcm: Data(count: chunkBytes), startMs: ms, durationMs: 100))
            ms += 100
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await t.finish()
        for s in log.segments { print("segment: [\(s.startMs)-\(s.endMs)] \(s.speaker ?? "-"): \(s.text)") }
        #expect(!t.failed, "\(t.lastError ?? "")")
        #expect(!log.segments.isEmpty)
    }
}

