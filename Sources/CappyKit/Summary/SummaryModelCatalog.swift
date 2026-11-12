import Foundation

/// 要約に使えるモデルの 1 件（`summary.model` / `--summary-model` に書ける値）
public struct SummaryModelOption: Equatable, Sendable {
    /// `summary.model` に書く値（`claude-opus-5-5`、`gemini-4-argon`、`moonshotai.kimi-k3.1` など）
    public var id: String
    /// 表示名（API が返したもの。なければ nil）
    public var name: String?
    /// 使えることを確かめたか（false: 一時的なエラーなどで確かめられなかった）
    public var verified: Bool

    public init(id: String, name: String? = nil, verified: Bool = true) {
        self.id = id
        self.name = name
        self.verified = verified
    }
}

/// 要約に使えるモデルの一覧を API で取得する。
///
/// - Vertex AI: Model Garden の `publishers/{google,anthropic}/models`（v1beta1 の publishers.models.list）。
///   プロジェクトで有効にしているかどうかや、summary.region で使えるかまでは分からない
///   （Claude は Model Garden での有効化が別に必要）
/// - Bedrock: `ListFoundationModels`（出力がテキストのモデル）と `ListInferenceProfiles`（システム定義の推論プロファイル）。
///   summary.region が推論プロファイルの範囲（global / jp など）なら、その範囲の推論プロファイルがあるモデル、
///   リージョン名なら、そのリージョンでオンデマンドで呼べるモデル
///
/// 一覧には申請・有効化をしていないモデル（Anthropic のモデルなど）も含まれるため、
/// 各モデルを課金されない方法で呼んでみて（`checkAvailable`）、使えるものだけに絞る
public enum SummaryModelCatalog {
    /// モデルを使えるかの確認（使えなければ throw）
    public typealias AccessCheck = @Sendable (String) async throws -> Void

    /// 一覧の取得先を区別するキー（プロファイルが違っても取得先が同じなら同じ一覧を使う）
    public static func cacheKey(for profile: Profile) -> String {
        switch profile.summaryProvider {
        case "google":
            return "google|\(profile.summaryProjectID ?? "")|\(profile.summary.region)"
        case "aws":
            let aws = profile.aws ?? AWSSettings()
            return "aws|\(aws.profile ?? "")|\(aws.region ?? "")|\(profile.summary.region)"
        default:
            return profile.summaryProvider
        }
    }

    public static func list(profile: Profile, transport: HTTPTransport = URLSessionTransport()) async throws -> [SummaryModelOption] {
        switch profile.summaryProvider {
        case "google":
            guard let project = profile.summaryProjectID.flatMap({ $0.isEmpty ? nil : $0 }) else {
                throw CappyError.usage(
                    tr("The Google Cloud project for summaries is not set", ja: "要約に使う Google Cloud プロジェクトが設定されていません"),
                    hint: tr("Set project_id in [profiles.\(profile.name).google] or [profiles.\(profile.name).summary]", ja: "[profiles.\(profile.name).google] の project_id、または [profiles.\(profile.name).summary] の project_id を設定してください"))
            }
            let auth = try ApplicationDefaultCredentials.load(transport: transport)
            let models = try await listVertex(userProject: project, auth: auth, transport: transport)
            let region = profile.summary.region, effort = profile.summary.effort
            let claude = ClaudeVertexClient(projectID: project, region: region, auth: auth, transport: transport, retry: .none)
            let gemini = GeminiVertexClient(projectID: project, region: region, auth: auth, transport: transport, retry: .none)
            return try await checkAvailable(models) { model in
                if SummaryModelFamily.of(model) == .claude {
                    try await claude.checkModelAccess(model: model)
                } else {
                    try await gemini.checkAccess(model: model, effort: effort)
                }
            }
        case "aws":
            let aws = profile.aws ?? AWSSettings()
            let credentials = try AWSCredentialsProvider.resolve(profile: aws.profile, region: aws.region, transport: transport)
            let routing = profile.summary.region
            guard let region = BedrockClaudeClient.isAWSRegion(routing) ? routing : credentials.region else {
                throw CappyError.usage(
                    tr("The AWS region for Bedrock is not set", ja: "Bedrock を呼び出す AWS のリージョンが設定されていません"),
                    hint: tr("Set region in [profiles.\(profile.name).aws], AWS_REGION, or region in the AWS profile", ja: "[profiles.\(profile.name).aws] の region、AWS_REGION、AWS のプロファイルの region のいずれかを設定してください"))
            }
            let models = try await listBedrock(region: region, routing: routing, credentials: credentials, transport: transport)
            let client = BedrockSummaryClient(region: region, routing: routing, credentials: credentials, transport: transport, retry: .none)
            let effort = profile.summary.effort
            return try await checkAvailable(models) { model in
                try await client.checkAccess(model: model, effort: effort)
            }
        default:
            return []
        }
    }

    // MARK: - Vertex AI

