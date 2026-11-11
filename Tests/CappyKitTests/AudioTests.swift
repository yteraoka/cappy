import AVFoundation
import Foundation
import Testing
@testable import CappyKit

@Suite struct ConverterTests {
    @Test func convertsTo16kMonoFLAC() throws {
        let dir = try TestSupport.tempDir()
        let caf = dir.appendingPathComponent("remote.caf")
        try TestSupport.writeSineCAF(caf, seconds: 3, channels: 2, frequency: 440)
        let r = try SendFileConverter.convert(input: caf, outputBase: dir.appendingPathComponent("remote"))
        #expect(r.container == .flac)
        #expect(r.url.pathExtension == "flac")
        #expect(abs(r.durationMs - 3000) <= 5)
        let est = try TestSupport.estimateFrequency(r.url)
        #expect(est.sampleRate == 16_000)
        #expect(est.channels == 1)
        #expect(abs(est.frequency - 440) < 5)
        let f = try AVAudioFile(forReading: r.url)
        #expect(f.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatFLAC)
    }

    @Test func wavFallbackWorks() throws {
        let dir = try TestSupport.tempDir()
        let caf = dir.appendingPathComponent("mic.caf")
        try TestSupport.writeSineCAF(caf, seconds: 1, channels: 1, frequency: 300)
        let r = try SendFileConverter.convert(input: caf, outputBase: dir.appendingPathComponent("mic"), preferred: .wav)
        #expect(r.url.pathExtension == "wav")
        #expect(abs(try TestSupport.estimateFrequency(r.url).frequency - 300) < 5)
    }

    @Test func mixAlignsOffsets() throws {
        let dir = try TestSupport.tempDir()
        let a = dir.appendingPathComponent("a.caf"), b = dir.appendingPathComponent("b.caf")
        try TestSupport.writeSineCAF(a, seconds: 2, channels: 1, frequency: 440, amplitude: 0.3)
        try TestSupport.writeSineCAF(b, seconds: 1, channels: 1, frequency: 440, amplitude: 0.3)
        let ra = try SendFileConverter.convert(input: a, outputBase: dir.appendingPathComponent("a"))
        let rb = try SendFileConverter.convert(input: b, outputBase: dir.appendingPathComponent("b"))
        let mix = try SendFileConverter.mix(inputs: [(ra.url, 0), (rb.url, 1500)], outputBase: dir.appendingPathComponent("mix"))
        // b は 1.5 秒から 1 秒間 → 全体 2.5 秒
        #expect(abs(mix.durationMs - 2500) <= 5)
        let f = try AVAudioFile(forReading: mix.url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let p = buf.floatChannelData![0]
        func peak(_ from: Double, _ to: Double) -> Float {
            var m: Float = 0
            for i in Int(from * 16000)..<Int(to * 16000) { m = max(m, abs(p[i])) }
            return m
        }
        #expect(abs(peak(0.5, 1.4) - 0.3) < 0.03)   // a のみ
        #expect(abs(peak(1.6, 1.9) - 0.6) < 0.05)   // a + b（同位相）
        #expect(abs(peak(2.1, 2.4) - 0.3) < 0.03)   // b のみ
    }

    @Test func splitsLongFiles() throws {
        let dir = try TestSupport.tempDir()
        let caf = dir.appendingPathComponent("remote.caf")
        try TestSupport.writeSineCAF(caf, seconds: 5, channels: 1)
        let r = try SendFileConverter.convert(input: caf, outputBase: dir.appendingPathComponent("remote"))
        let one = try SendFileConverter.split(r.url, maxSeconds: 10, into: dir.appendingPathComponent("chunks"))
        #expect(one.count == 1)
        #expect(one[0].url == r.url)
        let chunks = try SendFileConverter.split(r.url, maxSeconds: 2, into: dir.appendingPathComponent("chunks"))
        #expect(chunks.map(\.offsetMs) == [0, 2000, 4000])
        #expect(chunks.map(\.durationMs) == [2000, 2000, 1000])
        for c in chunks { #expect(FileManager.default.fileExists(atPath: c.url.path)) }
        #expect(abs((SendFileConverter.durationMs(of: chunks[2].url) ?? 0) - 1000) <= 2)
    }

    @Test func fileSinkConvertsChangedFormat() async throws {
        let dir = try TestSupport.tempDir()
        let url = dir.appendingPathComponent("remote.caf")
        let f48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let f24 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: true)!
        let sink = FileSink(url: url)
        try sink.start(format: f48, track: .remote)
        let a = AVAudioPCMBuffer(pcmFormat: f48, frameCapacity: 48_000)!
        a.frameLength = 48_000
        sink.consume(a, at: 0)
        // 作り直し後に形式が変わっても、最初の形式で書き続ける
        for _ in 0..<10 {
            let b = AVAudioPCMBuffer(pcmFormat: f24, frameCapacity: 2400)!
            b.frameLength = 2400
            sink.consume(b, at: 0)
        }
        try await sink.finish()
        #expect(sink.failure == nil)
        let f = try AVAudioFile(forReading: url)
        #expect(f.fileFormat.sampleRate == 48_000)
        #expect(f.fileFormat.channelCount == 2)
        // 1 秒 + 24 kHz で 1 秒分（変換の遅延ぶん多少短い）
        #expect(abs(Double(f.length) - 96_000) < 500)
    }
}

@Suite struct CAFRepairTests {
    @Test func repairsUnfinalizedDataChunk() throws {
        let dir = try TestSupport.tempDir()
        let url = dir.appendingPathComponent("remote.caf")
        try TestSupport.writeSineCAF(url, seconds: 1, channels: 2)
        // data チャンクのサイズを壊す（異常終了で 0 のまま残ったケース）＋端数バイトを足す
        var data = try Data(contentsOf: url)
        let range = data.range(of: Data("data".utf8))!
        let sizeOffset = range.upperBound
        for i in 0..<8 { data[sizeOffset + i] = 0 }
        data.append(contentsOf: [1, 2, 3])
        try data.write(to: url)

        let report = try CAFRepair.repair(url)
        #expect(report.changed)
        #expect(report.truncatedBytes == 3)
        #expect(report.dataBytes == 48_000 * 8)
        let f = try AVAudioFile(forReading: url)
        #expect(f.length == 48_000)
        // もう一度かけても変わらない
        #expect(try CAFRepair.repair(url).changed == false)
    }

