import CappyKit
import Foundation

enum TranscribeRunner {
    struct Request {
        var providerName: String?
        /// transcribe.model の代わりに使うモデル（cappy transcribe --model）
        var model: String? = nil
        var language: String?
        var mix: Bool
        var formats: [TranscriptFormat]
        var force: Bool
        var keepRemote: Bool
        /// 既存の transcript.* をタイムスタンプ付きの名前で残してから上書きする（cappy tui から作り直すとき）
        var backupExisting = false
    }

    static func run(store: SessionStore, profile: Profile, request: Request) async throws {
        let providerName = request.providerName ?? profile.provider
        guard Profile.knownProviders.contains(providerName) else {
            throw CappyError.usage(tr("Invalid --provider: \(providerName) (\(Profile.providerList))", ja: "--provider が不正です: \(providerName)（\(Profile.providerList)）"))
        }
        // --provider で別のクラウドにしたときは、プロファイルの transcribe.model は使わない
        let model = request.model ?? (providerName == profile.provider ? profile.transcribeModel : nil)
        let service = Profile.transcriptionService(provider: providerName, model: model)
        if service == .none {
            Console.print(tr("Provider is none, so no transcription (recording only)", ja: "プロバイダが none のため、文字起こしは行いません（録音のみ）"))
            return
        }
        if request.model != nil && service == .amazon {
            throw CappyError.usage(tr("--model can be used only with provider google (Amazon Transcribe has no model to choose)", ja: "--model は provider が google のときだけ使えます（Amazon Transcribe にはモデルの選択がありません）"))
        }
        let provider = try ProviderFactory.make(service: service, profile: profile, model: model)
        let gemini = service == .gemini
        var opts: Transcriber.Options
        if let aws = provider as? AmazonTranscribeProvider {
            opts = Transcriber.Options(
                language: request.language ?? profile.language,
                mix: request.mix,
                formats: request.formats,
                diarization: profile.awsTranscribe.diarization,
                wordTimestamps: true,
                maxSpeakers: profile.awsTranscribe.maxSpeakers,
                cleanup: (profile.aws?.deleteRemoteAfter ?? true) && !request.keepRemote,
                force: request.force,
                location: aws.region)
        } else {
            opts = Transcriber.Options(
                language: request.language ?? profile.language,
                mix: request.mix,
                formats: request.formats,
                diarization: gemini ? profile.gemini.diarization : profile.google.diarization,
                wordTimestamps: gemini ? profile.gemini.wordTimestamps : profile.google.wordTimestamps,
                minSpeakers: gemini ? nil : profile.google.minSpeakers,
                maxSpeakers: gemini ? nil : profile.google.maxSpeakers,
                cleanup: profile.google.deleteRemoteAfter && !request.keepRemote,
                force: request.force,
                location: gemini ? profile.gemini.location : profile.google.location)
        }
        opts.pollMax = 300
        opts.backupExisting = request.backupExisting
        if request.mix {
            Console.print(tr("Note: --mix loses the distinction between you and the remote side; speakers are told apart only by the provider's diarization", ja: "注意: --mix では自分と相手の区別が失われ、話者の区別はプロバイダの話者分離に頼ります"))
        }
        let transcriber = Transcriber(store: store, provider: provider, options: opts)
        let urls = try await transcriber.run()
        Console.clearStatus()
        // 自分の名前（speakers.me）はモデルを使わずに反映できる
        if let me = profile.speakers.me {
            do {
                try SpeakerNamer.apply(store, me: me)
            } catch {
                CappyLog.shared.warning(tr("Could not apply speakers.me: \(error)", ja: "speakers.me を反映できませんでした: \(error)"))
            }
        }
        Console.print(tr("Transcription finished:", ja: "文字起こしが完了しました:"))
        for u in urls { Console.print("  \(u.path)") }
    }
}

enum SummarizeRunner {
    struct Request {
        var force = false
        var model: String?
        var effort: String?
        /// 要約のテンプレート（nil ならプロファイルの summary.prompt）
        var prompt: String?
        /// --summarize を明示したか（none のときの表示を変える）
        var explicit = false
        /// 既存の summary.md をタイムスタンプ付きの名前で残してから上書きする（cappy tui から作り直すとき）
        var backupExisting = false
    }