    /// Model Garden の Gemini と Claude（名前順。Gemini が先）
    public static func listVertex(userProject: String?, auth: AccessTokenProvider,
                                  transport: HTTPTransport) async throws -> [SummaryModelOption] {
        var result: [SummaryModelOption] = []
        for publisher in ["google", "anthropic"] {
            var pageToken: String?
            var pages = 0
            repeat {
                var comps = URLComponents()
                comps.scheme = "https"
                // モデルの一覧は場所によらないため、グローバルのエンドポイントで取得する
                comps.host = VertexAI.host(region: "global")
                comps.path = "/v1beta1/publishers/\(publisher)/models"
                comps.queryItems = [URLQueryItem(name: "pageSize", value: "100")]
                    + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
                var req = URLRequest(url: comps.url!)
                req.httpMethod = "GET"
                req.timeoutInterval = 30
                req.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
                if let userProject { req.setValue(userProject, forHTTPHeaderField: "x-goog-user-project") }
                let resp = try await transport.send(req)
                guard resp.status == 200 else { throw GoogleAPIError.from(resp) }
                let page = try parseVertex(resp.body)
                result += page.models
                pageToken = page.nextPageToken
                pages += 1
            } while pageToken != nil && pages < 20
        }
        return sorted(dedup(result))
    }