    @Test func recoverRebuildsSessionAndSendFiles() throws {
        let dir = try TestSupport.tempDir().appendingPathComponent("2026-11-11T1000_weekly-sync")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try TestSupport.writeSineCAF(dir.appendingPathComponent("remote.caf"), seconds: 2, channels: 2)
        try TestSupport.writeSineCAF(dir.appendingPathComponent("mic.caf"), seconds: 2, channels: 1)
        let report = try SessionProcessing.recover(dir)
        #expect(report.rebuiltSessionJSON)
        #expect(report.tracks[.remote] == 2000)
        let store = try SessionStore.open(dir)
        #expect(store.metadata.name == "weekly-sync")
        #expect(store.metadata.recording.state == .converted)
        #expect(store.metadata.tracks.count == 2)
        #expect(store.metadata.startedAt != nil)
        #expect(store.metadata.endedAt != nil)
        for t in store.metadata.tracks {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(t.sendFile!).path))
        }
    }

    @Test func recoverMarksInterruptedRecording() throws {
        let dir = try TestSupport.tempDir()
        try TestSupport.writeSineCAF(dir.appendingPathComponent("remote.caf"), seconds: 1, channels: 2)
        var meta = SessionMetadata(id: "s1", name: nil)
        meta.startedAt = TimeFormat.iso8601(Date(timeIntervalSince1970: 1_793_000_000))
        meta.tracks = [SessionTrack(id: .remote, file: "remote.caf", sampleRate: 48_000, channels: 2)]
        let store = SessionStore(directory: dir, metadata: meta)
        try store.save()
        _ = try SessionProcessing.recover(dir)
        let m = try SessionStore.open(dir).metadata
        #expect(m.recording.stopReason == "recovered")
        #expect(m.recording.state == .converted)
        #expect(m.endedAt == TimeFormat.iso8601(Date(timeIntervalSince1970: 1_793_000_001)))
    }
}

