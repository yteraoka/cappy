import CryptoKit
import Foundation

/// transcript.json から会議の要約（summary.md）を作る
public struct Summarizer: Sendable {
    public static let fileName = "summary.md"

    public struct Options: Sendable {
        public var model: String
        /// refusal のときに使うモデル（nil / 空なら再試行しない）
        public var fallbackModel: String?
        public var effort: String
        public var maxTokens: Int
        public var language: String
        public var instructions: String?
        public var force: Bool

        public init(model: String, fallbackModel: String?, effort: String, maxTokens: Int, language: String,
                    instructions: String? = nil, force: Bool = false) {
            self.model = model
            self.fallbackModel = fallbackModel
            self.effort = effort
            self.maxTokens = maxTokens
            self.language = language
            self.instructions = instructions
            self.force = force
        }
    }

    public enum Outcome: Sendable, Equatable {
        case created(URL)
        /// 同じ文字起こしから作った要約がすでにある
        case upToDate(URL)

        public var url: URL {
            switch self {
            case .created(let u), .upToDate(let u): return u
            }
        }
    }

    let store: SessionStore
    let client: SummaryModelClient
    let options: Options

    public init(store: SessionStore, client: SummaryModelClient, options: Options) {
        self.store = store
        self.client = client
        self.options = options
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func run() async throws -> Outcome {
        let transcriptURL = store.url(for: TranscriptFormat.json.fileName)
        guard let data = try? Data(contentsOf: transcriptURL) else {
            throw CappyError.usage("文字起こしの結果（transcript.json）がありません: \(store.directory.path)",
                                   hint: "先に `cappy transcribe \(store.directory.path)` を実行してください")
        }
        let doc: TranscriptDocument
        do {
            doc = try JSONDecoder().decode(TranscriptDocument.self, from: data)
        } catch {
            throw CappyError.usage("transcript.json を読めません: \(error)",
                                   hint: "`cappy transcribe --force \(store.directory.path)` で作り直せます")
        }
        guard !doc.segments.isEmpty else {
            throw CappyError.usage("文字起こしの結果が空のため、要約できません")
        }
        let digest = Self.digest(data)
        let outURL = store.url(for: Self.fileName)
        if !options.force, let s = store.metadata.summary, s.state == .done, s.transcriptDigest == digest,
           FileManager.default.fileExists(atPath: outURL.path) {
            return .upToDate(outURL)
        }

        let request = SummaryRequest(
            system: SummaryPrompt.system(language: options.language, extraInstructions: options.instructions),
            userText: SummaryPrompt.user(doc: doc, meta: store.metadata),
            maxTokens: options.maxTokens, effort: options.effort)

        try store.update { m in
            var s = SummaryState(provider: client.providerName, model: options.model, region: client.region)
            s.state = .running
            s.transcriptDigest = digest
            s.updatedAt = TimeFormat.iso8601(Date())
            m.summary = s
        }
        CappyLog.shared.info("要約を開始しました provider=\(client.providerName) model=\(options.model) segments=\(doc.segments.count)")

        var notes: [String] = []
        let response: SummaryResponse
        do {
            var r = try await client.generate(request, model: options.model)
            if r.stopReason == "refusal" {
                let category = r.refusalCategory.map { "（\($0)）" } ?? ""
                if let fb = options.fallbackModel, !fb.isEmpty, fb != options.model {
                    CappyLog.shared.warning("\(options.model) が要約を拒否しました\(category)。\(fb) で再試行します")
                    notes.append("\(options.model) が拒否したため \(fb) で作成")
                    r = try await client.generate(request, model: fb)
                }
                if r.stopReason == "refusal" {
                    throw CappyError.transcription("モデルが要約を拒否しました\(r.refusalCategory.map { "（\($0)）" } ?? "")")
                }
            }
            response = r
        } catch {
            let message = (error as? CappyError)?.message ?? "\(error)"
            _ = try? store.update { m in
                m.summary?.state = .failed
                m.summary?.error = message
                m.summary?.updatedAt = TimeFormat.iso8601(Date())
            }
            CappyLog.shared.error("要約に失敗しました: \(message)")
            if let e = error as? CappyError { throw e }
            throw CappyError.transcription("要約に失敗しました: \(message)", hint: Self.hint(for: error, model: options.model, region: client.region))
        }

        guard !response.text.isEmpty else {
            _ = try? store.update { m in
                m.summary?.state = .failed
                m.summary?.error = "応答に本文がありません（stop_reason=\(response.stopReason ?? "-")）"
            }
            throw CappyError.transcription("要約の応答に本文がありません（stop_reason=\(response.stopReason ?? "-")）",
                                           hint: response.stopReason == "max_tokens" ? "summary.max_tokens を増やしてください" : nil)
        }
        if response.stopReason == "max_tokens" {
            notes.append("出力上限（max_tokens）に達したため途中で切れています")
            CappyLog.shared.warning("要約が max_tokens で打ち切られました")
        }

        let markdown = Self.render(body: response.text, doc: doc, meta: store.metadata, response: response,
                                   providerName: client.providerName, notes: notes)
        try FileSecurity.writeAtomically(Data(markdown.utf8), to: outURL)
        try store.update { m in
            m.summary?.state = .done
            m.summary?.model = response.model
            m.summary?.file = Self.fileName
            m.summary?.inputTokens = response.inputTokens
            m.summary?.outputTokens = response.outputTokens
            m.summary?.stopReason = response.stopReason
            m.summary?.note = notes.isEmpty ? nil : notes.joined(separator: "; ")
            m.summary?.error = nil
            m.summary?.updatedAt = TimeFormat.iso8601(Date())
        }
        CappyLog.shared.info("要約が完了しました model=\(response.model) input_tokens=\(response.inputTokens ?? -1) output_tokens=\(response.outputTokens ?? -1)")
        return .created(outURL)
    }

    static func render(body: String, doc: TranscriptDocument, meta: SessionMetadata, response: SummaryResponse,
                       providerName: String, notes: [String], timeZone: TimeZone = .current) -> String {
        var lines: [String] = []
        let title = (meta.name ?? doc.name).flatMap { $0.isEmpty ? nil : $0 } ?? meta.id
        lines.append("# \(title) 要約")
        lines.append("")
        if let s = meta.startedAt ?? doc.startedAt, let d = TimeFormat.parseISO8601(s) {
            lines.append("- 録音開始: \(SummaryPrompt.localTime(d, timeZone))")
        }
        if let length = meta.tracks.compactMap(\.durationMs).max() ?? doc.segments.map(\.endMs).max() {
            lines.append("- 長さ: \(TimeFormat.hms(ms: length))")
        }
        let via = providerName == "vertex" ? "Vertex AI" : providerName
        lines.append("- 要約: \(response.model)（\(via)）による自動生成です。重要な内容は transcript.md で確認してください")
        for n in notes { lines.append("- 注意: \(n)") }
        lines.append("")
        lines.append(body)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func hint(for error: Error, model: String, region: String?) -> String? {
        guard let g = error as? GoogleAPIError else { return nil }
        switch g.httpStatus {
        case 401:
            return "`gcloud auth application-default login` で認証し直してください"
        case 403:
            return "Vertex AI API の有効化（aiplatform.googleapis.com）と、roles/aiplatform.user の付与を確認してください"
        case 404:
            if SummaryModelFamily.of(model) == .gemini {
                return "\(model) が \(region ?? "-") で使えません。モデル ID と summary.region を確認してください"
            }
            return "\(model) が \(region ?? "-") で使えません。Model Garden で Claude を有効にしているか、summary.model / summary.region を確認してください"
        case 429:
            return "Vertex AI の Claude のクォータを超えています。時間をおいて `cappy summarize` を再実行してください"
        default:
            return nil
        }
    }
}

/// プロファイルから要約クライアントを作る
public enum SummaryClientFactory {
    public static func make(profile: Profile, transport: HTTPTransport = URLSessionTransport()) throws -> SummaryModelClient {
        switch profile.summaryProvider {
        case "vertex":
            guard let project = profile.summaryProjectID, !project.isEmpty else {
                throw CappyError.usage(
                    "要約に使う Google Cloud プロジェクトが設定されていません",
                    hint: "[profiles.\(profile.name).google] の project_id、または [profiles.\(profile.name).summary] の project_id を設定してください")
            }
            let auth = try ApplicationDefaultCredentials.load(transport: transport)
            return VertexSummaryClient(projectID: project, region: profile.summary.region, auth: auth, transport: transport)
        case "none":
            throw CappyError.usage("要約のプロバイダが none のため、要約は行いません")
        default:
            throw CappyError.usage("未対応の要約プロバイダです: \(profile.summaryProvider)（vertex / none）")
        }
    }

    /// summary.instructions_file を読む
    public static func instructions(profile: Profile) throws -> String? {
        guard let path = profile.summary.instructionsFile, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: FileSecurity.expandTilde(path))
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CappyError.usage("summary.instructions_file を読めません: \(url.path): \(error.localizedDescription)")
        }
    }
}