    /// publishers.models.list の応答から、要約に使えるモデルを取り出す
    static func parseVertex(_ data: Data) throws -> (models: [SummaryModelOption], nextPageToken: String?) {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CappyError.transcription(tr("Invalid model list response", ja: "モデル一覧の応答が不正です"))
        }
        let items = obj["publisherModels"] as? [[String: Any]] ?? []
        var models: [SummaryModelOption] = []
        for item in items {
            guard let name = item["name"] as? String, let id = name.split(separator: "/").last.map(String.init) else { continue }
            guard isVertexTextModel(id) else { continue }
            // 廃止済み・非公開のものは出さない
            if let stage = item["launchStage"] as? String, ["DEPRECATED", "LAUNCH_STAGE_UNSPECIFIED"].contains(stage) { continue }
            models.append(SummaryModelOption(id: id, name: item["displayName"] as? String))
        }
        let token = (obj["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (models, token)
    }

    /// Vertex AI のモデル ID のうち、要約（テキストの生成）に使えそうなもの
    static func isVertexTextModel(_ id: String) -> Bool {
        let m = id.lowercased()
        guard let family = SummaryModelFamily.of(m), family == .gemini || family == .claude else { return false }
        // 埋め込み・画像・音声・リアルタイム・文字起こし用のモデルは除く
        let excluded = ["embedding", "image", "tts", "live", "audio", "transcribe", "native", "computer-use", "veo", "imagen"]
        return !excluded.contains { m.contains($0) }
    }

    // MARK: - Bedrock

    public static func listBedrock(region: String, routing: String, credentials: AWSCredentialsSource,
                                   transport: HTTPTransport) async throws -> [SummaryModelOption] {
        let host = "https://bedrock.\(region).amazonaws.com"
        let foundation = try await bedrockGET(URL(string: "\(host)/foundation-models?byOutputModality=TEXT")!,
                                              region: region, credentials: credentials, transport: transport)
        let models = try parseFoundationModels(foundation)
        if BedrockClaudeClient.isAWSRegion(routing) {
            // そのリージョンだけで処理する: オンデマンドで呼べるモデル
            return sorted(dedup(models.filter(\.onDemand).compactMap { option(bedrockID: $0.id, name: $0.name) }))
        }
        var profiles: [String] = []
        var nextToken: String?
        var pages = 0
        repeat {
            var comps = URLComponents(string: "\(host)/inference-profiles")!
            comps.queryItems = [URLQueryItem(name: "typeEquals", value: "SYSTEM_DEFINED"), URLQueryItem(name: "maxResults", value: "1000")]
                + (nextToken.map { [URLQueryItem(name: "nextToken", value: $0)] } ?? [])
            let page = try parseInferenceProfiles(try await bedrockGET(comps.url!, region: region, credentials: credentials, transport: transport))
            profiles += page.ids
            nextToken = page.nextToken
            pages += 1
        } while nextToken != nil && pages < 20
        let names = Dictionary(models.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let prefix = routing + "."
        let options: [SummaryModelOption] = profiles.compactMap { profile -> SummaryModelOption? in
            guard profile.hasPrefix(prefix) else { return nil }
            let base = String(profile.dropFirst(prefix.count))
            // 出力がテキストの基盤モデルのものだけ（埋め込みや画像のモデルを除く）
            guard let name = names[base] else { return nil }
            return option(bedrockID: base, name: name)
        }
        return sorted(dedup(options))
    }

    static func bedrockGET(_ url: URL, region: String, credentials: AWSCredentialsSource, transport: HTTPTransport) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        SigV4Signer(credentials: try await credentials.credentials(), region: region, service: "bedrock").sign(&req)
        let resp = try await transport.send(req)
        guard resp.status == 200 else { throw AWSAPIError.from(resp) }
        return resp.body
    }

    struct FoundationModel: Equatable {
        var id: String
        var name: String?
        var onDemand: Bool
    }

    /// ListFoundationModels の応答（`modelSummaries`）。LEGACY のモデルは除く
    static func parseFoundationModels(_ data: Data) throws -> [FoundationModel] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CappyError.transcription(tr("Invalid model list response", ja: "モデル一覧の応答が不正です"))
        }
        return (obj["modelSummaries"] as? [[String: Any]] ?? []).compactMap { m -> FoundationModel? in
            guard let id = m["modelId"] as? String else { return nil }
            if let outputs = m["outputModalities"] as? [String], !outputs.contains("TEXT") { return nil }
            if let status = (m["modelLifecycle"] as? [String: Any])?["status"] as? String, status != "ACTIVE" { return nil }
            let types = m["inferenceTypesSupported"] as? [String] ?? []
            let name = [m["providerName"] as? String, m["modelName"] as? String].compactMap { $0 }.joined(separator: " ")
            return FoundationModel(id: id, name: name.isEmpty ? nil : name, onDemand: types.contains("ON_DEMAND"))
        }
    }

    /// ListInferenceProfiles の応答（`inferenceProfileSummaries`）。ACTIVE のものの ID
    static func parseInferenceProfiles(_ data: Data) throws -> (ids: [String], nextToken: String?) {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CappyError.transcription(tr("Invalid inference profile list response", ja: "推論プロファイル一覧の応答が不正です"))
        }
        let ids = (obj["inferenceProfileSummaries"] as? [[String: Any]] ?? []).compactMap { p -> String? in
            if let status = p["status"] as? String, status != "ACTIVE" { return nil }
            return p["inferenceProfileId"] as? String
        }
        return (ids, (obj["nextToken"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Bedrock の基盤モデルの ID（範囲なし）を `summary.model` に書く値にする。
    /// Anthropic のモデルは `claude-…`、それ以外は Bedrock の ID のまま（範囲は summary.region から付く）
    static func option(bedrockID id: String, name: String?) -> SummaryModelOption? {
        var model = id
        if model.hasPrefix("anthropic.") { model = String(model.dropFirst("anthropic.".count)) }
        guard let family = SummaryModelFamily.of(model), family != .gemini else { return nil }
        return SummaryModelOption(id: model, name: name)
    }

    // MARK: - 使えるかの確認

    /// 確認の結果
    enum Availability: Equatable {
        case available
        /// 申請・有効化していない、リージョンで使えないなど
        case unavailable
        /// 一時的なエラー（429 / 5xx / 通信）で確かめられなかった
        case unknown
    }

    /// エラーを分類する。認証の誤り（401）はどのモデルでも同じなので、一覧の取得の失敗として投げ直す
    static func classify(_ error: Error) throws -> Availability {
        let status: Int?
        if let e = error as? AWSAPIError { status = e.httpStatus }
        else if let e = error as? GoogleAPIError { status = e.httpStatus }
        else { status = nil }
        switch status {
        case 401?: throw error
        case 400?, 403?, 404?: return .unavailable
        default:
            if error is CappyError { return .unavailable } // このクライアントでは扱えないモデル
            return .unknown
        }
    }

    /// 各モデルを確かめて、使えるものだけを返す（順番はそのまま）。
    /// 確かめられなかったものは verified = false で残す
    public static func checkAvailable(_ models: [SummaryModelOption], concurrency: Int = 8,
                                      check: @escaping AccessCheck) async throws -> [SummaryModelOption] {
        var results = [Availability?](repeating: nil, count: models.count)
        try await withThrowingTaskGroup(of: (Int, Availability).self) { group in
            var next = 0
            while next < models.count {
                // 同時に確かめる数を concurrency までにする
                if next >= concurrency, let done = try await group.next() { results[done.0] = done.1 }
                let i = next, id = models[i].id
                next += 1
                group.addTask {
                    do {
                        try await check(id)
                        return (i, Availability.available)
                    } catch {
                        return (i, try SummaryModelCatalog.classify(error))
                    }
                }
            }
            while let done = try await group.next() { results[done.0] = done.1 }
        }
        return models.enumerated().compactMap { i, m in
            switch results[i] {
            case .available?: return m
            case .unknown?:
                var u = m
                u.verified = false
                return u
            case .unavailable?, nil: return nil
            }
        }
    }

    // MARK: - 共通

    static func dedup(_ list: [SummaryModelOption]) -> [SummaryModelOption] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }

    /// Gemini → Claude → そのほかの順に、それぞれ ID の降順（新しい版が上に来やすい）
    static func sorted(_ list: [SummaryModelOption]) -> [SummaryModelOption] {
        func rank(_ id: String) -> Int {
            switch SummaryModelFamily.of(id) {
            case .gemini: return 0
            case .claude: return 1
            default: return 2
            }
        }
        return list.sorted { a, b in
            let (ra, rb) = (rank(a.id), rank(b.id))
            if ra != rb { return ra < rb }
            return a.id.compare(b.id, options: .numeric) == .orderedDescending
        }
    }
}
