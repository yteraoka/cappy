import AVFoundation
import CoreAudio
import Foundation

/// 録音対象の指定
public struct RecordTargetSpec: Sendable, Equatable {
    public var bundleIDs: [String]
    public var pids: [Int32]
    public var system: Bool

    public init(bundleIDs: [String] = [], pids: [Int32] = [], system: Bool = false) {
        self.bundleIDs = bundleIDs
        self.pids = pids
        self.system = system
    }

    public var isEmpty: Bool { bundleIDs.isEmpty && pids.isEmpty && !system }
}

public struct ResolvedTargets: Sendable {
    public var tapMode: ProcessTapModeDescription
    public var targets: [SessionTarget]
    public var objectIDs: [AudioObjectID]
}

/// 外部に公開するタップモード（内部の ProcessTap.Mode と対応）
public enum ProcessTapModeDescription: Sendable, Equatable {
    case processes([AudioObjectID])
    case systemExcluding([AudioObjectID])

    var mode: ProcessTap.Mode {
        switch self {
        case .processes(let ids): return .processes(ids)
        case .systemExcluding(let ids): return .systemExcluding(ids)
        }
    }
}

public enum TargetResolver {
    /// --app（前方一致）/ --pid / --system を音声プロセスオブジェクトに解決する
    public static func resolve(_ spec: RecordTargetSpec) throws -> ResolvedTargets {
        if spec.system {
            var exclude: [AudioObjectID] = []
            if let me = AudioProcesses.objectID(forPID: getpid()) { exclude.append(me) }
            return ResolvedTargets(tapMode: .systemExcluding(exclude), targets: [SessionTarget(kind: .system)], objectIDs: exclude)
        }
        let processes = try AudioProcesses.list()
        var ids: [AudioObjectID] = []
        var targets: [SessionTarget] = []
        for prefix in spec.bundleIDs {
            let matched = processes.filter { !$0.bundleID.isEmpty && $0.bundleID.hasPrefix(prefix) }
            if matched.isEmpty {
                CappyLog.shared.warning(tr("No audio process matches bundle ID \(prefix)", ja: "bundle ID \(prefix) に一致する音声プロセスがありません"))
            }
            ids.append(contentsOf: matched.map(\.objectID))
            targets.append(SessionTarget(kind: .app, bundleID: prefix, matchedPIDs: matched.map(\.pid)))
        }
        for pid in spec.pids {
            if let obj = AudioProcesses.objectID(forPID: pid) {
                ids.append(obj)
                targets.append(SessionTarget(kind: .pid, pid: pid, matchedPIDs: [pid]))
            } else {
                CappyLog.shared.warning(tr("PID \(pid) is not found as an audio process", ja: "PID \(pid) は音声プロセスとして見つかりません"))
                targets.append(SessionTarget(kind: .pid, pid: pid, matchedPIDs: []))
            }
        }
        var seen = Set<AudioObjectID>()
        ids = ids.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else {
            throw CappyError.targetNotFound(
                tr("No process to record was found (\(describe(spec)))", ja: "録音対象のプロセスが見つかりません（\(describe(spec))）"),
                hint: tr("Check the audio processes with `cappy apps`. Use --wait to wait until the target starts playing audio", ja: "`cappy apps` で音声プロセスを確認してください。対象が音声を出し始めるまで待つには --wait を指定します"))
        }
        return ResolvedTargets(tapMode: .processes(ids.sorted()), targets: targets, objectIDs: ids.sorted())
    }

    public static func describe(_ spec: RecordTargetSpec) -> String {
        var parts: [String] = spec.bundleIDs.map { "--app \($0)" }
        parts += spec.pids.map { "--pid \($0)" }
        if spec.system { parts.append("--system") }
        return parts.joined(separator: " ")
    }
}

public struct RecorderOptions: Sendable {
    public var targets: RecordTargetSpec
    public var micEnabled: Bool
    /// nil ならシステムの既定入力（変更にも追従する）
    public var micUID: String?
    public var diskWarnBytes: Int64
    public var diskStopBytes: Int64
    /// マイクをミュートした状態で録音を始める
    public var micMutedAtStart: Bool

