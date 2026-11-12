import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// IOProc が書くレコードのヘッダ
struct CaptureRecordHeader {
    var hostTime: UInt64
    var remoteBytes: UInt32
    var micBytes: UInt32
}

/// 1 トラック分のバッファ配置（集約デバイスの入力バッファ中の位置）
struct TrackLayout: @unchecked Sendable {
    /// AudioBufferList 内のインデックス（インターリーブなら 1 個、非インターリーブならチャンネル数）
    var bufferIndices: [Int]
    var format: AVAudioFormat
}

/// IOProc とライターで共有する状態（IOProc 側はロックもメモリ確保もしない）
final class CaptureIO: @unchecked Sendable {
    let ring: RingBuffer
    let remote: TrackLayout?
    let mic: TrackLayout?
    let reason: String?
    private let remoteIdx: UnsafeMutableBufferPointer<Int>
    private let micIdx: UnsafeMutableBufferPointer<Int>
    private let zeros: UnsafeMutableRawPointer
    private static let zeroBytes = 1 << 16
    let callbackCount = Atomic<Int>(0)
    let firstHostTime = Atomic<UInt64>(0)
    let stopped = Atomic<Bool>(false)

    init(remote: TrackLayout?, mic: TrackLayout?, reason: String?) {
        self.remote = remote
        self.mic = mic
        self.reason = reason
        remoteIdx = .allocate(capacity: max(1, remote?.bufferIndices.count ?? 0))
        micIdx = .allocate(capacity: max(1, mic?.bufferIndices.count ?? 0))
        for (i, v) in (remote?.bufferIndices ?? []).enumerated() { remoteIdx[i] = v }
        for (i, v) in (mic?.bufferIndices ?? []).enumerated() { micIdx[i] = v }
        zeros = .allocate(byteCount: Self.zeroBytes, alignment: 16)
        zeros.initializeMemory(as: UInt8.self, repeating: 0, count: Self.zeroBytes)
        // 約 10 秒分を確保（最低 4 MB）
        var bytesPerSecond = 0.0
        for l in [remote, mic].compactMap({ $0 }) {
            bytesPerSecond += l.format.sampleRate * Double(l.format.streamDescription.pointee.mBytesPerFrame
                * (l.format.isInterleaved ? 1 : l.format.channelCount))
        }
        ring = RingBuffer(capacity: max(4 << 20, Int(bytesPerSecond * 10)))
    }

    deinit {
        remoteIdx.deallocate()
        micIdx.deallocate()
        zeros.deallocate()
    }

    var remoteCount: Int { remote?.bufferIndices.count ?? 0 }
    var micCount: Int { mic?.bufferIndices.count ?? 0 }

    /// リアルタイムスレッドから呼ばれる。リングバッファに書くだけ
    @inline(__always)
    func handle(_ input: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let ts = time.pointee
        let host = (ts.mFlags.contains(.hostTimeValid) && ts.mHostTime != 0) ? ts.mHostTime : mach_absolute_time()
        if callbackCount.load(ordering: .relaxed) == 0 { firstHostTime.store(host, ordering: .relaxed) }
        callbackCount.add(1, ordering: .relaxed)

        let nr = remoteCount, nm = micCount
        // 各トラックのバッファサイズは先頭バッファに揃える（非インターリーブ時も全チャンネル同サイズ）
        let remoteEach = nr > 0 && remoteIdx[0] < abl.count ? Int(abl[remoteIdx[0]].mDataByteSize) : 0
        let micEach = nm > 0 && micIdx[0] < abl.count ? Int(abl[micIdx[0]].mDataByteSize) : 0
        var header = CaptureRecordHeader(hostTime: host,
                                         remoteBytes: UInt32(remoteEach * nr),
                                         micBytes: UInt32(micEach * nm))
        withUnsafeBytes(of: &header) { hp in
            withUnsafeTemporaryAllocation(of: (UnsafeRawPointer, Int).self, capacity: 1 + nr + nm) { parts in
                parts[0] = (hp.baseAddress!, MemoryLayout<CaptureRecordHeader>.size)
                var k = 1
                for i in 0..<nr {
                    parts[k] = pointer(abl, remoteIdx[i], remoteEach); k += 1
                }
                for i in 0..<nm {
                    parts[k] = pointer(abl, micIdx[i], micEach); k += 1
                }
                _ = ring.write(UnsafeBufferPointer(rebasing: parts[0..<k]))
            }
        }
    }

    @inline(__always)
    private func pointer(_ abl: UnsafeMutableAudioBufferListPointer, _ index: Int, _ size: Int) -> (UnsafeRawPointer, Int) {
        if index < abl.count, let p = abl[index].mData, Int(abl[index].mDataByteSize) >= size {
            return (UnsafeRawPointer(p), size)
        }
        return (UnsafeRawPointer(zeros), min(size, Self.zeroBytes))
    }
}

