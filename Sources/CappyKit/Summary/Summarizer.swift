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
        var transcriptURL = store.url(for: TranscriptFormat.json.fileName)
        var fromLive = false
        if !FileManager.default.fileExists(atPath: transcriptURL.path) {
            let live = store.url(for: TranscriptFormat.json.fileName(base: LiveTranscription.baseName))
            if FileManager.default.fileExists(atPath: live.path) {
                transcriptURL = live
                fromLive = true
            }
        }
        guard let data = try? Data(contentsOf: transcriptURL) else {
            throw CappyError.usage(tr("No transcription result (transcript.json): \(store.directory.path)", ja: "文字起こしの結果（transcript.json）がありません: \(store.directory.path)"),
                                   hint: tr("Run `cappy transcribe \(store.directory.path)` first", ja: "先に `cappy transcribe \(store.directory.path)` を実行してください"))
        }
        let doc: TranscriptDocument
        do {
            doc = try JSONDecoder().decode(TranscriptDocument.self, from: data)
        } catch {
            throw CappyError.usage(tr("Cannot read transcript.json: \(error)", ja: "transcript.json を読めません: \(error)"),
                                   hint: tr("Recreate it with `cappy transcribe --force \(store.directory.path)`", ja: "`cappy transcribe --force \(store.directory.path)` で作り直せます"))
        }
        guard !doc.segments.isEmpty else {
            throw CappyError.usage(tr("The transcription is empty, so there is nothing to summarize", ja: "文字起こしの結果が空のため、要約できません"))
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
        CappyLog.shared.info(tr("Summary started provider=\(client.providerName) model=\(options.model) segments=\(doc.segments.count)", ja: "要約を開始しました provider=\(client.providerName) model=\(options.model) segments=\(doc.segments.count)"))

        // summary.md の注意書きは、会議の言語（transcript の language）で書く
        let docLang = UILanguage.forDocument(doc.language)
        var notes: [String] = []
        if fromLive {
            notes.append(tr(docLang, "Created from the live transcription (live-transcript.json). For better accuracy, run `cappy transcribe` and then `cappy summarize --force`",
                            ja: "リアルタイム文字起こし（live-transcript.json）から作成しました。精度を上げるには `cappy transcribe` の後に `cappy summarize --force`"))
        }
        let response: SummaryResponse
        do {
            var r = try await client.generate(request, model: options.model)
            if r.stopReason == "refusal" {
                let category = r.refusalCategory.map { tr(" (\($0))", ja: "（\($0)）") } ?? ""
                if let fb = options.fallbackModel, !fb.isEmpty, fb != options.model {
                    CappyLog.shared.warning(tr("\(options.model) refused to summarize\(category). Retrying with \(fb)", ja: "\(options.model) が要約を拒否しました\(category)。\(fb) で再試行します"))
                    notes.append(tr(docLang, "Created with \(fb) because \(options.model) refused", ja: "\(options.model) が拒否したため \(fb) で作成"))
                    r = try await client.generate(request, model: fb)
                }
                if r.stopReason == "refusal" {
                    throw CappyError.transcription(tr("The model refused to summarize\(r.refusalCategory.map { " (\($0))" } ?? "")", ja: "モデルが要約を拒否しました\(r.refusalCategory.map { tr(" (\($0))", ja: "（\($0)）") } ?? "")"))
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
            CappyLog.shared.error(tr("Summary failed: \(message)", ja: "要約に失敗しました: \(message)"))
            if let e = error as? CappyError { throw e }
            throw CappyError.transcription(tr("Summary failed: \(message)", ja: "要約に失敗しました: \(message)"), hint: Self.hint(for: error, model: options.model, region: client.region,
                                                                                               provider: client.providerName))
        }

        guard !response.text.isEmpty else {
            _ = try? store.update { m in
                m.summary?.state = .failed
                m.summary?.error = tr("The response has no text (stop_reason=\(response.stopReason ?? "-"))", ja: "応答に本文がありません（stop_reason=\(response.stopReason ?? "-")）")
            }
            throw CappyError.transcription(tr("The summary response has no text (stop_reason=\(response.stopReason ?? "-"))", ja: "要約の応答に本文がありません（stop_reason=\(response.stopReason ?? "-")）"),
                                           hint: response.stopReason == "max_tokens" ? tr("Increase summary.max_tokens", ja: "summary.max_tokens を増やしてください") : nil)
        }
        if response.stopReason == "max_tokens" {
            notes.append(tr(docLang, "Cut off because the output limit (max_tokens) was reached", ja: "出力上限（max_tokens）に達したため途中で切れています"))
            CappyLog.shared.warning(tr("The summary was cut off by max_tokens", ja: "要約が max_tokens で打ち切られました"))
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
        CappyLog.shared.info(tr("Summary finished model=\(response.model) input_tokens=\(response.inputTokens ?? -1) output_tokens=\(response.outputTokens ?? -1)", ja: "要約が完了しました model=\(response.model) input_tokens=\(response.inputTokens ?? -1) output_tokens=\(response.outputTokens ?? -1)"))
        return .created(outURL)
    }

    static func render(body: String, doc: TranscriptDocument, meta: SessionMetadata, response: SummaryResponse,
                       providerName: String, notes: [String], timeZone: TimeZone = .current) -> String {
        // 会議の言語（transcript の language）で書く
        let L = UILanguage.forDocument(doc.language)
        var lines: [String] = []
        let title = (meta.name ?? doc.name).flatMap { $0.isEmpty ? nil : $0 } ?? meta.id
        lines.append(tr(L, "# \(title) summary", ja: "# \(title) 要約"))
        lines.append("")
        if let s = meta.startedAt ?? doc.startedAt, let d = TimeFormat.parseISO8601(s) {
            lines.append(tr(L, "- Recording started: ", ja: "- 録音開始: ") + SummaryPrompt.localTime(d, timeZone))
        }
        if let length = meta.tracks.compactMap(\.durationMs).max() ?? doc.segments.map(\.endMs).max() {
            lines.append(tr(L, "- Length: ", ja: "- 長さ: ") + TimeFormat.hms(ms: length))
        }
        let via = ["vertex": "Vertex AI", "bedrock": "Amazon Bedrock"][providerName] ?? providerName
        lines.append(tr(L, "- Summary: generated automatically by \(response.model) (\(via)). Check important points in transcript.md",
                        ja: "- 要約: \(response.model)（\(via)）による自動生成です。重要な内容は transcript.md で確認してください"))
        for n in notes { lines.append(tr(L, "- Note: \(n)", ja: "- 注意: \(n)")) }
        lines.append("")
        lines.append(body)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func hint(for error: Error, model: String, region: String?, provider: String = "vertex") -> String? {
        if let a = error as? AWSAPIError { return bedrockHint(a, model: model, routing: region) }
        // ストリームの途中のエラー（ClaudeStreamParser）は GoogleAPIError で届く
        if provider == "bedrock", let g = error as? GoogleAPIError {
            return bedrockHint(AWSAPIError(httpStatus: g.httpStatus, code: g.status, message: g.message), model: model, routing: region)
        }
        guard let g = error as? GoogleAPIError else { return nil }
        switch g.httpStatus {
        case 401:
            return tr("Sign in again with `gcloud auth application-default login`", ja: "`gcloud auth application-default login` で認証し直してください")
        case 403:
            return tr("Check that the Vertex AI API (aiplatform.googleapis.com) is enabled and roles/aiplatform.user is granted", ja: "Vertex AI API の有効化（aiplatform.googleapis.com）と、roles/aiplatform.user の付与を確認してください")
        case 404:
            if SummaryModelFamily.of(model) == .gemini {
                return tr("\(model) is not available in \(region ?? "-"). Check the model ID and summary.region", ja: "\(model) が \(region ?? "-") で使えません。モデル ID と summary.region を確認してください")
            }
            return tr("\(model) is not available in \(region ?? "-"). Check that Claude is enabled in Model Garden, and check summary.model / summary.region", ja: "\(model) が \(region ?? "-") で使えません。Model Garden で Claude を有効にしているか、summary.model / summary.region を確認してください")
        case 429:
            return tr("The Claude quota on Vertex AI is exceeded. Run `cappy summarize` again later", ja: "Vertex AI の Claude のクォータを超えています。時間をおいて `cappy summarize` を再実行してください")
        default:
            return nil
        }
    }
}

extension Summarizer {
    public static func bedrockHint(_ e: AWSAPIError, model: String, routing: String?) -> String? {
        switch e.httpStatus {
        case 401:
            return tr("Check your AWS credentials (for SSO, `aws sso login`). `cappy doctor` can check them", ja: "AWS の認証情報を確認してください（SSO なら `aws sso login`）。`cappy doctor` で確認できます")
        case 403:
            if e.code == "permission_error" || e.code == "permission_denied_error" {
                if SummaryModelFamily.of(model) == .bedrockChat {
                    return tr("\(model) is not available for this account. Check \"Model access\" in the Amazon Bedrock console (some models, such as GLM-5.3, are limited to eligible customers and require contacting your AWS account team)", ja: "このアカウントでは \(model) を使えません。Amazon Bedrock コンソールの「モデルアクセス」を確認してください（GLM-5.3 など、利用できる顧客が限られていて AWS のアカウントチームへの問い合わせが必要なモデルもあります）")
                }
                return tr("Enable \(model) in \"Model access\" in the Amazon Bedrock console (Anthropic models require submitting use case details the first time)", ja: "Amazon Bedrock コンソールの「モデルアクセス」で \(model) を有効にしてください（Anthropic のモデルは初回に利用目的の申請が必要です）")
            }
            return tr("Check that IAM allows bedrock:InvokeModel and bedrock:InvokeModelWithResponseStream on the inference profile and on the foundation model in each Region", ja: "IAM で bedrock:InvokeModel と bedrock:InvokeModelWithResponseStream が、推論プロファイルと各リージョンの基盤モデルに許可されているか確認してください")
        case 400 where BedrockClaudeClient.isModelIdentifierError(e):
            return tr("\(BedrockModels.modelID(model, routing: routing ?? "global")) cannot be used. Check summary.model, summary.region (the inference profile scope) and the AWS region", ja: "\(BedrockModels.modelID(model, routing: routing ?? "global")) は使えません。summary.model と summary.region（推論プロファイルの範囲）、AWS のリージョンを確認してください")
                + (SummaryModelFamily.of(model) == .bedrockChat ? tr(" (in Tokyo, Kimi K3.1 and GLM-5.3 are available only through global; you can give the scope explicitly, e.g. `global.moonshotai.kimi-k3.1`)", ja: "（Kimi K3.1・GLM-5.3 は東京では global のみ。`global.moonshotai.kimi-k3.1` のように範囲を付けて指定できます）") : "")
        case 429:
            return tr("The Bedrock quota is exceeded. Run `cappy summarize` again later", ja: "Bedrock のクォータを超えています。時間をおいて `cappy summarize` を再実行してください")
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
                    tr("The Google Cloud project for summaries is not set", ja: "要約に使う Google Cloud プロジェクトが設定されていません"),
                    hint: tr("Set project_id in [profiles.\(profile.name).google] or [profiles.\(profile.name).summary]", ja: "[profiles.\(profile.name).google] の project_id、または [profiles.\(profile.name).summary] の project_id を設定してください"))
            }
            let auth = try ApplicationDefaultCredentials.load(transport: transport)
            return VertexSummaryClient(projectID: project, region: profile.summary.region, auth: auth, transport: transport)
        case "bedrock":
            let aws = profile.aws ?? AWSSettings()
            let credentials = try AWSCredentialsProvider.resolve(profile: aws.profile, region: aws.region, transport: transport)
            let routing = profile.summary.region
            guard let region = BedrockClaudeClient.isAWSRegion(routing) ? routing : credentials.region else {
                throw CappyError.usage(
                    tr("The AWS region for Bedrock is not set", ja: "Bedrock を呼び出す AWS のリージョンが設定されていません"),
                    hint: tr("Set region in [profiles.\(profile.name).aws], AWS_REGION, or region in the AWS profile", ja: "[profiles.\(profile.name).aws] の region、AWS_REGION、AWS のプロファイルの region のいずれかを設定してください"))
            }
            return BedrockSummaryClient(region: region, routing: routing, credentials: credentials, transport: transport)
        case "none":
            throw CappyError.usage(tr("Summary provider is none, so no summary", ja: "要約のプロバイダが none のため、要約は行いません"))
        default:
            throw CappyError.usage(tr("Unsupported summary provider: \(profile.summaryProvider) (vertex / bedrock / none)", ja: "未対応の要約プロバイダです: \(profile.summaryProvider)（vertex / bedrock / none）"))
        }
    }

    /// summary.instructions_file を読む
    public static func instructions(profile: Profile) throws -> String? {
        guard let path = profile.summary.instructionsFile, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: FileSecurity.expandTilde(path))
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CappyError.usage(tr("Cannot read summary.instructions_file: \(url.path): \(error.localizedDescription)", ja: "summary.instructions_file を読めません: \(url.path): \(error.localizedDescription)"))
        }
    }
}