    public init(targets: RecordTargetSpec, micEnabled: Bool, micUID: String?,
                diskWarnBytes: Int64 = 1 << 30, diskStopBytes: Int64 = 300 << 20,
                micMutedAtStart: Bool = false) {
        self.targets = targets
        self.micEnabled = micEnabled
        self.micUID = micUID
        self.micMutedAtStart = micMutedAtStart
        self.diskWarnBytes = diskWarnBytes
        self.diskStopBytes = diskStopBytes
    }
}

public struct RecorderStatus: Sendable {
    public var elapsed: TimeInterval
    public var peaks: [TrackID: Float]
    public var droppedRecords: Int
    public var ringUsage: Double
    public var gaps: Int
    /// マイクをミュートしているか
    public var micMuted: Bool = false
}

/// タップとマイクを 1 つの集約デバイスにまとめて録音する
public final class Recorder: @unchecked Sendable {
    public let options: RecorderOptions
    public let session: SessionStore

    private let control = DispatchQueue(label: "dev.cappy.recorder")
    private var tap: ProcessTap?
    private var engine: CaptureEngine?
    private var writer: CaptureWriter?
    private var sinks: [TrackID: [AudioSink]] = [:]
    private var fileSinks: [TrackID: FileSink] = [:]
    private var running = false
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var debounce: [String: DispatchWorkItem] = [:]
    private var monitorTimer: DispatchSourceTimer?
    private var diskWarned = false
    private var lastCallbackCount = 0
    private var stallTicks = 0
    private var rebuildPending = false
    private var lastVerboseLog = Date()
    private var currentMicUID: String?
    private var currentOutputUID: String = ""

    /// 録音全体を通して完全に無音だったトラック（stop 後に有効）
    public private(set) var silentTracks: [TrackID] = []

    /// 録音を続けられない障害（ディスク不足・書き込み失敗）
    public var onFatalError: (@Sendable (CappyError) -> Void)?

    /// トラックごとに追加するシンク（リアルタイム文字起こしなど）。start の前に設定する
    public var extraSinks: ((TrackID) -> [AudioSink])?

    public init(options: RecorderOptions, session: SessionStore) {
        self.options = options
        self.session = session
    }

    // MARK: 開始

    public func start(resolved: ResolvedTargets) throws {
        try control.sync {
            let outputUID = try Self.defaultOutputUID()
            currentOutputUID = outputUID
            currentMicUID = options.micEnabled ? try resolveMicUID() : nil

            do {
                tap = try ProcessTap(mode: resolved.tapMode.mode)
            } catch {
                throw CappyError.io(tr("Cannot create the process tap: \(error)", ja: "タップを作成できません: \(error)"),
                                    hint: tr("macOS 15 or later is required. Check the permissions with `cappy doctor`", ja: "macOS 15 以降が必要です。`cappy doctor` で権限を確認してください"))
            }
            let engine: CaptureEngine
            do {
                engine = try CaptureEngine(tap: tap, outputUID: outputUID, micUID: currentMicUID, reason: nil)
            } catch {
                tap?.destroy()
                throw CappyError.io(tr("Cannot create the aggregate device: \(error)", ja: "集約デバイスを作成できません: \(error)"))
            }
            self.engine = engine

            // トラックとシンク
            var tracks: [SessionTrack] = []
            if let layout = engine.io.remote {
                let sink = FileSink(url: session.url(for: "remote.caf"))
                try sink.start(format: layout.format, track: .remote)
                fileSinks[.remote] = sink
                sinks[.remote] = [sink]
                for extra in extraSinks?(.remote) ?? [] {
                    try extra.start(format: layout.format, track: .remote)
                    sinks[.remote]!.append(extra)
                }
                var t = SessionTrack(id: .remote, file: "remote.caf", sampleRate: layout.format.sampleRate,
                                     channels: Int(layout.format.channelCount))
                t.deviceUID = outputUID
                tracks.append(t)
            } else {
                engine.destroy()
                tap?.destroy()
                throw CappyError.io(tr("The aggregate device has no tap stream", ja: "集約デバイスにタップのストリームがありません"))
            }
            if let layout = engine.io.mic {
                let sink = FileSink(url: session.url(for: "mic.caf"))
                try sink.start(format: layout.format, track: .mic)
                fileSinks[.mic] = sink
                sinks[.mic] = [sink]
                for extra in extraSinks?(.mic) ?? [] {
                    try extra.start(format: layout.format, track: .mic)
                    sinks[.mic]!.append(extra)
                }
                var t = SessionTrack(id: .mic, file: "mic.caf", sampleRate: layout.format.sampleRate,
                                     channels: Int(layout.format.channelCount))
                t.deviceUID = currentMicUID
                t.deviceName = currentMicUID.flatMap { try? AudioDevices.device(uid: $0)?.name }
                tracks.append(t)
            } else if options.micEnabled {
                Console.print(tr("Warning: no microphone input stream was found, so the microphone is not recorded", ja: "警告: マイクの入力ストリームが見つからないため、マイクは録音しません"))
            }

            let writer = CaptureWriter(io: engine.io, sinks: sinks)
            writer.onGap = { [weak self] gap in self?.recordGap(gap) }
            writer.onFirstRecord = { [weak self] host in self?.recordStart(hostTime: host) }
            writer.onMicMuteChanged = { [weak self] muted, atMs in self?.recordMicMute(muted, atMs: atMs) }
            writer.micMuted.store(options.micMutedAtStart && fileSinks[.mic] != nil, ordering: .relaxed)
            self.writer = writer

            try session.update { m in
                m.targets = resolved.targets
                m.tracks = tracks
                m.startedAt = TimeFormat.iso8601(Date())
                m.recording = RecordingState(state: .recording)
                m.recording.outputDeviceUID = outputUID
            }

            writer.start()
            do {
                try engine.start()
            } catch {
                engine.destroy()
                tap?.destroy()
                throw CappyError.io(tr("Cannot start recording: \(error)", ja: "録音を開始できません: \(error)"))
            }
            running = true
            installListeners()
            startMonitor()
            CappyLog.shared.info(tr("Recording started tracks=\(tracks.map(\.id.rawValue))", ja: "録音を開始しました tracks=\(tracks.map(\.id.rawValue))"))
        }
    }

