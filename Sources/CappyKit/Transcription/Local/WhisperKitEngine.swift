import Foundation
import SpeakerKit
import WhisperKit

/// WhisperKit（Core ML の Whisper）による端末内の音声認識。モデルは初回にダウンロードして model_dir に置く
public struct WhisperKitRecognizer: LocalRecognizer {
    public let whisperModel: String?
    public let modelDirectory: URL

    public var name: String { "whisperkit" }
    public var model: String? { whisperModel }

    public init(whisperModel: String?, modelDirectory: URL) {
        self.whisperModel = whisperModel
        self.modelDirectory = modelDirectory
    }

    public func recognize(_ audio: URL, language: String, vocabulary: [String]) async throws -> [RecognizedPiece] {
        try FileSecurity.createPrivateDirectory(modelDirectory)
        Console.status(tr("Loading the WhisperKit model (downloaded the first time)…", ja: "WhisperKit のモデルを読み込んでいます（初回はダウンロードします）…"))
        let config = WhisperKitConfig(model: whisperModel, downloadBase: modelDirectory,
                                      verbose: false, prewarm: false, load: true, download: true)
        let pipe = try await WhisperKit(config)
        var options = DecodingOptions(
            task: .transcribe,
            language: Self.whisperLanguage(language),
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            chunkingStrategy: .vad)
        if !vocabulary.isEmpty, let tokenizer = pipe.tokenizer {
            // 固有名詞などをプロンプトに入れて認識を寄せる（長すぎると認識を乱すので先頭の一部だけ）
            let prompt = vocabulary.prefix(50).joined(separator: ", ")
            options.promptTokens = tokenizer.encode(text: " " + prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        Console.status(tr("Recognizing with WhisperKit (\(pipe.modelFolder?.lastPathComponent ?? "whisper"))…", ja: "WhisperKit で認識しています（\(pipe.modelFolder?.lastPathComponent ?? "whisper")）…"))
        let results = try await pipe.transcribe(audioPath: audio.path, decodeOptions: options)
        return results.flatMap { $0.segments }.map { s in
            RecognizedPiece(startMs: Int64((Double(s.start) * 1000).rounded()), endMs: Int64((Double(s.end) * 1000).rounded()),
                            text: Self.clean(s.text), confidence: nil)
        }
    }

    /// ja-JP → ja（Whisper の言語コード）
    static func whisperLanguage(_ code: String) -> String {
        let base = code.split(separator: "-").first.map { String($0).lowercased() } ?? code.lowercased()
        return base == "zh" ? "zh" : base
    }

    /// 残った特殊トークン（<|0.00|> など）を除く
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|>]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// SpeakerKit（pyannote の Core ML 版）による端末内の話者分離
public struct SpeakerKitDiarizerEngine: LocalDiarizer {
    public let modelDirectory: URL

    public init(modelDirectory: URL) { self.modelDirectory = modelDirectory }

    public func diarize(_ audio: URL, numSpeakers: Int?) async throws -> [SpeakerTurn] {
        try FileSecurity.createPrivateDirectory(modelDirectory)
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path)
        let config = PyannoteConfig(downloadBase: modelDirectory.path, download: true, verbose: false)
        let kit = try await SpeakerKit(config)
        let result = try await kit.diarize(audioArray: samples, options: PyannoteDiarizationOptions(numberOfSpeakers: numSpeakers))
        return result.segments.compactMap { s in
            guard let id = s.speaker.speakerId else { return nil }
            return SpeakerTurn(speaker: "spk_\(id)", startMs: Int64((Double(s.startTime) * 1000).rounded()),
                               endMs: Int64((Double(s.endTime) * 1000).rounded()))
        }
    }
}