    static func run(store: SessionStore, profile: Profile, request: Request) async throws {
        if profile.summaryProvider == "none" {
            if request.explicit {
                Console.print(tr("Summary provider is none, so no summary", ja: "要約のプロバイダが none のため、要約は行いません"))
            }
            return
        }
        if let e = request.effort, !SummarySettings.knownEfforts.contains(e) {
            throw CappyError.usage(tr("Invalid --effort: \(e) (low / medium / high / xhigh / max)", ja: "--effort が不正です: \(e)（low / medium / high / xhigh / max）"))
        }
        let s = profile.summary
        let model = request.model ?? s.model
        try validateModel(model, profile: profile)
        let template = try SummaryTemplate.load(request.prompt ?? profile.summary.prompt)
        let client = try SummaryClientFactory.make(profile: profile)
        // 要約の前に話者の名前を推定して transcript に反映する（失敗しても要約は続ける）。
        // 文字起こしがない・空のときは、要約の側でそのエラーを出す
        if profile.speakers.auto, let source = try? SpeakerNamer.load(store), !source.doc.segments.isEmpty {
            do {
                try await SpeakersRunner.infer(store: store, profile: profile, client: client, request: .init(quiet: true))
            } catch {
                Console.clearStatus()
                // 中断（cappy tui の Ctrl-C など）は要約に進まない
                if Task.isCancelled || error is CancellationError { throw error }
                let message = (error as? CappyError)?.message ?? "\(error)"
                Console.print(tr("Could not name the speakers (continuing with the summary): \(message)", ja: "話者の名前を推定できませんでした（要約は続けます）: \(message)"))
            }
        }
        let options = Summarizer.Options(
            model: model,
            fallbackModel: s.effectiveFallback(for: model),
            effort: request.effort ?? s.effort,
            maxTokens: s.maxTokens,
            language: profile.language,
            instructions: try SummaryClientFactory.instructions(profile: profile),
            template: template,
            force: request.force,
            backupExisting: request.backupExisting)
        let via = template.isBuiltin ? "" : ", " + template.name
        Console.status(tr("Creating the summary (\(options.model)\(via))…", ja: "要約を作成しています（\(options.model)\(via)）…"))
        let outcome = try await Summarizer(store: store, client: client, options: options).run()
        Console.clearStatus()
        switch outcome {
        case .created(let url):
            Console.print(tr("Summary created:", ja: "要約を作成しました:"))
            Console.print("  \(url.path)")
        case .upToDate(let url):
            Console.print(tr("A summary of the same transcript already exists (use --force to regenerate):", ja: "同じ文字起こしから作った要約があります（作り直すには --force）:"))
            Console.print("  \(url.path)")
        }
    }
}

extension SummarizeRunner {
    /// 要約・話者の名前の推定に使うモデルが、要約のクラウドで使えるかを確かめる
    static func validateModel(_ model: String, profile: Profile) throws {
        guard let family = SummaryModelFamily.of(model) else {
            throw CappyError.usage(tr("Invalid --model: \(model) (a model ID starting with claude- or gemini-, or on Bedrock an ID such as moonshotai.kimi-k3.1)", ja: "--model が不正です: \(model)（claude- または gemini- で始まるモデル ID、Bedrock なら moonshotai.kimi-k3.1 のような ID）"))
        }
        if profile.summaryProvider == "aws" && family == .gemini {
            throw CappyError.usage(tr("Invalid --model: \(model) (Gemini models are not available on Bedrock)", ja: "--model が不正です: \(model)（Bedrock では Claude のモデルだけを使えます）"))
        }
        if profile.summaryProvider == "google" && (model.contains("anthropic.") || family == .bedrockChat) {
            throw CappyError.usage(tr("Invalid --model: \(model) (Bedrock model IDs can be used only with summary.provider = \"aws\")", ja: "--model が不正です: \(model)（Bedrock のモデル ID は summary.provider = \"aws\" のときだけ使えます）"))
        }
    }
}

/// 話者の名前の推定（cappy speakers と、要約の前の自動実行）
enum SpeakersRunner {
    struct Request {
        var force = false
        var model: String?
        var effort: String?
        /// 要約の前の自動実行（推定済みなら何も表示しない）
        var quiet = false
    }

