import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import CappyKit

@Suite struct MicMuteTests {
    @Test func applyOpensAndClosesIntervals() {
        var mutes: [SessionMute] = []
        SessionMute.apply(muted: true, atMs: 1000, to: &mutes)
        SessionMute.apply(muted: true, atMs: 1500, to: &mutes) // 二重のミュートは無視
        SessionMute.apply(muted: false, atMs: 3000, to: &mutes)
        SessionMute.apply(muted: false, atMs: 3500, to: &mutes) // 二重の解除も無視
        SessionMute.apply(muted: true, atMs: 5000, to: &mutes)
        #expect(mutes == [SessionMute(startMs: 1000, endMs: 3000), SessionMute(startMs: 5000)])
        #expect(SessionMute.totalMs(mutes, untilMs: 6000) == 3000)
    }

    @Test func sessionJSONWithoutMutesStillDecodes() throws {
        var m = SessionMetadata(id: "abc", name: nil)
        let old = try SessionStore.encode(m)
        #expect(!String(decoding: old, as: UTF8.self).contains("mic_mutes"))
        #expect(try SessionStore.decode(old).micMutes == nil)

        m.micMutes = [SessionMute(startMs: 10, endMs: 20)]
        let data = try SessionStore.encode(m)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"mic_mutes\""))
        #expect(text.contains("\"end_ms\""))
        #expect(try SessionStore.decode(data) == m)
    }

    /// IOProc と同じ経路でレコードを流し、ミュート中だけマイクが無音になり、時刻がずれないことを確かめる
    @Test func writerZeroesMicWhileMuted() async throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true)!
        let io = CaptureIO(remote: TrackLayout(bufferIndices: [0], format: fmt),
                           mic: TrackLayout(bufferIndices: [1], format: fmt), reason: nil)
        let remote = CollectingSink(), mic = CollectingSink()
        let writer = CaptureWriter(io: io, sinks: [.remote: [remote], .mic: [mic]])
        let changes = ChangeLog()
        writer.onMicMuteChanged = { muted, ms in changes.append(muted, ms) }
        writer.start()

        let frames = 480 // 10 ms
        var host: UInt64 = 1_000_000_000
        // ホストタイムの刻みを 10 ms に合わせる（欠落と判定されないように）
        let tenMs = UInt64((0.01 / HostTime.toSeconds(1)).rounded())
        func feedTimed(_ count: Int) {
            for _ in 0..<count {
                feedRecord(io, frames: frames, host: host)
                host += tenMs
            }
        }
        feedTimed(10)            // 0–100 ms: 通常
        try await waitUntil { mic.frames >= frames * 10 }
        writer.micMuted.store(true, ordering: .relaxed)
        feedTimed(10)            // 100–200 ms: ミュート
        try await waitUntil { mic.frames >= frames * 20 }
        writer.micMuted.store(false, ordering: .relaxed)
        feedTimed(10)            // 200–300 ms: 解除
        io.stopped.store(true, ordering: .releasing)
        await writer.stopAndDrain()

        #expect(remote.frames == frames * 30)
        #expect(mic.frames == frames * 30)
        let samples = mic.samples
        #expect(samples[0..<(frames * 10)].allSatisfy { $0 != 0 })
        #expect(samples[(frames * 10)..<(frames * 20)].allSatisfy { $0 == 0 })
        #expect(samples[(frames * 20)..<(frames * 30)].allSatisfy { $0 != 0 })
        #expect(remote.samples.allSatisfy { $0 != 0 })
        #expect(changes.items.map(\.0) == [true, false])
        #expect(changes.items.map(\.1) == [100, 200])
        #expect((writer.overallPeaks[.mic] ?? 0) > 0)
    }

    @Test func registryListsLiveProcessesAndDropsStaleOnes() throws {
        let dir = try TestSupport.tempDir()
        let me = getpid()
        let start = try #require(RecordingRegistry.processStartMicros(me))
        try RecordingRegistry.write(.init(pid: me, processStart: start, session: "/tmp/s", name: "x", hasMic: true, micMuted: true), in: dir)
        // 同じ PID でも開始時刻が違えば別のプロセス（PID の再利用）とみなす
        try RecordingRegistry.write(.init(pid: 1, processStart: 42, session: "/tmp/old", name: nil, hasMic: true, micMuted: false), in: dir)
        let list = RecordingRegistry.list(in: dir)
        #expect(list.map(\.pid) == [me])
        #expect(list.first?.micMuted == true)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("record-1.json").path))
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("record-\(me).json").path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        RecordingRegistry.remove(pid: me, in: dir)
        #expect(RecordingRegistry.list(in: dir).isEmpty)
    }
}