    private static func defaultOutputUID() throws -> String {
        let out = try AudioDevices.defaultOutputDevice()
        guard out != kAudioObjectUnknown else { throw CappyError.io(tr("No default output device", ja: "既定の出力デバイスがありません")) }
        return try CA.string(out, kAudioDevicePropertyDeviceUID)
    }

    private func resolveMicUID() throws -> String? {
        if let uid = options.micUID {
            guard (try? AudioDevices.device(uid: uid)) != nil else {
                throw CappyError.usage(tr("Input device \(uid) not found", ja: "入力デバイス \(uid) が見つかりません"), hint: tr("Check the UID with `cappy devices`", ja: "`cappy devices` で UID を確認してください"))
            }
            return uid
        }
        let dev = try AudioDevices.defaultInputDevice()
        guard dev != kAudioObjectUnknown else {
            Console.print(tr("Warning: there is no default input device, so the microphone is not recorded", ja: "警告: 既定の入力デバイスがないため、マイクは録音しません"))
            return nil
        }
        return try CA.string(dev, kAudioDevicePropertyDeviceUID)
    }

    private func recordStart(hostTime: UInt64) {
        let lag = HostTime.delta(HostTime.now(), hostTime)
        let start = Date().addingTimeInterval(-max(0, lag))
        _ = try? session.update { m in
            m.startedAt = TimeFormat.iso8601(start)
            m.recording.hostTimeStart = hostTime
            for i in m.tracks.indices { m.tracks[i].offsetMs = 0 }
        }
    }

    private func recordMicMute(_ muted: Bool, atMs: Int64) {
        CappyLog.shared.info(muted ? tr("Mic muted at=\(atMs)ms", ja: "マイクをミュートしました at=\(atMs)ms")
                                   : tr("Mic unmuted at=\(atMs)ms", ja: "マイクのミュートを解除しました at=\(atMs)ms"))
        _ = try? session.update { m in
            var mutes = m.micMutes ?? []
            SessionMute.apply(muted: muted, atMs: atMs, to: &mutes)
            m.micMutes = mutes
        }
    }

    private func recordGap(_ gap: SessionGap) {
        guard gap.endMs > gap.startMs else {
            CappyLog.shared.info(tr("Recreated the aggregate device (no gap) reason=\(gap.reason)", ja: "集約デバイスを作り直しました（欠落なし） reason=\(gap.reason)"))
            return
        }
        CappyLog.shared.warning(tr("Gap \(gap.startMs)–\(gap.endMs) ms reason=\(gap.reason)", ja: "欠落区間 \(gap.startMs)–\(gap.endMs) ms reason=\(gap.reason)"))
        _ = try? session.update { m in GapMerger.append(gap, to: &m.gaps) }
    }

