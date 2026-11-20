import AVFoundation
import CoreMedia
import Foundation
#if canImport(Speech)
import Speech
#endif

/// Apple の SpeechAnalyzer / SpeechTranscriber（macOS 26 以降）による端末内の音声認識。
/// 言語の音声モデルは OS が管理し、初回にダウンロードする。話者分離はしない（SpeakerKit と組み合わせる）
public struct AppleSpeechRecognizer: LocalRecognizer {
    public var name: String { "apple" }
    public var model: String? { "SpeechTranscriber" }

    public init() {}

    /// この Mac で使えるか（macOS 26 以降で、macOS 26 の SDK でビルドしたとき）
    public static var isSupported: Bool {
        #if canImport(Speech) && compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    public func recognize(_ audio: URL, language: String, vocabulary: [String]) async throws -> [RecognizedPiece] {
        #if canImport(Speech) && compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return try await AppleSpeechAnalysis.recognize(audio, language: language)
        }
        #endif
        throw CappyError.usage(tr("Apple SpeechTranscriber needs macOS 26 or later", ja: "Apple の SpeechTranscriber は macOS 26 以降で使えます"),
                               hint: tr("Use transcribe.model = \"whisperkit\" instead", ja: "代わりに transcribe.model = \"whisperkit\" を使ってください"))
    }

    /// 言語の音声モデルを用意する（cappy doctor --download-models）
    public static func prepare(language: String) async throws {
        #if canImport(Speech) && compiler(>=6.2)
        if #available(macOS 26.0, *) {
            try await AppleSpeechAnalysis.installAssets(language: language)
            Console.clearStatus()
            return
        }
        #endif
        throw CappyError.usage(tr("Apple SpeechTranscriber needs macOS 26 or later", ja: "Apple の SpeechTranscriber は macOS 26 以降で使えます"))
    }

    /// 言語の対応状況（doctor 用）。対応していなければ nil、対応していれば導入済みか
    public static func localeStatus(_ language: String) async -> (supported: Bool, installed: Bool)? {
        #if canImport(Speech) && compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return await AppleSpeechAnalysis.localeStatus(language)
        }
        #endif
        return nil
    }
}

#if canImport(Speech) && compiler(>=6.2)
@available(macOS 26.0, *)
enum AppleSpeechAnalysis {
    static func locale(for language: String) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else {
            throw CappyError.usage(tr("Apple SpeechTranscriber is not available on this Mac", ja: "この Mac では Apple の SpeechTranscriber を使えません"),
                                   hint: tr("Use transcribe.model = \"whisperkit\" instead", ja: "代わりに transcribe.model = \"whisperkit\" を使ってください"))
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw CappyError.usage(tr("Apple SpeechTranscriber does not support \(language)", ja: "Apple の SpeechTranscriber は \(language) に対応していません"),
                                   hint: tr("Use transcribe.model = \"whisperkit\" instead", ja: "代わりに transcribe.model = \"whisperkit\" を使ってください"))
        }
        return locale
    }

    static func localeStatus(_ language: String) async -> (supported: Bool, installed: Bool)? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else { return nil }
        let installed = await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        return (true, installed)
    }

    static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    static func installAssets(for transcriber: SpeechTranscriber, language: String) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Console.status(tr("Downloading the speech model for \(language) (the first time only)…", ja: "\(language) の音声モデルをダウンロードしています（初回のみ）…"))
            try await request.downloadAndInstall()
        }
    }

    static func installAssets(language: String) async throws {
        let locale = try await locale(for: language)
        try await installAssets(for: makeTranscriber(locale), language: language)
    }

    static func recognize(_ audio: URL, language: String) async throws -> [RecognizedPiece] {
        let locale = try await locale(for: language)
        let transcriber = makeTranscriber(locale)
        try await installAssets(for: transcriber, language: language)
        Console.status(tr("Recognizing with Apple SpeechTranscriber…", ja: "Apple の SpeechTranscriber で認識しています…"))
        let file = try AVAudioFile(forReading: audio)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [RecognizedPiece] in
            var out: [RecognizedPiece] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters)
                out.append(RecognizedPiece(startMs: AppleSpeechAnalysis.milliseconds(result.range.start), endMs: AppleSpeechAnalysis.milliseconds(result.range.end), text: text))
            }
            return out
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    static func milliseconds(_ t: CMTime) -> Int64 {
        guard t.isValid, t.isNumeric else { return 0 }
        return Int64((t.seconds * 1000).rounded())
    }
}
#endif

/// Apple の SpeechTranscriber による端末内のリアルタイム文字起こし（macOS 26 以降）。
/// 音声をそのまま流し込み、認識途中の文字（volatile）と確定した発言を受け取る
public struct AppleLiveBackend: LiveBackend {
    public init() {}

