import ArgumentParser
import CappyKit
import Foundation

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "対象アプリの音声（相手）とマイク（自分）を別トラックで録音する",
        discussion: """
        例:
          cappy record --app us.zoom.xos --name weekly-sync
          cappy record --app com.google.Chrome --duration 90m --transcribe --summarize
          cappy record --app us.zoom.xos --live
          cappy record --system --no-mic

        録音中に Enter を押すとマーカー（目印）を記録します。文字を入力してから Enter でラベル付きになります。
        Ctrl-C で停止して送信用ファイルまで作成します。2 回目の Ctrl-C で変換を省いて終了します。
        """
    )

    @Option(name: .customLong("app"), help: "録音対象の bundle ID（前方一致でヘルパープロセスも含む。複数指定可）")
    var apps: [String] = []

    @Option(name: .customLong("pid"), help: "録音対象の PID（複数指定可）")
    var pids: [Int32] = []

    @Flag(help: "自分自身を除くシステム全体の出力を録音する")
    var system = false

    @Flag(name: .customLong("no-mic"), help: "マイクを録音しない")
    var noMic = false

    @Option(help: "マイクの入力デバイス UID（既定はシステムの既定入力。`cappy devices` で確認）")
    var mic: String?

    @Option(help: "出力先ディレクトリ（既定はプロファイルの output_dir）")
    var out: String?

    @Option(help: "セッション名（ディレクトリ名と transcript の見出しに使う）")
    var name: String?

    @Option(help: "指定時間で自動停止する（例: 90m, 1h30m, 45s）")
    var duration: String?

    @Flag(help: "録音終了後に続けて文字起こしする")
    var transcribe = false

    @Flag(help: "--transcribe 時に 2 トラックをミックスした 1 本で送る")
    var mix = false

    @Option(help: "--transcribe 時の出力形式（md,json,srt）")
    var format: String = "md,json,srt"

    @Flag(inversion: .prefixedNo, help: "--transcribe / --live 時に続けて会議の要約を作る（既定はプロファイルの summary.auto）")
    var summarize: Bool?

    @Flag(help: "録音しながらリアルタイムで文字起こしする（Vertex AI の gemini.live_model。結果は live-transcript.*）")
    var live = false

    @Flag(help: "対象が音声を出し始めるまで待つ")
    var wait = false

    @Flag(help: "録音の告知メッセージを表示しない")
    var quiet = false

    @OptionGroup var common: CommonOptions

    func validate() throws {
        if apps.isEmpty && pids.isEmpty && !system {
            throw ValidationError("録音対象を --app / --pid / --system のいずれかで指定してください")
        }
        if system && (!apps.isEmpty || !pids.isEmpty) {
            throw ValidationError("--system と --app / --pid は同時に指定できません")
        }
        if noMic && mic != nil {
            throw ValidationError("--no-mic と --mic は同時に指定できません")
        }
        if mix && !transcribe {
            throw ValidationError("--mix は --transcribe と一緒に指定してください（録音後なら `cappy transcribe --mix`）")
        }
        if summarize == true && !transcribe && !live {
            throw ValidationError("--summarize は --transcribe か --live と一緒に指定してください（録音後なら `cappy transcribe --summarize`）")
        }
    }

    func run() async throws {
        CappyLog.shared.verbose = common.verbose
        let profile = try common.loadProfile()
        let formats = try TranscriptFormat.parseList(format)
        let maxDuration = try duration.map(DurationParser.parse)
        let spec = RecordTargetSpec(bundleIDs: apps, pids: pids, system: system)

        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)) else {
            throw CappyError.usage("macOS 15 以降が必要です")
        }

        if !quiet {
            Console.print("⚠️  録音は参加者への告知と同意を得たうえで行ってください。")
        }
        let liveSetup = live ? try prepareLive(profile) : nil

        try await Permissions.ensure(systemAudio: true, microphone: !noMic)

        // 録音対象の解決（--wait なら現れるまで待つ）
        let resolved: ResolvedTargets
        do {
            resolved = try TargetResolver.resolve(spec)
        } catch let e as CappyError where e.status == .targetNotFound && wait {
            resolved = try await waitForTargets(spec)
        }

        // セッションディレクトリ
        let parent = out.map { URL(fileURLWithPath: FileSecurity.expandTilde($0), isDirectory: true) } ?? profile.outputDirectoryURL
        let start = Date()
        let dir: URL
        do {
            dir = try SessionStore.createDirectory(in: parent, start: start, name: name)
        } catch {
            throw CappyError.io("セッションディレクトリを作成できません: \(parent.path): \(error.localizedDescription)")
        }
        var meta = SessionMetadata(id: UUID().uuidString.lowercased(), name: name)
        meta.profile = profile.name
        let store = SessionStore(directory: dir, metadata: meta)
        try store.save()
        CappyLog.shared.attach(sessionDirectory: dir)
        CappyLog.shared.info("cappy \(CappyVersion.current) record 開始 session=\(meta.id) targets=\(TargetResolver.describe(spec))")

        let recorder = Recorder(
            options: RecorderOptions(targets: spec, micEnabled: !noMic, micUID: mic,
                                     diskWarnBytes: Int64(profile.diskWarnMB) << 20,
                                     diskStopBytes: Int64(profile.diskStopMB) << 20),
            session: store)

        let (events, continuation) = AsyncStream<StopEvent>.makeStream()
        let interrupts = InterruptController { reason in continuation.yield(.stop(reason)) }
        interrupts.sessionPath = dir.path
        recorder.onFatalError = { error in continuation.yield(.fatal(error)) }

        var liveSession: LiveTranscription?
        if let liveSetup {
            let l = LiveTranscription(store: store, settings: profile.gemini, projectID: liveSetup.project,
                                      language: profile.language, connector: liveSetup.connector)
            l.onSegment = { s in
                Console.print("[\(TimeFormat.hms(ms: s.startMs))] \(s.track.displayName): \(s.text)")
            }
            l.onInterim = { track, text in LiveCaptions.shared.set(track, text) }
            l.onNotice = { Console.print("リアルタイム文字起こし: \($0)") }
            try l.begin()
            recorder.extraSinks = { track in [l.sink(for: track)] }
            liveSession = l
        }

        do {
            try recorder.start(resolved: resolved)
        } catch {
            // 録音を始められなかったセッションは残さない
            CappyLog.shared.detach()
            try? FileManager.default.removeItem(at: dir)
            throw error
        }

        let sleepDone = DispatchSemaphore(value: 0)
        let sleepWatcher = SleepWatcher {
            continuation.yield(.stop("sleep"))
            // CAF の確定を待ってからスリープを許可する（最大 20 秒）
            _ = sleepDone.wait(timeout: .now() + 20)
        }

        Console.print("録音を開始しました: \(dir.path)")
        let trackList = store.metadata.tracks.map { "\($0.id.displayName)（\($0.id.rawValue)）" }.joined(separator: "・")
        Console.print("トラック: \(trackList)  停止: Ctrl-C\(isatty(STDIN_FILENO) != 0 ? "  マーカー: Enter" : "")")

        if let maxDuration {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(maxDuration * 1e9))
                continuation.yield(.stop("duration"))
            }
        }
        let statusTimer = startStatusLine(recorder)
        startMarkerReader(recorder)

        // 停止要因を待つ
        var fatal: CappyError?
        var reason = "interrupt"
        for await event in events {
            switch event {
            case .stop(let r): reason = r
            case .fatal(let e): fatal = e; reason = "error"
            }
            break
        }
        interrupts.setPhase(.finalizing)
        statusTimer.cancel()
        Console.clearStatus()
        Console.print(reason == "sleep" ? "スリープするため録音を停止しています…" : "録音を停止しています…")

        var stopError: Error?
        if liveSession != nil { Console.print("リアルタイム文字起こしの残りの結果を待っています…") }
        do {
            try await recorder.stop(reason: reason)
        } catch {
            stopError = error
        }
        var liveURLs: [URL] = []
        if let liveSession {
            do {
                liveURLs = try liveSession.finish(formats: formats)
            } catch {
                Console.print("警告: リアルタイム文字起こしの結果を保存できませんでした: \(error)")
            }
        }
        sleepDone.signal()
        sleepWatcher.invalidate()

        let meta2 = store.metadata
        printSummary(meta2)
        if recorder.silentTracks.contains(.remote) {
            Console.print("警告: 相手側（remote）が完全に無音でした。対象アプリが音を出していなかったか、"
                + "システムオーディオ録音が許可されていない可能性があります（`cappy doctor`）")
        }
        if recorder.silentTracks.contains(.mic) {
            Console.print("警告: 自分（mic）が完全に無音でした。マイクの許可と入力デバイスを確認してください")
        }
        if liveSession != nil {
            if liveURLs.isEmpty {
                Console.print("リアルタイム文字起こしの結果はありません"
                    + (store.metadata.live?.error.map { "（\($0)）" } ?? ""))
            } else {
                Console.print("リアルタイム文字起こしを保存しました:")
                for u in liveURLs { Console.print("  \(u.path)") }
                if let dropped = store.metadata.live?.droppedMs, dropped >= 1000 {
                    Console.print("注意: 接続できなかった \(TimeFormat.hms(ms: dropped)) 分の音声はリアルタイム文字起こしに含まれていません")
                }
            }
        }
        if let fatal { throw fatal }
        if let stopError { throw CappyError.io("録音ファイルの確定に失敗しました: \(stopError)") }

        if interrupts.skipConversion {
            Console.print("変換を省略しました。送信用ファイルは `cappy recover \(dir.path)` で作成できます")
            return
        }
        interrupts.setPhase(.converting)
        Console.print("送信用ファイル（16 kHz・モノラル）を作成しています…")
        try SessionProcessing.convert(store)
        for t in store.metadata.tracks {
            if let s = t.sendFile { Console.print("  \(dir.appendingPathComponent(s).path)") }
        }

        if transcribe {
            interrupts.setPhase(.transcribing)
            try await TranscribeRunner.run(store: store, profile: profile, request: .init(
                providerName: nil, language: nil, mix: mix, formats: formats, force: false, keepRemote: false))
            if (summarize ?? profile.summary.auto) && profile.provider != "none" {
                interrupts.setPhase(.summarizing)
                try await SummarizeRunner.run(store: store, profile: profile, request: .init(explicit: summarize == true))
            }
        } else {
            if !liveURLs.isEmpty && (summarize ?? profile.summary.auto) {
                // リアルタイム文字起こしの結果から要約する
                interrupts.setPhase(.summarizing)
                try await SummarizeRunner.run(store: store, profile: profile, request: .init(explicit: summarize == true))
            }
            Console.print("文字起こし: cappy transcribe \(dir.path)")
        }
        interrupts.setPhase(.done)
        CappyLog.shared.detach()
    }

    struct LiveSetup {
        var project: String
        var connector: LiveConnector
    }

    /// --live の準備（設定と認証を確認する。録音を始める前に失敗させる）
    private func prepareLive(_ profile: Profile) throws -> LiveSetup {
        guard profile.provider != "none" else {
            throw CappyError.usage("プロファイル \(profile.name) の provider が none のため、--live は使えません")
        }
        guard let project = profile.geminiProjectID, !project.isEmpty else {
            throw CappyError.usage("リアルタイム文字起こしに使う project_id が設定されていません",
                                   hint: "[profiles.\(profile.name).google] か [profiles.\(profile.name).gemini] に project_id を書いてください")
        }
        let auth = try ApplicationDefaultCredentials.load()
        Console.print("リアルタイム文字起こし: 録音中の音声を Vertex AI（\(profile.gemini.liveModel)、\(profile.gemini.location)）に送信します")
        return LiveSetup(project: project,
                         connector: VertexLiveConnector(location: profile.gemini.location, auth: auth, userProject: project))
    }

    enum StopEvent: Sendable {
        case stop(String)
        case fatal(CappyError)
    }

    private func waitForTargets(_ spec: RecordTargetSpec) async throws -> ResolvedTargets {
        Console.print("録音対象（\(TargetResolver.describe(spec))）が音声を出し始めるのを待っています…（Ctrl-C で中止）")
        signal(SIGINT, SIG_DFL)
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if let r = try? TargetResolver.resolve(spec) {
                Console.print("録音対象が見つかりました")
                return r
            }
        }
    }

    private func startStatusLine(_ recorder: Recorder) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        let hasMic = !noMic
        timer.setEventHandler {
            let s = recorder.status()
            var line = "● 録音中 \(TimeFormat.elapsed(s.elapsed))  相手 \(LevelMeter.bar(s.peaks[.remote]))"
            if hasMic { line += "  自分 \(LevelMeter.bar(s.peaks[.mic]))" }
            if s.gaps > 0 { line += "  欠落 \(s.gaps)" }
            if let caption = LiveCaptions.shared.line(maxLength: 36) { line += "  💬 \(caption)" }
            if CappyLog.shared.verbose { line += String(format: "  drop %d  ring %.0f%%", s.droppedRecords, s.ringUsage * 100) }
            Console.status(line)
        }
        timer.resume()
        return timer
    }

    private func startMarkerReader(_ recorder: Recorder) {
        guard isatty(STDIN_FILENO) != 0 else { return }
        let t = Thread {
            var n = 0
            while let line = readLine() {
                n += 1
                let label = line.trimmingCharacters(in: .whitespaces)
                recorder.addMarker(label: label.isEmpty ? nil : label)
                let at = TimeFormat.elapsed(recorder.status().elapsed)
                Console.print("マーカー \(n) を記録しました（\(at)）\(label.isEmpty ? "" : ": \(label)")")
            }
        }
        t.name = "dev.cappy.markers"
        t.start()
    }

    private func printSummary(_ meta: SessionMetadata) {
        let maxMs = meta.tracks.compactMap(\.durationMs).max() ?? 0
        var line = "録音を停止しました（\(TimeFormat.hms(ms: maxMs))"
        if !meta.gaps.isEmpty {
            let total = meta.gaps.reduce(Int64(0)) { $0 + ($1.endMs - $1.startMs) }
            line += "、欠落 \(meta.gaps.count) 区間 計 \(total) ms"
        }
        if !meta.markers.isEmpty { line += "、マーカー \(meta.markers.count)" }
        line += "）"
        Console.print(line)
    }
}