/// remote は 0.25、mic は 0.5 の一定値で 1 レコードを書く
private func feedRecord(_ io: CaptureIO, frames: Int, host: UInt64) {
    let abl = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(abl.unsafeMutablePointer) }
    let r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    let m = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer { r.deallocate(); m.deallocate() }
    r.initialize(repeating: 0.25, count: frames)
    m.initialize(repeating: 0.5, count: frames)
    let bytes = UInt32(frames * MemoryLayout<Float>.size)
    abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: r)
    abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: m)
    var ts = AudioTimeStamp()
    ts.mHostTime = host
    ts.mFlags = .hostTimeValid
    io.handle(abl.unsafePointer, &ts)
}

private func waitUntil(timeout: Double = 5, _ cond: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !cond() {
        guard Date() < deadline else { Issue.record("timed out"); return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

private final class ChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [(Bool, Int64)] = []
    var items: [(Bool, Int64)] { lock.withLock { _items } }
    func append(_ muted: Bool, _ ms: Int64) { lock.withLock { _items.append((muted, ms)) } }
}

private final class CollectingSink: AudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _samples: [Float] = []
    var samples: [Float] { lock.withLock { _samples } }
    var frames: Int { lock.withLock { _samples.count } }
    var failure: Error? { nil }
    func start(format: AVAudioFormat, track: TrackID) throws {}
    func consume(_ buffer: AVAudioPCMBuffer, at hostTime: UInt64) {
        guard let p = buffer.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: p, count: Int(buffer.frameLength)))
        lock.withLock { _samples += chunk }
    }
    func finish() async throws {}
}

@Suite struct KeyInputParserTests {
    private func feed(_ p: inout KeyInputParser, _ bytes: [UInt8]) -> [KeyInputParser.Event] {
        bytes.compactMap { p.feed($0) }
    }

    @Test func spaceTogglesOnlyWhenNothingIsTyped() {
        var p = KeyInputParser()
        #expect(feed(&p, [0x20]) == [.toggleMute])
        #expect(feed(&p, Array("a b".utf8)) == [.edited, .edited, .edited])
        #expect(p.text == "a b")
        #expect(feed(&p, [0x0D]) == [.marker(label: "a b")])
        #expect(p.text.isEmpty)
        #expect(feed(&p, [0x20, 0x0D]) == [.toggleMute, .marker(label: nil)])
    }

    @Test func fullWidthSpaceTogglesAndJapaneseLabelsWork() {
        var p = KeyInputParser()
        #expect(feed(&p, Array("\u{3000}".utf8)) == [.toggleMute])
        #expect(feed(&p, Array("議題\u{3000}2".utf8)) == [.edited, .edited, .edited, .edited])
        #expect(feed(&p, [0x7F]) == [.edited]) // Backspace は 1 文字（バイトではなく）
        #expect(p.text == "議題\u{3000}")
        #expect(feed(&p, [0x0A]) == [.marker(label: "議題")])
    }

    @Test func escapeSequencesAndControlCharsAreIgnored() {
        var p = KeyInputParser()
        // ↑ ← F1(ESC O P) Alt+x と Tab・Ctrl-A
        #expect(feed(&p, [0x1B, 0x5B, 0x41, 0x1B, 0x5B, 0x44, 0x1B, 0x4F, 0x50, 0x1B, 0x78, 0x09, 0x01]).isEmpty)
        #expect(p.text.isEmpty)
        #expect(feed(&p, [0x20]) == [.toggleMute])
        _ = feed(&p, Array("abc".utf8))
        #expect(feed(&p, [0x15]) == [.edited]) // Ctrl-U
        #expect(p.text.isEmpty)
        #expect(feed(&p, [0x7F]).isEmpty) // 空のときの Backspace は何もしない
    }

    @Test func brokenUTF8IsDropped() {
        var p = KeyInputParser()
        #expect(feed(&p, [0x80, 0xE8, 0x41]) == [.edited]) // 継続バイトだけ・途中で途切れた文字は捨てる
        #expect(p.text == "A")
    }
}
