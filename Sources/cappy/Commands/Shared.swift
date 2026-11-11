import CappyKit
import Foundation

enum TranscribeRunner {
    struct Request {
        var providerName: String?
        var language: String?
        var mix: Bool
        var formats: [TranscriptFormat]
        var force: Bool
        var keepRemote: Bool
    }

    static func run(store: SessionStore, profile: Profile, request: Request) async throws {
        let providerName = request.providerName ?? profile.provider
        if providerName == "none" {
            Console.print("プロバイダが none のため、文字起こしは行いません（録音のみ）")
            return
        }
        let provider = try ProviderFactory.make(name: providerName, profile: profile)
        var opts = Transcriber.Options(
            language: request.language ?? profile.language,
            mix: request.mix,
            formats: request.formats,
            diarization: profile.google.diarization,
            wordTimestamps: profile.google.wordTimestamps,
            minSpeakers: profile.google.minSpeakers,
            maxSpeakers: profile.google.maxSpeakers,
            cleanup: profile.google.deleteRemoteAfter && !request.keepRemote,
            force: request.force,
            location: providerName == "google" ? profile.google.location : nil)
        opts.pollMax = 300
        if request.mix {
            Console.print("注意: --mix では自分と相手の区別が失われ、話者の区別はプロバイダの話者分離に頼ります")
        }
        let transcriber = Transcriber(store: store, provider: provider, options: opts)
        let urls = try await transcriber.run()
        Console.clearStatus()
        Console.print("文字起こしが完了しました:")
        for u in urls { Console.print("  \(u.path)") }
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
    enum Phase { case recording, finalizing, converting, transcribing, done }

    private let lock = NSLock()
    private var phase: Phase = .recording
    private var count = 0
    private var _skipConversion = false
    private var sources: [DispatchSourceSignal] = []
    private let onStop: @Sendable (String) -> Void
    var sessionPath = ""

    init(onStop: @escaping @Sendable (String) -> Void) {
        self.onStop = onStop
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
            Console.print("\(name): 変換を省略して終了します")
        case .converting:
            Console.clearStatus()
            Console.print("\(name): 変換を中断しました。録音ファイル（CAF）は保存済みです。"
                + "送信用ファイルは `cappy recover \(sessionPath)` で作成できます")
            Foundation.exit(130)
        case .transcribing:
            Console.clearStatus()
            Console.print("\(name): 中断しました。`cappy transcribe \(sessionPath)` で再開できます")
            Foundation.exit(130)
        case .done:
            Foundation.exit(130)
        }
    }
}
