import AVFoundation
import Foundation
import Synchronization

/// リングバッファからレコードを取り出し、トラック（remote / mic）に振り分けてシンクに配る（非リアルタイムスレッド）
final class CaptureWriter: @unchecked Sendable {
    struct Stats {
        var peaks: [TrackID: Float] = [:]
        var droppedRecords = 0
        var ringUsage: Double = 0
        var gaps = 0
    }

    /// 録音全体を通したピーク（無音検出用）
    private var overallPeak: [TrackID: Float] = [:]
    var overallPeaks: [TrackID: Float] { lock.withLock { overallPeak } }

    private let lock = NSLock()
    private var current: CaptureIO
    private var pending: [CaptureIO] = []
    private var sinks: [TrackID: [AudioSink]]
    private let tracks: [TrackID]
    private var timeline = TimelineTracker()
    private var stopRequested = false
    private var thread: Thread?
    private let done = DispatchSemaphore(value: 0)
    private var stats = Stats()
    private var lastDropped = 0
    private var droppedTotal = 0
    private var pendingReason: String?
    private var scratch: UnsafeMutableRawPointer
    private var scratchSize: Int
    private var buffers: [TrackID: AVAudioPCMBuffer] = [:]

    /// 欠落区間が見つかったとき（タイムライン上の ms）
    var onGap: ((SessionGap) -> Void)?
    /// 最初のレコードを受け取ったとき（ホストタイム）
    var onFirstRecord: ((UInt64) -> Void)?

    init(io: CaptureIO, sinks: [TrackID: [AudioSink]]) {
        self.current = io
        self.sinks = sinks
        self.tracks = sinks.keys.sorted()
        scratchSize = 1 << 20
        scratch = .allocate(byteCount: scratchSize, alignment: 16)
    }

    deinit { scratch.deallocate() }

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "dev.cappy.writer"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    /// 集約デバイスを作り直したときに、新しい IO に切り替える（古い IO を読み切ってから）
    func switchTo(_ io: CaptureIO) {
        lock.withLock { pending.append(io) }
    }