    // MARK: 変化への追従

    private func installListeners() {
        func add(_ selector: AudioObjectPropertySelector, key: String, _ action: @escaping () -> Void) {
            let addr = CA.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.debounced(key, action)
            }
            var a = addr
            if AudioObjectAddPropertyListenerBlock(CA.system, &a, control, block) == noErr {
                listeners.append((addr, block))
            }
        }
        if !options.targets.system, !options.targets.bundleIDs.isEmpty {
            add(kAudioHardwarePropertyProcessObjectList, key: "processes") { [weak self] in self?.processesChanged() }
        }
        add(kAudioHardwarePropertyDefaultOutputDevice, key: "output") { [weak self] in
            guard let self else { return }
            let uid = (try? Self.defaultOutputUID()) ?? ""
            guard !uid.isEmpty, uid != self.currentOutputUID else { return }
            CappyLog.shared.info(tr("Default output device changed: \(self.currentOutputUID) → \(uid)", ja: "既定の出力デバイスが変わりました: \(self.currentOutputUID) → \(uid)"))
            Console.print(tr("The output device changed; switching the recording", ja: "出力デバイスが変わったため、録音を切り替えます"))
            self.rebuildEngine(reason: "output_device_changed")
        }
        if options.micEnabled, options.micUID == nil {
            add(kAudioHardwarePropertyDefaultInputDevice, key: "input") { [weak self] in
                guard let self else { return }
                let uid = try? self.resolveMicUID()
                guard uid != self.currentMicUID else { return }
                CappyLog.shared.info(tr("Default input device changed: \(self.currentMicUID ?? "-") → \(uid ?? "-")", ja: "既定の入力デバイスが変わりました: \(self.currentMicUID ?? "-") → \(uid ?? "-")"))
                Console.print(tr("The input device changed; switching the recording", ja: "入力デバイスが変わったため、録音を切り替えます"))
                self.rebuildEngine(reason: "input_device_changed")
            }
        }
    }

    private func removeListeners() {
        for (addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(CA.system, &a, control, block)
        }
        listeners.removeAll()
    }

    /// control キュー上で、連続した通知をまとめて 0.5 秒後に処理する
    private func debounced(_ key: String, _ action: @escaping () -> Void) {
        debounce[key]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            action()
        }
        debounce[key] = item
        control.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// 対象アプリの音声プロセスが増減したとき
    private func processesChanged() {
        guard let tap, case .processes(let currentIDs) = tap.mode else { return }
        guard let resolved = try? TargetResolver.resolve(options.targets),
              case .processes(let newIDs) = resolved.tapMode else { return }
        guard newIDs != currentIDs else { return }
        // 終了して減っただけなら作り直さない（消えたプロセスは音を出さないので害がない）
        guard !Set(newIDs).isSubset(of: Set(currentIDs)) else { return }
        let mergedIDs = Array(Set(newIDs).union(currentIDs.filter { AudioProcesses.info(objectID: $0) != nil })).sorted()
        CappyLog.shared.info(tr("Target audio processes changed: \(currentIDs) → \(newIDs)", ja: "対象の音声プロセスが変わりました: \(currentIDs) → \(newIDs)"))
        _ = try? session.update { m in
            // 一致した PID の記録を更新（既存の PID は残す）
            for i in m.targets.indices {
                guard let r = resolved.targets.first(where: { $0.kind == m.targets[i].kind && $0.bundleID == m.targets[i].bundleID && $0.pid == m.targets[i].pid }) else { continue }
                let merged = Set((m.targets[i].matchedPIDs ?? []) + (r.matchedPIDs ?? []))
                m.targets[i].matchedPIDs = merged.sorted()
            }
        }
        let newMode = ProcessTap.Mode.processes(mergedIDs)
        if tap.update(mode: newMode) { return }
        // 更新できなければタップから作り直す
        rebuildEngine(reason: "tap_rebuilt", newTapMode: newMode)
    }

    private func rebuildEngine(reason: String, newTapMode: ProcessTap.Mode? = nil) {
        guard running else { return }
        let old = engine
        old?.stop()
        engine = nil
        do {
            if let newTapMode {
                tap?.destroy()
                tap = try ProcessTap(mode: newTapMode)
            }
            let outputUID = try Self.defaultOutputUID()
            let micUID = options.micEnabled ? try resolveMicUID() : nil
            let new = try CaptureEngine(tap: tap, outputUID: outputUID, micUID: micUID, reason: reason)
            try new.start()
            writer?.switchTo(new.io)
            engine = new
            currentOutputUID = outputUID
            currentMicUID = micUID
            lastCallbackCount = 0
            stallTicks = 0
            rebuildPending = false
            old?.destroy()
            _ = try? session.update { m in m.recording.outputDeviceUID = outputUID }
        } catch {
            old?.destroy()
            CappyLog.shared.error(tr("Could not recreate the aggregate device (retrying in 2 seconds): \(error)", ja: "集約デバイスを作り直せませんでした（2 秒後に再試行）: \(error)"))
            rebuildPending = true
            control.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.running, self.engine == nil else { return }
                self.rebuildEngine(reason: reason)
            }
        }
    }

    /// テスト用: 出力デバイスの切替と同じ経路で集約デバイスを作り直す
    func simulateRebuild(reason: String) {
        control.async { [weak self] in self?.rebuildEngine(reason: reason) }
    }

    // MARK: 監視

    private func startMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.monitorTick() }
        timer.resume()
        monitorTimer = timer
    }

    private func monitorTick() {
        guard running else { return }
        // 書き込みエラー
        for (track, sink) in fileSinks {
            if let err = sink.failure {
                fatal(CappyError.io(tr("Failed to write the \(track.rawValue) track: \(err.localizedDescription)", ja: "\(track.rawValue) トラックの書き込みに失敗しました: \(err.localizedDescription)")))
                return
            }
        }
        // ディスクの空き
        if let free = FileSecurity.availableBytes(at: session.directory) {
            if free < options.diskStopBytes {
                fatal(CappyError.io(tr("Stopped recording because the disk is almost full (\(free >> 20) MB left)", ja: "ディスクの空き容量が不足したため録音を停止しました（残り \(free >> 20) MB）")))
                return
            }
            if free < options.diskWarnBytes, !diskWarned {
                diskWarned = true
                Console.print(tr("Warning: the disk is getting full (\(free >> 20) MB left)", ja: "警告: ディスクの空き容量が少なくなっています（残り \(free >> 20) MB）"))
                CappyLog.shared.warning(tr("Low disk space: \(free >> 20) MB", ja: "ディスクの空き容量が少ない: \(free >> 20) MB"))
            }
        }
        // 出力デバイスのサンプルレートが変わったら、新しいレートで作り直す（トラックの形式がずれないように）
        if let engine, !rebuildPending {
            let rate = engine.currentSampleRate
            if rate > 0, engine.sampleRate > 0, rate != engine.sampleRate {
                CappyLog.shared.info(tr("The sample rate of the aggregate device changed: \(Int(engine.sampleRate)) → \(Int(rate)) Hz", ja: "集約デバイスのサンプルレートが変わりました: \(Int(engine.sampleRate)) → \(Int(rate)) Hz"))
                rebuildEngine(reason: "sample_rate_changed")
                return
            }
        }
        // IOProc が止まっていないか（デバイスが消えた場合など）
        if let engine, !rebuildPending {
            let count = engine.io.callbackCount.load(ordering: .relaxed)
            if count == lastCallbackCount {
                stallTicks += 1
                if stallTicks >= 3 {
                    CappyLog.shared.warning(tr("IOProc has not been called for 6 seconds. Recreating the aggregate device", ja: "IOProc が 6 秒間呼ばれていません。集約デバイスを作り直します"))
                    rebuildEngine(reason: "device_stalled")
                }
            } else {
                stallTicks = 0
            }
            lastCallbackCount = count
        }
        if CappyLog.shared.verbose, Date().timeIntervalSince(lastVerboseLog) >= 10, let writer {
            lastVerboseLog = Date()
            let s = writer.snapshot()
            CappyLog.shared.debug(String(format: "stats dropped=%d ring=%.1f%% gaps=%d callbacks=%d",
                                         s.droppedRecords, s.ringUsage * 100, s.gaps,
                                         engine?.io.callbackCount.load(ordering: .relaxed) ?? 0))
        }
    }

    private func fatal(_ error: CappyError) {
        CappyLog.shared.error(error.message)
        let handler = onFatalError
        running = false
        handler?(error)
    }

    // MARK: 状態

    public func status() -> RecorderStatus {
        guard let writer else { return RecorderStatus(elapsed: 0, peaks: [:], droppedRecords: 0, ringUsage: 0, gaps: 0) }
        let s = writer.snapshot()
        return RecorderStatus(elapsed: writer.elapsedSeconds, peaks: s.peaks, droppedRecords: s.droppedRecords,
                              ringUsage: s.ringUsage, gaps: s.gaps, micMuted: isMicMuted)
    }

    /// 録音開始からのトラックごとのピーク（無音の検出用。まだデータのないトラックは含まない）
    public var overallPeaks: [TrackID: Float] { writer?.overallPeaks ?? [:] }

    /// マイクのトラックを録音しているか（ミュートの対象があるか）
    public var hasMicTrack: Bool { control.sync { fileSinks[.mic] != nil } }

    /// マイクをミュートしているか（要求した状態。音声への反映は次のバッファから）
    public var isMicMuted: Bool { writer?.micMuted.load(ordering: .relaxed) ?? false }

    /// マイクのミュートを切り替える。マイクのトラックがなければ何もせず false を返す
    @discardableResult
    public func setMicMuted(_ muted: Bool) -> Bool {
        guard hasMicTrack, let writer else { return false }
        writer.micMuted.store(muted, ordering: .relaxed)
        return true
    }

    /// 録音中の目印（フェーズ 2）
    public func addMarker(label: String?) {
        let at = Int64(((writer?.elapsedSeconds ?? 0) * 1000).rounded())
        _ = try? session.update { m in m.markers.append(SessionMarker(atMs: at, label: label)) }
        CappyLog.shared.info(tr("Marker added at=\(at)ms", ja: "マーカーを記録しました at=\(at)ms"))
    }

    // MARK: 停止

    /// 録音を停止し、CAF を確定する
    public func stop(reason: String) async throws {
        let (engine, tap) = control.sync { () -> (CaptureEngine?, ProcessTap?) in
            running = false
            monitorTimer?.cancel()
            monitorTimer = nil
            debounce.values.forEach { $0.cancel() }
            removeListeners()
            // 外側の定数 engine と区別するため self を明示する（Swift 6.1 ではエラーになる）
            self.engine?.stop()
            return (self.engine, self.tap)
        }
        await writer?.stopAndDrain()
        var firstError: Error?
        for sink in sinks.values.flatMap({ $0 }) {
            do { try await sink.finish() } catch { if firstError == nil { firstError = error } }
        }
        engine?.destroy()
        tap?.destroy()
        let dropped = writer?.droppedRecords ?? 0
        let ended = Date()
        let frames = fileSinks.mapValues { $0.framesWritten }
        try session.update { m in
            if var mutes = m.micMutes, let f = frames[.mic], let t = m.track(.mic) {
                // ミュートしたまま停止した場合は、マイクのトラックの末尾で区間を閉じる
                SessionMute.apply(muted: false, atMs: Int64((Double(f) / t.sampleRate * 1000).rounded()), to: &mutes)
                m.micMutes = mutes
            }
            m.endedAt = TimeFormat.iso8601(ended)
            m.recording.state = .finalized
            m.recording.stopReason = reason
            m.recording.droppedBuffers = dropped
            for i in m.tracks.indices {
                if let f = frames[m.tracks[i].id] {
                    m.tracks[i].frames = f
                    m.tracks[i].durationMs = Int64((Double(f) / m.tracks[i].sampleRate * 1000).rounded())
                }
            }
        }
        CappyLog.shared.info(tr("Recording stopped reason=\(reason) dropped=\(dropped)", ja: "録音を停止しました reason=\(reason) dropped=\(dropped)"))
        let peaks = writer?.overallPeaks ?? [:]
        silentTracks = session.metadata.tracks.map(\.id).filter { (peaks[$0] ?? 0) == 0 }
        if !silentTracks.isEmpty {
            CappyLog.shared.warning(tr("Completely silent tracks: \(silentTracks.map(\.rawValue))", ja: "完全に無音のトラック: \(silentTracks.map(\.rawValue))"))
        }
        if let firstError { throw firstError }
    }
}