    public func open(startMs: Int64, options: LiveTranscriber.Options,
                     onEvent: @escaping @Sendable (LiveTranscriber.Event) -> Void) async throws -> LiveSession {
        #if canImport(Speech) && compiler(>=6.2)
        if #available(macOS 26.0, *) {
            do {
                return try await AppleLiveSession.open(startMs: startMs, track: options.track, language: options.language, onEvent: onEvent)
            } catch let e as CappyError {
                throw LiveConnectionError(message: e.message, permanent: true)
            }
        }
        #endif
        throw LiveConnectionError(message: tr("Apple SpeechTranscriber needs macOS 26 or later", ja: "Apple の SpeechTranscriber は macOS 26 以降で使えます"),
                                  permanent: true)
    }
}

#if canImport(Speech) && compiler(>=6.2)
@available(macOS 26.0, *)
final class AppleLiveSession: LiveSession, @unchecked Sendable {
    let startMs: Int64
    let track: TrackID
    let onEvent: @Sendable (LiveTranscriber.Event) -> Void
    let analyzer: SpeechAnalyzer
    let input: AsyncStream<AnalyzerInput>.Continuation
    /// 解析に渡す形式（16 kHz・モノラル・16 bit から変換する）
    let format: AVAudioFormat
    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: LiveAudioSink.sampleRate,
                                             channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var results: Task<Void, Never>?
    private var dead = false
    private var _deathReason: String?

    private init(startMs: Int64, track: TrackID, analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation,
                 format: AVAudioFormat, onEvent: @escaping @Sendable (LiveTranscriber.Event) -> Void) {
        self.startMs = startMs
        self.track = track
        self.analyzer = analyzer
        self.input = input
        self.format = format
        self.onEvent = onEvent
        if !format.isEqual(sourceFormat) { converter = AVAudioConverter(from: sourceFormat, to: format) }
    }

    static func open(startMs: Int64, track: TrackID, language: String,
                     onEvent: @escaping @Sendable (LiveTranscriber.Event) -> Void) async throws -> AppleLiveSession {
        let locale = try await AppleSpeechAnalysis.locale(for: language)
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                            attributeOptions: [.audioTimeRange])
        try await AppleSpeechAnalysis.installAssets(for: transcriber, language: language)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: LiveAudioSink.sampleRate, channels: 1, interleaved: true)!
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let session = AppleLiveSession(startMs: startMs, track: track, analyzer: analyzer, input: continuation,
                                       format: format, onEvent: onEvent)
        let base = startMs
        session.results = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        onEvent(.interim(track, nil))
                        guard !text.isEmpty else { continue }
                        onEvent(.segment(Segment(track: track, speaker: nil,
                                                 startMs: base + AppleSpeechAnalysis.milliseconds(result.range.start),
                                                 endMs: base + AppleSpeechAnalysis.milliseconds(result.range.end),
                                                 text: text, confidence: nil)))
                    } else {
                        onEvent(.interim(track, text.isEmpty ? nil : text))
                    }
                }
            } catch {
                session.markDead(String(describing: error))
            }
        }
        try await analyzer.start(inputSequence: stream)
        return session
    }

    var isDead: Bool { lock.withLock { dead } }
    var deathReason: String? { lock.withLock { _deathReason } }
    var deathIsPermanent: Bool { false }

    func markDead(_ reason: String) {
        lock.withLock {
            if !dead { _deathReason = reason }
            dead = true
        }
    }

    func sendAudio(_ chunk: LiveTranscriber.Chunk) async throws {
        let frames = AVAudioFrameCount(chunk.pcm.count / 2)
        guard frames > 0, let src = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames),
              let dst = src.int16ChannelData?[0] else { return }
        src.frameLength = frames
        chunk.pcm.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(dst, base, Int(frames) * 2) }
        }
        let buffer: AVAudioPCMBuffer
        if let converter = lock.withLock({ converter }) {
            let capacity = AVAudioFrameCount(Double(frames) * format.sampleRate / sourceFormat.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            let (status, error) = converter.convertSingleBuffer(src, to: out)
            if status == .error {
                if let error { throw error }
                throw CappyError.transcription(tr("Could not convert the audio", ja: "音声を変換できませんでした"))
            }
            buffer = out
        } else {
            buffer = src
        }
        input.yield(AnalyzerInput(buffer: buffer))
    }

    /// 端末内では時間の制限がないので張り替えない
    func shouldRotate(at positionMs: Int64, options: LiveTranscriber.Options) -> Bool { false }

    func endAndDrain(timeout: Double) async {
        input.finish()
        let analyzer = self.analyzer
        let results = lock.withLock { self.results }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                await results?.value
            }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)) }
            await group.next()
            group.cancelAll()
        }
        onEvent(.interim(track, nil))
    }
}
#endif