    /// 推定して transcript に反映し、結果を表示する
    static func infer(store: SessionStore, profile: Profile, client: SummaryModelClient? = nil, request: Request) async throws {
        if profile.summaryProvider == "none" {
            throw CappyError.usage(tr("The summary provider of profile \(profile.name) is none, so there is no model to name the speakers with", ja: "プロファイル \(profile.name) の要約プロバイダが none のため、話者の名前を推定するモデルがありません"),
                                   hint: tr("Set provider in [profiles.\(profile.name).summary], or give the names with `cappy speakers --set`", ja: "[profiles.\(profile.name).summary] の provider を設定するか、`cappy speakers --set` で名前を指定してください"))
        }
        if let e = request.effort, !SummarySettings.knownEfforts.contains(e) {
            throw CappyError.usage(tr("Invalid --effort: \(e) (low / medium / high / xhigh / max)", ja: "--effort が不正です: \(e)（low / medium / high / xhigh / max）"))
        }
        let model = request.model ?? profile.speakers.model ?? profile.summary.model
        try SummarizeRunner.validateModel(model, profile: profile)
        let options = SpeakerNamer.Options(
            model: model,
            fallbackModel: profile.summary.effectiveFallback(for: model),
            effort: request.effort ?? profile.speakers.effort,
            maxTokens: profile.summary.maxTokens,
            me: profile.speakers.me,
            force: request.force)
        let modelClient = try client ?? SummaryClientFactory.make(profile: profile)
        Console.status(tr("Naming the speakers (\(model))…", ja: "話者の名前を推定しています（\(model)）…"))
        let outcome = try await SpeakerNamer(store: store, client: modelClient, options: options).infer()
        Console.clearStatus()
        switch outcome {
        case .nothingToName:
            if !request.quiet {
                Console.print(tr("No speakers to name (the transcription has no speaker labels)", ja: "名前を推定できる話者がいません（文字起こしに話者の区別がありません）"))
            }
            return
        case .upToDate:
            try SpeakerNamer.apply(store, me: profile.speakers.me)
            if request.quiet { return }
            Console.print(tr("Speakers were already named from the same transcript (use --force to infer again):", ja: "同じ文字起こしから推定済みです（推定し直すには --force）:"))
        case .inferred:
            try SpeakerNamer.apply(store, me: profile.speakers.me)
            Console.print(tr("Named the speakers:", ja: "話者の名前を推定しました:"))
        }
        try printNames(store: store, profile: profile)
    }

    /// 話者ごとの名前と、その出どころを表示する
    static func printNames(store: SessionStore, profile: Profile) throws {
        let source = try SpeakerNamer.load(store)
        let L = UILanguage.forDocument(source.doc.language)
        let naming = SpeakerNaming(segments: source.doc.segments, language: L)
        let speakers = naming.speakers(in: source.doc.segments)
        // 文字起こしをやり直す前の推定・指定は表示しない（apply と同じく、発言が同じときだけ使う）
        let digest = SpeakerNamer.segmentsDigest(source.doc.segments)
        let state = store.metadata.speakers.flatMap { $0.segmentsDigest == digest ? $0 : nil }
        let names = source.doc.speakerNames ?? [:]
        let width = speakers.map { $0.label.count }.max() ?? 0
        for sp in speakers {
            let pad = String(repeating: " ", count: max(0, width - sp.label.count))
            let guess = state?.guesses.first { $0.key == sp.key }
            var line = "  \(sp.label)\(pad)  → "
            if let name = names[sp.key] {
                line += name
                if state?.manual[sp.key] != nil {
                    line += tr("  (set by you)", ja: "  （指定）")
                } else if sp.key == TrackID.mic.rawValue, profile.speakers.me != nil {
                    line += tr("  (speakers.me)", ja: "  （speakers.me）")
                } else if let g = guess {
                    line += "  (\(g.confidence ?? "-")\(g.evidence.map { ": " + $0 } ?? ""))"
                }
            } else {
                line += tr("(unknown)", ja: "（不明）")
                if state?.manual[sp.key] != nil {
                    line += tr("  (cleared by you)", ja: "  （名前なしに指定）")
                } else if let g = guess, let n = g.name {
                    line += tr("  (not used, low confidence: \(n)\(g.evidence.map { "; " + $0 } ?? ""))",
                               ja: "  （確度が低いため不採用: \(n)\(g.evidence.map { "。" + $0 } ?? "")）")
                } else if let e = guess?.evidence {
                    line += "  (\(e))"
                }
            }
            Console.print(line)
        }
    }
}