/// プライベート集約デバイス（メイン = 既定出力、サブデバイス = マイク、タップ）と IOProc
final class CaptureEngine: @unchecked Sendable {
    let aggregateID: AudioObjectID
    let io: CaptureIO
    let outputUID: String
    let micUID: String?
    /// 作成時の集約デバイスの公称サンプルレート（トラックの形式はこのレートにそろえる）
    let sampleRate: Double
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private var destroyed = false

    init(tap: ProcessTap?, outputUID: String, micUID: String?, reason: String?) throws {
        self.outputUID = outputUID
        self.micUID = micUID

        var subdevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: outputUID]]
        if let micUID, micUID != outputUID {
            // マイク側はドリフト補正を有効にして、出力デバイスのクロックに合わせる
            subdevices.append([kAudioSubDeviceUIDKey: micUID, kAudioSubDeviceDriftCompensationKey: true])
        }
        var desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "cappy",
            kAudioAggregateDeviceUIDKey: "dev.cappy.aggregate." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subdevices,
        ]
        if let tap {
            // tapautostart を有効にすると、対象が音を出すまで IO が始まらない（無音区間のマイクも録れない）ため無効にする
            desc[kAudioAggregateDeviceTapAutoStartKey] = false
            desc[kAudioAggregateDeviceTapListKey] = [[kAudioSubTapUIDKey: tap.uid, kAudioSubTapDriftCompensationKey: true]]
        }
        var aggID = AudioObjectID(kAudioObjectUnknown)
        let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)
        guard st == noErr, aggID != kAudioObjectUnknown else {
            throw CoreAudioError(status: st, what: "AudioHardwareCreateAggregateDevice")
        }
        self.aggregateID = aggID
        self.sampleRate = Self.nominalSampleRate(aggID)
        do {
            let (remote, mic) = try Self.resolveLayout(aggregate: aggID, tap: tap, outputUID: outputUID, micUID: micUID,
                                                       deviceRate: sampleRate)
            io = CaptureIO(remote: remote, mic: mic, reason: reason)
        } catch {
            AudioHardwareDestroyAggregateDevice(aggID)
            throw error
        }
        CappyLog.shared.info(tr("Created the aggregate device id=\(aggID) rate=\(Int(sampleRate)) output=\(outputUID) mic=\(micUID ?? "-") ", ja: "集約デバイスを作成しました id=\(aggID) rate=\(Int(sampleRate)) output=\(outputUID) mic=\(micUID ?? "-") ")
            + "remote=\(io.remote.map { Self.describe($0.format) } ?? "-") micfmt=\(io.mic.map { Self.describe($0.format) } ?? "-")")
    }

    deinit { destroy() }

    /// 集約デバイスの公称サンプルレート（取れなければ 0）
    static func nominalSampleRate(_ device: AudioObjectID) -> Double {
        (try? CA.scalar(device, kAudioDevicePropertyNominalSampleRate, default: Float64(0))) ?? 0
    }

    /// 集約デバイスの現在の公称サンプルレート（録音中の変化の検出用）
    var currentSampleRate: Double { Self.nominalSampleRate(aggregateID) }

    /// ストリームの形式のサンプルレートを、実際に IOProc に届くレートに直す。
    ///
    /// 集約デバイスでは全ストリームが集約デバイスのクロック（メインのサブデバイス = 既定出力）で動き、
    /// IOProc 1 回あたりのフレーム数もそろう。タップのストリームは、データは集約デバイスのレートに変換されているのに、
    /// 形式（kAudioStreamPropertyVirtualFormat）はタップ本来のレート（通常 48 kHz）を返すことがある。
    /// そのまま使うと、出力デバイスが 44.1 kHz のときに remote が 48 kHz と記録され、約 8.8% 速く再生される（#15）。
    static func correctedSampleRate(stream: Double, device: Double) -> Double {
        device > 0 ? device : stream
    }

    static func describe(_ f: AVAudioFormat) -> String {
        "\(Int(f.sampleRate))Hz/\(f.channelCount)ch/\(f.isInterleaved ? "i" : "n")"
    }

    /// 集約デバイスの入力ストリームをトラックに対応付ける。
    /// ストリームはサブデバイス（リスト順）の入力ストリーム、続いてタップの順に並ぶ。
    static func resolveLayout(aggregate: AudioObjectID, tap: ProcessTap?, outputUID: String,
                              micUID: String?, deviceRate: Double) throws -> (TrackLayout?, TrackLayout?) {
        let streams = try CA.array(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: AudioStreamID.self)
        var formats: [AudioStreamBasicDescription] = []
        for s in streams {
            formats.append(try CA.scalar(s, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription()))
        }
        func inputStreamCount(_ uid: String) -> Int {
            (try? AudioDevices.device(uid: uid))?.inputStreamCount ?? 0
        }
        let sameDevice = micUID != nil && micUID == outputUID
        let outputStreams = sameDevice ? 0 : inputStreamCount(outputUID)
        let micStreams = micUID.map { inputStreamCount($0) } ?? 0
        let tapStreams = tap == nil ? 0 : 1
        var micStreamIndex: Int?
        var tapStreamIndex: Int?
        if streams.count == outputStreams + micStreams + tapStreams {
            if micUID != nil, micStreams > 0 { micStreamIndex = outputStreams }
            if tap != nil { tapStreamIndex = streams.count - 1 }
        } else {
            CappyLog.shared.warning(tr("The aggregate device has an unexpected number of streams (actual \(streams.count), ", ja: "集約デバイスのストリーム数が想定と異なります（実際 \(streams.count)、")
                + tr("expected out=\(outputStreams) mic=\(micStreams) tap=\(tapStreams)). Treating the last ones as the tap", ja: "想定 out=\(outputStreams) mic=\(micStreams) tap=\(tapStreams)）。末尾をタップとみなします"))
            if tap != nil, !streams.isEmpty { tapStreamIndex = streams.count - 1 }
            if micUID != nil {
                let candidate = min(outputStreams, streams.count - 1 - (tap == nil ? 0 : 1))
                if candidate >= 0, candidate != tapStreamIndex { micStreamIndex = candidate }
            }
        }
        if let micUID, micStreamIndex == nil {
            CappyLog.shared.warning(tr("No input stream found for microphone \(micUID)", ja: "マイク \(micUID) の入力ストリームが見つかりません"))
        }
        // ストリーム → バッファインデックス
        var bufferStart: [Int] = []
        var b = 0
        for f in formats {
            bufferStart.append(b)
            let nonInterleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            b += nonInterleaved ? Int(f.mChannelsPerFrame) : 1
        }
        func layout(_ index: Int?) throws -> TrackLayout? {
            guard let i = index else { return nil }
            var asbd = formats[i]
            let rate = correctedSampleRate(stream: asbd.mSampleRate, device: deviceRate)
            if rate != asbd.mSampleRate {
                CappyLog.shared.info(tr("Stream \(i) reports \(Int(asbd.mSampleRate)) Hz but the aggregate device runs at \(Int(rate)) Hz; using \(Int(rate)) Hz",
                                        ja: "stream \(i) の形式は \(Int(asbd.mSampleRate)) Hz ですが、集約デバイスは \(Int(rate)) Hz で動いているため \(Int(rate)) Hz として扱います"))
                asbd.mSampleRate = rate
            }
            guard let fmt = AVAudioFormat(streamDescription: &asbd) else {
                throw CappyError.io(tr("Unsupported audio format (stream \(i))", ja: "未対応の音声フォーマットです（stream \(i)）"))
            }
            let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            let n = nonInterleaved ? Int(asbd.mChannelsPerFrame) : 1
            return TrackLayout(bufferIndices: Array(bufferStart[i]..<(bufferStart[i] + n)), format: fmt)
        }
        return (try layout(tapStreamIndex), try layout(micStreamIndex))
    }

    func start() throws {
        let io = self.io
        var pid: AudioDeviceIOProcID?
        var st = AudioDeviceCreateIOProcIDWithBlock(&pid, aggregateID, nil) { _, inInputData, inInputTime, _, _ in
            io.handle(inInputData, inInputTime)
        }
        guard st == noErr, let pid else { throw CoreAudioError(status: st, what: "AudioDeviceCreateIOProcIDWithBlock") }
        procID = pid
        st = AudioDeviceStart(aggregateID, pid)
        guard st == noErr else { throw CoreAudioError(status: st, what: "AudioDeviceStart") }
        running = true
    }

    /// 停止（戻った時点で IOProc はもう呼ばれない）
    func stop() {
        if running, let procID {
            let st = AudioDeviceStop(aggregateID, procID)
            if st != noErr { CappyLog.shared.warning(tr("AudioDeviceStop failed: \(osStatusString(st))", ja: "AudioDeviceStop に失敗しました: \(osStatusString(st))")) }
            running = false
        }
        io.stopped.store(true, ordering: .releasing)
    }

    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        stop()
        if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
        procID = nil
        AudioHardwareDestroyAggregateDevice(aggregateID)
    }
}
