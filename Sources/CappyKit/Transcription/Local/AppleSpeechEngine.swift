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

    static func recognize(_ audio: URL, language: String) async throws -> [RecognizedPiece] {
        let locale = try await locale(for: language)
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Console.status(tr("Downloading the speech model for \(language) (the first time only)…", ja: "\(language) の音声モデルをダウンロードしています（初回のみ）…"))
            try await request.downloadAndInstall()
        }
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