/// レベルメーター（ピーク値 → 5 段）
enum LevelMeter {
    static func bar(_ peak: Float?) -> String {
        guard let peak, peak > 0 else { return "▯▯▯▯▯" }
        let db = 20 * log10(Double(peak))
        // -60 dB 〜 0 dB を 5 段に
        let n = max(0, min(5, Int(((db + 60) / 60 * 5).rounded(.up))))
        return String(repeating: "▮", count: n) + String(repeating: "▯", count: 5 - n)
    }
}

/// 割り込み（Ctrl-C / SIGTERM）の扱い。1 回目で停止、2 回目で変換を省いて即時終了する
final class InterruptController: @unchecked Sendable {
    enum Phase { case recording, finalizing, converting, transcribing, summarizing, done }

    private let lock = NSLock()
    private var phase: Phase = .recording
    private var count = 0
    private var _skipConversion = false
    private var sources: [DispatchSourceSignal] = []
    private let onStop: @Sendable (String) -> Void
    var sessionPath = ""

    /// いま動いている録音の割り込み処理（cappy tui が Ctrl-C を渡す先）
    nonisolated(unsafe) private static weak var _current: InterruptController?
    private static let currentLock = NSLock()
    static var current: InterruptController? { currentLock.withLock { _current } }

    init(onStop: @escaping @Sendable (String) -> Void) {
        self.onStop = onStop
        Self.currentLock.withLock { Self._current = self }
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { [weak self] in self?.handle(sig) }
            src.resume()
            sources.append(src)
        }
    }

    var skipConversion: Bool { lock.withLock { _skipConversion } }

    func setPhase(_ p: Phase) { lock.withLock { phase = p } }

    var currentPhase: Phase { lock.withLock { phase } }

    /// シグナルを受けたときと同じように扱う（端末の Ctrl-C を自分で読む cappy tui から呼ぶ）
    func trigger(_ sig: Int32) { handle(sig) }

    private func handle(_ sig: Int32) {
        let (p, n) = lock.withLock { () -> (Phase, Int) in
            count += 1
            return (phase, count)
        }
        let name = sig == SIGTERM ? "SIGTERM" : "Ctrl-C"
        switch p {
        case .recording:
            if n == 1 { onStop(sig == SIGTERM ? "sigterm" : "interrupt") }
        case .finalizing:
            lock.withLock { _skipConversion = true }
            Console.print(tr("\(name): skipping the conversion and exiting", ja: "\(name): 変換を省略して終了します"))
        case .converting:
            Console.clearStatus()
            Console.print(tr("\(name): conversion interrupted. The recordings (CAF) are saved. ", ja: "\(name): 変換を中断しました。録音ファイル（CAF）は保存済みです。")
                + tr("Create the files to send with `cappy recover \(sessionPath)`", ja: "送信用ファイルは `cappy recover \(sessionPath)` で作成できます"))
            Foundation.exit(130)
        case .transcribing:
            Console.clearStatus()
            Console.print(tr("\(name): interrupted. Resume with `cappy transcribe \(sessionPath)`", ja: "\(name): 中断しました。`cappy transcribe \(sessionPath)` で再開できます"))
            Foundation.exit(130)
        case .summarizing:
            Console.clearStatus()
            Console.print(tr("\(name): interrupted. Create the summary again with `cappy summarize \(sessionPath)`", ja: "\(name): 中断しました。`cappy summarize \(sessionPath)` で要約を作り直せます"))
            Foundation.exit(130)
        case .done:
            Foundation.exit(130)
        }
    }
}

/// 録音中のステータス行に出す、認識途中の文字
final class LiveCaptions: @unchecked Sendable {
    static let shared = LiveCaptions()
    private let lock = NSLock()
    private var latest: (track: TrackID, text: String)?

    func set(_ track: TrackID, _ text: String?) {
        lock.withLock {
            if let text {
                latest = (track, text)
            } else if latest?.track == track {
                latest = nil
            }
        }
    }

    /// 前の録音の字幕を消す（cappy tui で続けて録音するとき）
    func reset() {
        lock.withLock { latest = nil }
    }

    /// 末尾の maxLength 文字（長ければ先頭を省く）
    func line(maxLength: Int) -> String? {
        lock.withLock {
            guard let l = latest else { return nil }
            let t = l.text.replacingOccurrences(of: "\n", with: " ")
            let tail = t.count > maxLength ? "…" + t.suffix(maxLength) : t
            return "\(l.track.displayName): \(tail)"
        }
    }
}
