import ArgumentParser
import CappyKit
import Foundation

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("Record the target app's audio (remote) and the microphone (you) as separate tracks", ja: "対象アプリの音声（相手）とマイク（自分）を別トラックで録音する"),
        discussion: tr("""
        Examples:
          cappy record --app us.zoom.xos --name weekly-sync
          cappy record --app com.google.Chrome --duration 90m --transcribe --summarize
          cappy record --app us.zoom.xos --live
          cappy record --system --no-mic

        Press Enter while recording to add a marker. Type some text before Enter to give the marker a label.
        Press Space (with nothing typed) to mute / unmute the microphone (also `cappy mic off|on|toggle` from elsewhere).
        While muted, the mic track is recorded as silence, so sounds picked up while you are muted in the meeting app are not kept.
        Ctrl-C stops recording and creates the files to send. A second Ctrl-C skips the conversion and exits.
        """, ja: """
        例:
          cappy record --app us.zoom.xos --name weekly-sync
          cappy record --app com.google.Chrome --duration 90m --transcribe --summarize
          cappy record --app us.zoom.xos --live
          cappy record --system --no-mic

        録音中に Enter を押すとマーカー（目印）を記録します。文字を入力してから Enter でラベル付きになります。
        何も入力していないときに Space を押すとマイクをミュート / 解除します（別のターミナルなどからは `cappy mic off|on|toggle`）。
        ミュート中はマイクのトラックを無音で記録するため、会議アプリでミュートしている間の音を残さずに済みます。
        Ctrl-C で停止して送信用ファイルまで作成します。2 回目の Ctrl-C で変換を省いて終了します。
        """)
    )

    @Option(name: .customLong("app"), help: ArgumentHelp(tr("Bundle ID of the app to record (prefix match, so helper processes are included; repeatable)", ja: "録音対象の bundle ID（前方一致でヘルパープロセスも含む。複数指定可）")),
            completion: .custom { _, _, _ in CompletionCandidates.apps() })
    var apps: [String] = []

    @Option(name: .customLong("pid"), help: ArgumentHelp(tr("PID to record (repeatable)", ja: "録音対象の PID（複数指定可）")), completion: .custom { _, _, _ in CompletionCandidates.pids() })
    var pids: [Int32] = []

    @Flag(help: ArgumentHelp(tr("Record all system output except cappy itself", ja: "自分自身を除くシステム全体の出力を録音する")))
    var system = false

    @Flag(name: .customLong("no-mic"), help: ArgumentHelp(tr("Do not record the microphone", ja: "マイクを録音しない")))
    var noMic = false

    @Flag(help: ArgumentHelp(tr("Start with the microphone muted (unmute with Space or `cappy mic on`)", ja: "マイクをミュートした状態で録音を始める（解除は Space か `cappy mic on`）")))
    var muted = false

    @Option(help: ArgumentHelp(tr("Microphone input device UID (default: the system default input; see `cappy devices`)", ja: "マイクの入力デバイス UID（既定はシステムの既定入力。`cappy devices` で確認）")),
            completion: .custom { _, _, _ in CompletionCandidates.microphones() })
    var mic: String?

    @Option(help: ArgumentHelp(tr("Output directory (default: output_dir of the profile)", ja: "出力先ディレクトリ（既定はプロファイルの output_dir）")), completion: .directory)
    var out: String?

    @Option(help: ArgumentHelp(tr("Session name (used for the directory name and the transcript title)", ja: "セッション名（ディレクトリ名と transcript の見出しに使う）")))
    var name: String?

    @Option(help: ArgumentHelp(tr("Stop automatically after this duration (e.g. 90m, 1h30m, 45s)", ja: "指定時間で自動停止する（例: 90m, 1h30m, 45s）")), completion: .list(["30m", "1h", "90m", "2h"]))
    var duration: String?

    @Flag(help: ArgumentHelp(tr("Transcribe after recording", ja: "録音終了後に続けて文字起こしする")))
    var transcribe = false

    @Flag(help: ArgumentHelp(tr("With --transcribe, send a single mix of the two tracks", ja: "--transcribe 時に 2 トラックをミックスした 1 本で送る")))
    var mix = false

    @Option(help: ArgumentHelp(tr("Output formats for --transcribe (md,json,srt)", ja: "--transcribe 時の出力形式（md,json,srt）")), completion: .list(CompletionCandidates.formats))
    var format: String = "md,json,srt"

    @Flag(inversion: .prefixedNo, help: ArgumentHelp(tr("Summarize the meeting after --transcribe / --live (default: summary.auto of the profile)", ja: "--transcribe / --live 時に続けて会議の要約を作る（既定はプロファイルの summary.auto）")))
    var summarize: Bool?

    @Option(name: .customLong("summary-model"),
            help: ArgumentHelp(tr("Model for the summary (default: summary.model of the profile)", ja: "要約に使うモデル（既定はプロファイルの summary.model）")),
            completion: .custom { _, _, _ in CompletionCandidates.models() })
    var summaryModel: String?

    @Option(name: .customLong("summary-prompt"),
            help: ArgumentHelp(tr("Template for the summary (a name in prompts/ or a path; default: summary.prompt of the profile)", ja: "要約のテンプレート（prompts/ の名前かパス。既定はプロファイルの summary.prompt）")),
            completion: .custom { _, _, _ in CompletionCandidates.prompts() })
    var summaryPrompt: String?

    @Flag(help: ArgumentHelp(tr("Transcribe in real time while recording (transcribe.live_model on Vertex AI, or Amazon Transcribe Streaming when transcribe.provider = aws; results go to live-transcript.*)", ja: "録音しながらリアルタイムで文字起こしする（Vertex AI の transcribe.live_model、transcribe.provider = aws なら Amazon Transcribe Streaming。結果は live-transcript.*）")))
    var live = false

    @Flag(help: ArgumentHelp(tr("Wait until the target starts playing audio", ja: "対象が音声を出し始めるまで待つ")))
    var wait = false

    @Flag(help: ArgumentHelp(tr("Do not show the recording notice", ja: "録音の告知メッセージを表示しない")))
    var quiet = false

    @OptionGroup var common: CommonOptions

    func validate() throws {
        if apps.isEmpty && pids.isEmpty && !system {
            throw ValidationError(tr("Specify what to record with --app, --pid or --system", ja: "録音対象を --app / --pid / --system のいずれかで指定してください"))
        }
        if system && (!apps.isEmpty || !pids.isEmpty) {
            throw ValidationError(tr("--system cannot be combined with --app / --pid", ja: "--system と --app / --pid は同時に指定できません"))
        }
        if noMic && mic != nil {
            throw ValidationError(tr("--no-mic cannot be combined with --mic", ja: "--no-mic と --mic は同時に指定できません"))
        }
        if noMic && muted {
            throw ValidationError(tr("--no-mic cannot be combined with --muted", ja: "--no-mic と --muted は同時に指定できません"))
        }
        if mix && !transcribe {
            throw ValidationError(tr("--mix requires --transcribe (after recording, use `cappy transcribe --mix`)", ja: "--mix は --transcribe と一緒に指定してください（録音後なら `cappy transcribe --mix`）"))
        }
        if summarize == true && !transcribe && !live {
            throw ValidationError(tr("--summarize requires --transcribe or --live (after recording, use `cappy transcribe --summarize`)", ja: "--summarize は --transcribe か --live と一緒に指定してください（録音後なら `cappy transcribe --summarize`）"))
        }
        // 録音が終わってから気づかないよう、モデル ID の形だけは先に確かめる
        if let m = summaryModel, SummaryModelFamily.of(m) == nil {
            throw ValidationError(tr("Invalid --summary-model: \(m) (a model ID starting with claude- or gemini-, or on Bedrock an ID such as moonshotai.kimi-k3.1)", ja: "--summary-model が不正です: \(m)（claude- または gemini- で始まるモデル ID、Bedrock なら moonshotai.kimi-k3.1 のような ID）"))
        }
    }

    func run() async throws {
        try await execute()
    }

    /// 録音する。keyInput を渡すと、端末を自分で読まずにそこからキー入力を受け取る（cappy tui）。
    /// onSession はセッションディレクトリを作った時点で呼ぶ
    func execute(keyInput: RecordKeyInput? = nil, onSession: (@Sendable (URL) -> Void)? = nil) async throws {
        CappyLog.shared.verbose = common.verbose
        let profile = try common.loadProfile()
        let formats = try TranscriptFormat.parseList(format)
        // 録音が終わってから気づかないよう、要約のテンプレートは先に読めるか確かめる
        if summarize ?? profile.summary.auto, transcribe || live {
            _ = try SummaryTemplate.load(summaryPrompt ?? profile.summary.prompt)
        }
        let maxDuration = try duration.map(DurationParser.parse)
        let spec = RecordTargetSpec(bundleIDs: apps, pids: pids, system: system)

        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)) else {
            throw CappyError.usage(tr("macOS 15 or later is required", ja: "macOS 15 以降が必要です"))
        }

        if !quiet {
            Console.print(tr("⚠️  Tell the participants and get their consent before recording.", ja: "⚠️  録音は参加者への告知と同意を得たうえで行ってください。"))
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
            throw CappyError.io(tr("Cannot create the session directory: \(parent.path): \(error.localizedDescription)", ja: "セッションディレクトリを作成できません: \(parent.path): \(error.localizedDescription)"))
        }
        var meta = SessionMetadata(id: UUID().uuidString.lowercased(), name: name)
        meta.profile = profile.name
        let store = SessionStore(directory: dir, metadata: meta)
        try store.save()
        onSession?(dir)
        CappyLog.shared.attach(sessionDirectory: dir)
        CappyLog.shared.info(tr("cappy \(CappyVersion.current) record started session=\(meta.id) targets=\(TargetResolver.describe(spec))", ja: "cappy \(CappyVersion.current) record 開始 session=\(meta.id) targets=\(TargetResolver.describe(spec))"))

        let recorder = Recorder(
            options: RecorderOptions(targets: spec, micEnabled: !noMic, micUID: mic,
                                     diskWarnBytes: Int64(profile.diskWarnMB) << 20,
                                     diskStopBytes: Int64(profile.diskStopMB) << 20,
                                     micMutedAtStart: muted),
            session: store)

        let (events, continuation) = AsyncStream<StopEvent>.makeStream()
        let interrupts = InterruptController { reason in continuation.yield(.stop(reason)) }
        interrupts.sessionPath = dir.path
        recorder.onFatalError = { error in continuation.yield(.fatal(error)) }

        var liveSession: LiveTranscription?
        if let liveSetup {
            let l = LiveTranscription(store: store, language: profile.language, config: liveSetup.config)
            l.onSegment = { s in
                let who = s.speaker.map { tr("\(s.track.displayName) (\($0))", ja: "\(s.track.displayName)（\($0)）") } ?? s.track.displayName
                Console.print("[\(TimeFormat.hms(ms: s.startMs))] \(who): \(s.text)")
            }
            l.onInterim = { track, text in LiveCaptions.shared.set(track, text) }
            l.onNotice = { Console.print(tr("Live transcription: \($0)", ja: "リアルタイム文字起こし: \($0)")) }
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

        let micControl = MicMuteController(recorder: recorder)
        micControl.start(session: dir, name: name)
        defer { micControl.stop() }

        let sleepDone = DispatchSemaphore(value: 0)
        let sleepWatcher = SleepWatcher {
            continuation.yield(.stop("sleep"))
            // CAF の確定を待ってからスリープを許可する（最大 20 秒）
            _ = sleepDone.wait(timeout: .now() + 20)
        }

        Console.print(tr("Recording started: \(dir.path)", ja: "録音を開始しました: \(dir.path)"))
        let trackList = store.metadata.tracks.map { tr("\($0.id.displayName) (\($0.id.rawValue))", ja: "\($0.id.displayName)（\($0.id.rawValue)）") }
            .joined(separator: tr(", ", ja: "・"))
        let statusLine = StatusLine()
        let keys = startKeyReader(recorder, micControl: micControl, statusLine: statusLine, input: keyInput)
        defer { keys?.stop() }
        let tty = keys != nil
        let muteKey = tty && micControl.hasMic
        Console.print(tr("Tracks: \(trackList)  Stop: Ctrl-C\(muteKey ? "  Mic mute: Space" : "")\(tty ? "  Marker: Enter (type a label first if you like)" : "")",
                         ja: "トラック: \(trackList)  停止: Ctrl-C\(muteKey ? "  マイクのミュート: Space" : "")\(tty ? "  マーカー: Enter（先に文字を入力するとラベル付き）" : "")"))
        if recorder.isMicMuted {
            Console.print(tr("🔇 The mic is muted. Unmute: \(muteKey ? "Space or " : "")`cappy mic on`", ja: "🔇 マイクはミュート中です。解除: \(muteKey ? "Space か " : "")`cappy mic on`"))
        }

        if let maxDuration {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(maxDuration * 1e9))
                continuation.yield(.stop("duration"))
            }
        }
        let statusTimer = startStatusLine(recorder, statusLine)

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
        keys?.stop()
        Console.clearStatus()
        Console.print(reason == "sleep" ? tr("Stopping the recording because the Mac is going to sleep…", ja: "スリープするため録音を停止しています…") : tr("Stopping the recording…", ja: "録音を停止しています…"))

        var stopError: Error?
        if liveSession != nil { Console.print(tr("Waiting for the remaining live transcription results…", ja: "リアルタイム文字起こしの残りの結果を待っています…")) }
        do {
            try await recorder.stop(reason: reason)
        } catch {
            stopError = error
        }
        micControl.stop()
        var liveURLs: [URL] = []
        if let liveSession {
            do {
                liveURLs = try liveSession.finish(formats: formats)
            } catch {
                Console.print(tr("Warning: could not save the live transcription: \(error)", ja: "警告: リアルタイム文字起こしの結果を保存できませんでした: \(error)"))
            }
        }
        sleepDone.signal()
        sleepWatcher.invalidate()

        let meta2 = store.metadata
        printSummary(meta2)
        if recorder.silentTracks.contains(.remote) {
            Console.print(tr("Warning: the remote track was completely silent. The target app may not have played any audio, or ", ja: "警告: 相手側（remote）が完全に無音でした。対象アプリが音を出していなかったか、")
                + tr("system audio recording may not be allowed (`cappy doctor`)", ja: "システムオーディオ録音が許可されていない可能性があります（`cappy doctor`）"))
        }
        if recorder.silentTracks.contains(.mic) && !Self.mutedThroughout(meta2) {
            Console.print(tr("Warning: the mic track was completely silent. Check the microphone permission and the input device", ja: "警告: 自分（mic）が完全に無音でした。マイクの許可と入力デバイスを確認してください"))
        }
        if liveSession != nil {
            if liveURLs.isEmpty {
                Console.print(tr("No live transcription results", ja: "リアルタイム文字起こしの結果はありません")
                    + (store.metadata.live?.error.map { tr(" (\($0))", ja: "（\($0)）") } ?? ""))
            } else {
                Console.print(tr("Live transcription saved:", ja: "リアルタイム文字起こしを保存しました:"))
                for u in liveURLs { Console.print("  \(u.path)") }
                if let dropped = store.metadata.live?.droppedMs, dropped >= 1000 {
                    Console.print(tr("Note: \(TimeFormat.hms(ms: dropped)) of audio sent while disconnected is not in the live transcription", ja: "注意: 接続できなかった \(TimeFormat.hms(ms: dropped)) 分の音声はリアルタイム文字起こしに含まれていません"))
                }
            }
        }
        if let fatal { throw fatal }
        if let stopError { throw CappyError.io(tr("Failed to finalize the recording files: \(stopError)", ja: "録音ファイルの確定に失敗しました: \(stopError)")) }

        if interrupts.skipConversion {
            Console.print(tr("Skipped the conversion. Create the files to send with `cappy recover \(dir.path)`", ja: "変換を省略しました。送信用ファイルは `cappy recover \(dir.path)` で作成できます"))
            return
        }
        interrupts.setPhase(.converting)
        Console.print(tr("Creating the files to send (16 kHz mono)…", ja: "送信用ファイル（16 kHz・モノラル）を作成しています…"))
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
                try await SummarizeRunner.run(store: store, profile: profile, request: .init(model: summaryModel, prompt: summaryPrompt, explicit: summarize == true))
            }
        } else {
            if !liveURLs.isEmpty && (summarize ?? profile.summary.auto) {
                // リアルタイム文字起こしの結果から要約する
                interrupts.setPhase(.summarizing)
                try await SummarizeRunner.run(store: store, profile: profile, request: .init(model: summaryModel, prompt: summaryPrompt, explicit: summarize == true))
            }
            Console.print(tr("Transcribe: cappy transcribe \(dir.path)", ja: "文字起こし: cappy transcribe \(dir.path)"))
        }
        interrupts.setPhase(.done)
        CappyLog.shared.detach()
    }

    struct LiveSetup {
        var config: LiveConfig
    }

    /// --live の準備（設定と認証を確認する。録音を始める前に失敗させる）
    private func prepareLive(_ profile: Profile) throws -> LiveSetup {
        guard profile.provider != "none" else {
            throw CappyError.usage(tr("--live is not available because transcribe.provider is none in profile \(profile.name)", ja: "プロファイル \(profile.name) の transcribe.provider が none のため、--live は使えません"))
        }
        if profile.provider == "aws" {
            let aws = profile.aws ?? AWSSettings()
            let credentials = try AWSCredentialsProvider.resolve(profile: aws.profile, region: aws.region)
            guard let region = credentials.region else {
                throw CappyError.usage(
                    tr("The AWS region for Amazon Transcribe Streaming is not set", ja: "Amazon Transcribe Streaming を呼び出す AWS のリージョンが設定されていません"),
                    hint: tr("Set region in [profiles.\(profile.name).aws], AWS_REGION, or region in the AWS profile", ja: "[profiles.\(profile.name).aws] の region、AWS_REGION、AWS のプロファイルの region のいずれかを設定してください"))
            }
            Console.print(tr("Live transcription: sending the audio to Amazon Transcribe Streaming (\(region)) while recording", ja: "リアルタイム文字起こし: 録音中の音声を Amazon Transcribe Streaming（\(region)）に送信します"))
            return LiveSetup(config: .transcribe(region: region, settings: profile.awsTranscribe, credentials: credentials))
        }
        guard let project = profile.google.projectID, !project.isEmpty else {
            throw CappyError.usage(tr("project_id for live transcription is not set", ja: "リアルタイム文字起こしに使う project_id が設定されていません"),
                                   hint: tr("Set project_id in [profiles.\(profile.name).google]", ja: "[profiles.\(profile.name).google] に project_id を書いてください"))
        }
        let auth = try ApplicationDefaultCredentials.load()
        Console.print(tr("Live transcription: sending the audio to Vertex AI (\(profile.gemini.liveModel), \(profile.gemini.location)) while recording", ja: "リアルタイム文字起こし: 録音中の音声を Vertex AI（\(profile.gemini.liveModel)、\(profile.gemini.location)）に送信します"))
        return LiveSetup(config: .gemini(settings: profile.gemini, projectID: project,
                                         connector: VertexLiveConnector(location: profile.gemini.location, auth: auth, userProject: project)))
    }

    enum StopEvent: Sendable {
        case stop(String)
        case fatal(CappyError)
    }

    private func waitForTargets(_ spec: RecordTargetSpec) async throws -> ResolvedTargets {
        Console.print(tr("Waiting for the target (\(TargetResolver.describe(spec))) to start playing audio… (Ctrl-C to cancel)", ja: "録音対象（\(TargetResolver.describe(spec))）が音声を出し始めるのを待っています…（Ctrl-C で中止）"))
        signal(SIGINT, SIG_DFL)
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if let r = try? TargetResolver.resolve(spec) {
                Console.print(tr("Found the recording target", ja: "録音対象が見つかりました"))
                return r
            }
        }
    }

    private func startStatusLine(_ recorder: Recorder, _ statusLine: StatusLine) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        let hasMic = !noMic
        timer.setEventHandler {
            let s = recorder.status()
            var line = tr("● REC \(TimeFormat.elapsed(s.elapsed))  remote \(LevelMeter.bar(s.peaks[.remote]))", ja: "● 録音中 \(TimeFormat.elapsed(s.elapsed))  相手 \(LevelMeter.bar(s.peaks[.remote]))")
            if hasMic {
                line += s.micMuted ? tr("  mic 🔇muted", ja: "  自分 🔇ミュート")
                                   : tr("  mic \(LevelMeter.bar(s.peaks[.mic]))", ja: "  自分 \(LevelMeter.bar(s.peaks[.mic]))")
            }
            if s.gaps > 0 { line += tr("  gaps \(s.gaps)", ja: "  欠落 \(s.gaps)") }
            if let caption = LiveCaptions.shared.line(maxLength: 36) { line += "  💬 \(caption)" }
            if CappyLog.shared.verbose { line += String(format: "  drop %d  ring %.0f%%", s.droppedRecords, s.ringUsage * 100) }
            statusLine.setBase(line)
        }
        timer.resume()
        return timer
    }

    /// キー入力（Space でミュートの切り替え、Enter でマーカー）を読み始める。端末から入力できなければ nil
    private func startKeyReader(_ recorder: Recorder, micControl: MicMuteController, statusLine: StatusLine,
                                input: RecordKeyInput?) -> KeyInputStopper? {
        let handler: @Sendable (KeyInputParser.Event, String) -> Void = { event, text in
            switch event {
            case .toggleMute:
                micControl.toggle()
            case .marker(let label):
                statusLine.setInput("")
                recorder.addMarker(label: label)
                let n = recorder.session.metadata.markers.count
                let at = TimeFormat.elapsed(recorder.status().elapsed)
                Console.print(tr("Marker \(n) added (\(at))\(label.map { ": \($0)" } ?? "")", ja: "マーカー \(n) を記録しました（\(at)）\(label.map { ": \($0)" } ?? "")"))
            case .edited:
                statusLine.setInput(text)
            }
        }
        if let input { return input.start(onEvent: handler) ? input : nil }
        let reader = KeyReader(onEvent: handler)
        return reader.start() ? reader : nil
    }

    /// 録音中ずっとマイクをミュートしていたか（それなら無音の警告は出さない）
    static func mutedThroughout(_ meta: SessionMetadata) -> Bool {
        guard let mutes = meta.micMutes, let duration = meta.track(.mic)?.durationMs, duration > 0 else { return false }
        return SessionMute.totalMs(mutes, untilMs: duration) >= duration - 100
    }

    private func printSummary(_ meta: SessionMetadata) {
        let maxMs = meta.tracks.compactMap(\.durationMs).max() ?? 0
        var line = tr("Recording stopped (\(TimeFormat.hms(ms: maxMs))", ja: "録音を停止しました（\(TimeFormat.hms(ms: maxMs))")
        if !meta.gaps.isEmpty {
            let total = meta.gaps.reduce(Int64(0)) { $0 + ($1.endMs - $1.startMs) }
            line += tr(", \(meta.gaps.count) gap(s), \(total) ms in total", ja: "、欠落 \(meta.gaps.count) 区間 計 \(total) ms")
        }
        if !meta.markers.isEmpty { line += tr(", \(meta.markers.count) marker(s)", ja: "、マーカー \(meta.markers.count)") }
        if let mutes = meta.micMutes, !mutes.isEmpty {
            let total = SessionMute.totalMs(mutes, untilMs: meta.track(.mic)?.durationMs ?? maxMs)
            line += tr(", mic muted \(TimeFormat.hms(ms: total)) in total", ja: "、マイクのミュート 計 \(TimeFormat.hms(ms: total))")
        }
        line += tr(")", ja: "）")
        Console.print(line)
    }
}

/// 録音中のステータス行（0.5 秒ごとの表示に、入力中のラベルを添える）
final class StatusLine: @unchecked Sendable {
    private let lock = NSLock()
    private var base = ""
    private var input = ""

    func setBase(_ line: String) {
        lock.withLock { base = line }
        render()
    }

    /// キー入力のたびに呼ぶ（レベルメーターを読み直さず、直前の表示に添えて書き直す）
    func setInput(_ text: String) {
        lock.withLock { input = text }
        render()
    }

    private func render() {
        let (b, i) = lock.withLock { (base, input) }
        guard !b.isEmpty else { return }
        Console.status(i.isEmpty ? b : b + "  ✎ " + String(i.suffix(30)) + "▏")
    }
}
