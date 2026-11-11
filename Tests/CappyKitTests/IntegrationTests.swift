import AVFoundation
import Foundation
import Testing
@testable import CappyKit

/// 実機の Core Audio を使う結合テスト。
///   CAPPY_INTEGRATION=1      集約デバイスの作り直しとタイムライン（権限が未許可でも実行可、相手側は無音になる）
///   CAPPY_INTEGRATION_TAP=1  afplay の音をタップし、元音声との相互相関で欠落とずれを確認（システムオーディオ録音の許可が必要）
@Suite(.serialized) struct IntegrationTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["CAPPY_INTEGRATION"] == "1" }
    static var tapEnabled: Bool { ProcessInfo.processInfo.environment["CAPPY_INTEGRATION_TAP"] == "1" }

    func newStore() throws -> SessionStore {
        let dir = try TestSupport.tempDir()
        let store = SessionStore(directory: dir, metadata: SessionMetadata(id: UUID().uuidString, name: "it"))
        try store.save()
        return store
    }

    @Test(.enabled(if: IntegrationTests.enabled))
    func rebuildKeepsTracksAligned() async throws {
        let store = try newStore()
        let spec = RecordTargetSpec(system: true)
        let recorder = Recorder(options: RecorderOptions(targets: spec, micEnabled: true, micUID: nil), session: store)
        try recorder.start(resolved: try TargetResolver.resolve(spec))
        try await Task.sleep(nanoseconds: 2_000_000_000)
        recorder.simulateRebuild(reason: "test_rebuild")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try await recorder.stop(reason: "test")
        let m = store.metadata
        let durations = m.tracks.compactMap(\.durationMs)
        #expect(durations.count == m.tracks.count)
        // 作り直しの欠落は無音で補填されるので、実時間（約 4 秒）とほぼ一致し、トラック間で揃う
        for d in durations { #expect(abs(d - 4000) < 300, "duration \(d)") }
        #expect((durations.max() ?? 0) - (durations.min() ?? 0) <= 50)
        #expect(m.gaps.allSatisfy { $0.reason == "test_rebuild" })
        try SessionProcessing.convert(store)
        for t in store.metadata.tracks {
            let ms = SendFileConverter.durationMs(of: store.url(for: t.sendFile!)) ?? 0
            #expect(abs(ms - (t.durationMs ?? 0)) < 30)
        }
    }

    @Test(.enabled(if: IntegrationTests.tapEnabled))
    func tapMatchesSourceAudio() async throws {
        #expect(Permissions.audioCaptureStatus() == .authorized, "システムオーディオ録音の許可が必要です")
        let dir = try TestSupport.tempDir()
        // 既知の音声: 周波数が変化するチャープ（相互相関のピークが一意になる）
        let source = dir.appendingPathComponent("source.wav")
        try writeChirp(source, seconds: 4)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [source.path]
        try player.run()
        defer { if player.isRunning { player.terminate() } }
        // afplay が音声プロセスとして現れるまで待つ
        var resolved: ResolvedTargets?
        for _ in 0..<50 {
            if let r = try? TargetResolver.resolve(RecordTargetSpec(pids: [player.processIdentifier])) { resolved = r; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let r = try #require(resolved)
        let store = try newStore()
        let recorder = Recorder(options: RecorderOptions(targets: RecordTargetSpec(pids: [player.processIdentifier]),
                                                         micEnabled: false, micUID: nil), session: store)
        try recorder.start(resolved: r)
        player.waitUntilExit()
        try await Task.sleep(nanoseconds: 300_000_000)
        try await recorder.stop(reason: "test")
        try SessionProcessing.convert(store)
        #expect(store.metadata.gaps.isEmpty)

        let rec = try samples16k(store.url(for: store.metadata.track(.remote)!.sendFile!))
        let src = try samples16k(SendFileConverter.convert(input: source, outputBase: dir.appendingPathComponent("src")).url)
        // 録音のどこに元音声があるか（相互相関）。開始が少し遅れるので、元音声の 0.5 秒以降の 2 秒で探す
        let probe = Array(src[8000..<40000])
        var best = (lag: 0, corr: -1.0)
        let normP = sqrt(probe.reduce(0) { $0 + Double($1 * $1) })
        var lag = 0
        while lag + probe.count <= rec.count {
            var dot = 0.0, norm = 0.0
            for i in stride(from: 0, to: probe.count, by: 2) {
                dot += Double(probe[i] * rec[lag + i])
                norm += Double(rec[lag + i] * rec[lag + i])
            }
            let c = dot / (normP / sqrt(2) * sqrt(norm) + 1e-9)
            if c > best.corr { best = (lag, c) }
            lag += 4
        }
        #expect(best.corr > 0.8, "相関が低い: \(best.corr)")
        // 見つかった位置から後ろ 2 秒も一致する（途中の欠落・ずれがない）
        let tailStart = best.lag + 32000
        if tailStart + 16000 <= rec.count, 40000 + 16000 <= src.count {
            var dot = 0.0, n1 = 0.0, n2 = 0.0
            for i in 0..<16000 {
                let a = Double(src[40000 + i]), b = Double(rec[tailStart + i])
                dot += a * b; n1 += a * a; n2 += b * b
            }
            #expect(dot / sqrt(n1 * n2 + 1e-12) > 0.8)
        }
    }

    func writeChirp(_ url: URL, seconds: Double) throws {
        let rate = 48_000.0
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                                            AVLinearPCMIsFloatKey: false])
        let n = Int(seconds * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / rate
            let freq = 200 + 1800 * (t / seconds)
            phase += 2 * .pi * freq / rate
            buf.floatChannelData![0][i] = Float(0.4 * sin(phase))
        }
        try f.write(from: buf)
    }

    func samples16k(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }
}