@Suite struct RingBufferTests {
    @Test func wrapsAroundAndDropsWhenFull() {
        let ring = RingBuffer(capacity: 100)
        var src = [UInt8](0..<60)
        var dst = [UInt8](repeating: 0, count: 60)
        #expect(src.withUnsafeBytes { ring.write($0.baseAddress!, 60) })
        #expect(!src.withUnsafeBytes { ring.write($0.baseAddress!, 60) })  // 入らない
        #expect(ring.droppedCount == 1)
        #expect(dst.withUnsafeMutableBytes { ring.read(into: $0.baseAddress!, count: 60) })
        #expect(dst == src)
        // 境界をまたぐ
        src = (0..<60).map { UInt8(100 + $0) }
        #expect(src.withUnsafeBytes { ring.write($0.baseAddress!, 60) })
        #expect(ring.availableToRead == 60)
        #expect(dst.withUnsafeMutableBytes { ring.read(into: $0.baseAddress!, count: 60) })
        #expect(dst == src)
        #expect(ring.availableToRead == 0)
        #expect(ring.highWaterBytes == 60)
    }

    @Test func concurrentProducerConsumer() async {
        let ring = RingBuffer(capacity: 4096)
        let total = 20_000
        let producer = Task.detached {
            var i: UInt32 = 0
            while Int(i) < total {
                var v = i
                if withUnsafeBytes(of: &v, { ring.write($0.baseAddress!, 4) }) { i += 1 }
            }
        }
        var expected: UInt32 = 0
        var ok = true
        while Int(expected) < total {
            var v: UInt32 = 0
            if withUnsafeMutableBytes(of: &v, { ring.read(into: $0.baseAddress!, count: 4) }) {
                if v != expected { ok = false; break }
                expected += 1
            }
        }
        await producer.value
        #expect(ok)
    }
}

@Suite struct TimelineTests {
    // テストではホストタイムをナノ秒として扱う
    let toSec: (UInt64, UInt64) -> Double = { a, b in (Double(a) - Double(b)) / 1e9 }

    @Test func detectsGapsAndTracksPosition() {
        var t = TimelineTracker()
        let d = 0.01 // 10 ms ごとのバッファ
        var host: UInt64 = 1_000_000_000
        #expect(t.observe(hostTime: host, duration: d, newEngineReason: nil, droppedSinceLast: false, toSeconds: toSec) == nil)
        for _ in 0..<99 {
            host += 10_000_000
            #expect(t.observe(hostTime: host, duration: d, newEngineReason: nil, droppedSinceLast: false, toSeconds: toSec) == nil)
        }
        #expect(abs(t.position - 1.0) < 1e-9)
        // 1 バッファ欠落
        host += 20_000_000
        let g = t.observe(hostTime: host, duration: d, newEngineReason: nil, droppedSinceLast: true, toSeconds: toSec)
        #expect(g?.reason == "buffer_overflow")
        #expect(abs((g?.durationSeconds ?? 0) - 0.01) < 1e-9)
        #expect(abs((g?.startSeconds ?? 0) - 1.0) < 1e-9)
        // 作り直しで 300 ms 空いた
        host += 310_000_000
        let g2 = t.observe(hostTime: host, duration: d, newEngineReason: "output_device_changed", droppedSinceLast: false, toSeconds: toSec)
        #expect(g2?.reason == "output_device_changed")
        #expect(abs((g2?.durationSeconds ?? 0) - 0.3) < 1e-9)
        #expect(abs(t.position - (1.0 + 0.01 + 0.01 + 0.3 + 0.01)) < 1e-9)
    }

    @Test func smallJitterIsNotAGap() {
        var t = TimelineTracker()
        var host: UInt64 = 0
        _ = t.observe(hostTime: host, duration: 0.01, newEngineReason: nil, droppedSinceLast: false, toSeconds: toSec)
        host += 10_002_000 // 2 µs の揺らぎ
        #expect(t.observe(hostTime: host, duration: 0.01, newEngineReason: nil, droppedSinceLast: false, toSeconds: toSec) == nil)
    }
}