    /// 停止要求。現在の IO（停止済み）を読み切ってから戻る
    func stopAndDrain() async {
        lock.withLock { stopRequested = true }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.done.wait()
                cont.resume()
            }
        }
    }

    func snapshot() -> Stats {
        lock.withLock {
            var s = stats
            s.droppedRecords = droppedTotal + current.ring.droppedCount - lastDropped
            s.ringUsage = Double(current.ring.usedBytes) / Double(current.ring.capacity)
            stats.peaks = [:]
            return s
        }
    }

    var elapsedSeconds: Double { lock.withLock { timeline.position } }
    var droppedRecords: Int { lock.withLock { droppedTotal + current.ring.droppedCount - lastDropped } }

    private func run() {
        while true {
            let processed = drainOnce()
            var finished = false
            lock.withLock {
                let io = current
                let empty = io.ring.availableToRead == 0
                if empty, io.stopped.load(ordering: .acquiring), !pending.isEmpty {
                    droppedTotal += io.ring.droppedCount - lastDropped
                    current = pending.removeFirst()
                    CappyLog.shared.debug("writer: 新しい集約デバイスの入力に切り替えました")
                    lastDropped = 0
                    pendingReason = current.reason
                    buffers = [:]
                } else if empty, stopRequested, io.stopped.load(ordering: .acquiring), pending.isEmpty {
                    droppedTotal += io.ring.droppedCount - lastDropped
                    lastDropped = io.ring.droppedCount
                    finished = true
                }
            }
            if finished { break }
            if processed == 0 { usleep(5_000) }
        }
        done.signal()
    }

    /// 読めるだけ読む。処理したレコード数を返す
    private func drainOnce() -> Int {
        let io = lock.withLock { current }
        let headerSize = MemoryLayout<CaptureRecordHeader>.size
        var count = 0
        var header = CaptureRecordHeader(hostTime: 0, remoteBytes: 0, micBytes: 0)
        while count < 256 {
            let ok = withUnsafeMutableBytes(of: &header) { io.ring.peek(into: $0.baseAddress!, count: headerSize) }
            guard ok else { break }
            let payload = Int(header.remoteBytes) + Int(header.micBytes)
            guard io.ring.availableToRead >= headerSize + payload else { break }
            io.ring.skip(headerSize)
            if payload > scratchSize {
                scratch.deallocate()
                scratchSize = payload * 2
                scratch = .allocate(byteCount: scratchSize, alignment: 16)
            }
            _ = io.ring.read(into: scratch, count: payload)
            process(io: io, header: header)
            count += 1
        }
        return count
    }

    private func process(io: CaptureIO, header: CaptureRecordHeader) {
        var trackBuffers: [TrackID: AVAudioPCMBuffer] = [:]
        var offset = 0
        if let layout = io.remote {
            if let b = makeBuffer(.remote, layout, bytes: Int(header.remoteBytes), offset: offset) { trackBuffers[.remote] = b }
            offset += Int(header.remoteBytes)
        }
        if let layout = io.mic {
            if let b = makeBuffer(.mic, layout, bytes: Int(header.micBytes), offset: offset) { trackBuffers[.mic] = b }
        }
        guard let ref = trackBuffers[.remote] ?? trackBuffers[.mic] else { return }
        let duration = Double(ref.frameLength) / ref.format.sampleRate

        let (gap, isFirst) = lock.withLock { () -> (TimelineTracker.Gap?, Bool) in
            let dropped = io.ring.droppedCount > lastDropped
            if dropped {
                droppedTotal += io.ring.droppedCount - lastDropped
                lastDropped = io.ring.droppedCount
            }
            let first = timeline.startHostTime == nil
            let r = pendingReason
            pendingReason = nil
            let g = timeline.observe(hostTime: header.hostTime, duration: duration,
                                     newEngineReason: first ? nil : r, droppedSinceLast: dropped)
            return (g, first)
        }
        if isFirst { onFirstRecord?(header.hostTime) }
        if let gap {
            if gap.durationSeconds > 0 {
                for track in tracks {
                    let fmt = trackBuffers[track]?.format ?? io.layout(for: track)?.format
                    if let fmt { writeSilence(track: track, format: fmt, seconds: gap.durationSeconds) }
                }
            }
            let startMs = Int64((gap.startSeconds * 1000).rounded())
            let endMs = Int64(((gap.startSeconds + gap.durationSeconds) * 1000).rounded())
            lock.withLock { stats.gaps += 1 }
            onGap?(SessionGap(startMs: startMs, endMs: endMs, reason: gap.reason))
        }
        for track in tracks {
            if let b = trackBuffers[track] {
                for s in sinks[track] ?? [] { s.consume(b, at: header.hostTime) }
                updatePeak(track, b)
            } else if let fmt = sinks[track]?.compactMap({ ($0 as? FileSink)?.format }).first {
                // 新しい集約デバイスにこのトラックがない場合（マイクが外れた等）は無音で揃える
                writeSilence(track: track, format: fmt, seconds: duration)
            }
        }
    }

    private func makeBuffer(_ track: TrackID, _ layout: TrackLayout, bytes: Int, offset: Int) -> AVAudioPCMBuffer? {
        let fmt = layout.format
        let n = layout.bufferIndices.count
        guard n > 0, bytes > 0 else { return nil }
        let perBuffer = bytes / n
        let bytesPerFrame = Int(fmt.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frames = AVAudioFrameCount(perBuffer / bytesPerFrame)
        var buf = buffers[track]
        if buf == nil || buf!.frameCapacity < frames || !(buf!.format.isEqual(fmt)) {
            buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: max(frames, 4096))
            buffers[track] = buf
        }
        guard let buf else { return nil }
        let abl = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)
        for i in 0..<min(n, abl.count) {
            guard let dst = abl[i].mData else { continue }
            memcpy(dst, scratch + offset + i * perBuffer, perBuffer)
            abl[i].mDataByteSize = UInt32(perBuffer)
        }
        buf.frameLength = frames
        return buf
    }

    private func writeSilence(track: TrackID, format: AVAudioFormat, seconds: Double) {
        var remaining = AVAudioFrameCount((seconds * format.sampleRate).rounded())
        while remaining > 0 {
            let n = min(remaining, AVAudioFrameCount(format.sampleRate))
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return }
            b.frameLength = n
            let abl = UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList)
            for i in 0..<abl.count {
                if let d = abl[i].mData { memset(d, 0, Int(abl[i].mDataByteSize)) }
            }
            for s in sinks[track] ?? [] { s.consume(b, at: 0) }
            remaining -= n
        }
    }

    private func updatePeak(_ track: TrackID, _ b: AVAudioPCMBuffer) {
        guard let ch = b.floatChannelData else { return }
        let frames = Int(b.frameLength)
        let channels = Int(b.format.channelCount)
        var peak: Float = 0
        if b.format.isInterleaved {
            let p = ch[0]
            for i in 0..<(frames * channels) { peak = max(peak, abs(p[i])) }
        } else {
            for c in 0..<channels {
                let p = ch[c]
                for i in 0..<frames { peak = max(peak, abs(p[i])) }
            }
        }
        lock.withLock {
            stats.peaks[track] = max(stats.peaks[track] ?? 0, peak)
            overallPeak[track] = max(overallPeak[track] ?? 0, peak)
        }
    }
}

extension CaptureIO {
    func layout(for track: TrackID) -> TrackLayout? {
        switch track {
        case .remote: return remote
        case .mic: return mic
        case .mix: return nil
        }
    }
}
