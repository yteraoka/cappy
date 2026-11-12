import ArgumentParser
import CappyKit
import Foundation

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("Check permissions, authentication and settings", ja: "権限・認証・設定の診断")
    )

    @Flag(name: .customLong("request-permissions"), help: ArgumentHelp(tr("Show permission prompts for permissions that have not been decided yet", ja: "未確認の権限について許可ダイアログを出す")))
    var requestPermissions = false

    @OptionGroup var common: CommonOptions

    enum Level { case ok, warn, fail }

    struct Check {
        var level: Level
        var title: String
        var detail: String
        var category: ExitStatus
    }

    func run() async throws {
        var checks: [Check] = []
        func add(_ level: Level, _ title: String, _ detail: String, _ category: ExitStatus = .usage) {
            checks.append(Check(level: level, title: title, detail: detail, category: category))
            let mark: String
            switch level {
            case .ok: mark = "✅"
            case .warn: mark = "⚠️ "
            case .fail: mark = "❌"
            }
            print("\(mark) \(title): \(detail)")
        }

        // OS
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osOK = v.majorVersion >= 15
        add(osOK ? .ok : .fail, "macOS", "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)\(osOK ? "" : tr(" (15 or later is required)", ja: "（15 以降が必要）"))")
        add(Permissions.hasEmbeddedUsageDescriptions ? .ok : .warn, "Info.plist",
            Permissions.hasEmbeddedUsageDescriptions ? tr("Usage description strings are embedded", ja: "利用目的の文字列が埋め込まれています") : tr("Not embedded (if built with swift build, check the linker settings in Package.swift)", ja: "埋め込まれていません（swift build で作った場合は Package.swift のリンカ設定を確認）"))

        // 権限
        var audio = Permissions.audioCaptureStatus()
        if audio == .notDetermined && requestPermissions { audio = await Permissions.requestAudioCapture() }
        switch audio {
        case .authorized: add(.ok, tr("System audio recording", ja: "システムオーディオ録音"), audio.displayName)
        case .denied: add(.fail, tr("System audio recording", ja: "システムオーディオ録音"), tr("Denied\n", ja: "拒否されています\n") + Permissions.audioCaptureHint, .permission)
        case .notDetermined: add(.warn, tr("System audio recording", ja: "システムオーディオ録音"), tr("Not decided yet (permission is requested on the first recording, or with --request-permissions)", ja: "未確認（初回の録音時、または --request-permissions で許可を求めます）"))
        case .unknown: add(.warn, tr("System audio recording", ja: "システムオーディオ録音"), tr("Cannot get the status", ja: "状態を取得できません"))
        }
        var mic = Permissions.microphoneStatus()
        if mic == .notDetermined && requestPermissions { mic = await Permissions.requestMicrophone() }
        switch mic {
        case .authorized: add(.ok, tr("Microphone", ja: "マイク"), mic.displayName)
        case .denied: add(.fail, tr("Microphone", ja: "マイク"), tr("Denied\n", ja: "拒否されています\n") + Permissions.microphoneHint, .permission)
        case .notDetermined: add(.warn, tr("Microphone", ja: "マイク"), tr("Not decided yet (permission is requested on the first recording, or with --request-permissions)", ja: "未確認（初回の録音時、または --request-permissions で許可を求めます）"))
        case .unknown: add(.warn, tr("Microphone", ja: "マイク"), tr("Cannot get the status", ja: "状態を取得できません"))
        }

        // デバイス
        if let out = try? AudioDevices.defaultOutputDevice(), let info = try? AudioDevices.info(for: out) {
            add(.ok, tr("Default output", ja: "既定の出力"), tr("\(info.name) (\(Int(info.sampleRate)) Hz)", ja: "\(info.name)（\(Int(info.sampleRate)) Hz）"))
        } else {
            add(.fail, tr("Default output", ja: "既定の出力"), tr("None", ja: "ありません"), .io)
        }
        if let inp = try? AudioDevices.defaultInputDevice(), let info = try? AudioDevices.info(for: inp) {
            add(.ok, tr("Default input", ja: "既定の入力"), tr("\(info.name) (\(Int(info.sampleRate)) Hz)", ja: "\(info.name)（\(Int(info.sampleRate)) Hz）"))
        } else {
            add(.warn, tr("Default input", ja: "既定の入力"), tr("None (you can record with --no-mic)", ja: "ありません（--no-mic で録音できます）"))
        }

        // 設定
        let config: CappyConfig
        do {
            config = try CappyConfig.load()
            add(config.fileExists ? .ok : .warn, tr("Config file", ja: "設定ファイル"),
                config.fileExists ? config.path.path : tr("\(config.path.path) does not exist (using defaults). Create it with `cappy init`", ja: "\(config.path.path) がありません（既定値を使います）。`cappy init` で作成できます"))
        } catch let e as CappyError {
            add(.fail, tr("Config file", ja: "設定ファイル"), e.message)
            finish(checks)
            return
        }
        let profile: Profile
        do {
            profile = try config.profile(named: common.profile)
            add(.ok, tr("Profile", ja: "プロファイル"), tr("\(profile.name) (transcribe=\(profile.provider) (\(profile.transcriptionService.displayName)), summary=\(profile.summaryProvider), language=\(profile.language))", ja: "\(profile.name)（transcribe=\(profile.provider)（\(profile.transcriptionService.displayName)）, summary=\(profile.summaryProvider), language=\(profile.language)）"))
        } catch let e as CappyError {
            add(.fail, tr("Profile", ja: "プロファイル"), e.message)
            finish(checks)
            return
        }
        let outDir = profile.outputDirectoryURL
        if let free = FileSecurity.availableBytes(at: FileManager.default.fileExists(atPath: outDir.path) ? outDir : outDir.deletingLastPathComponent()) {
            add(free > Int64(profile.diskWarnMB) << 20 ? .ok : .warn, tr("Output directory", ja: "保存先"), tr("\(outDir.path) (\(free >> 30) GB free)", ja: "\(outDir.path)（空き \(free >> 30) GB）"))
        } else {
            add(.ok, tr("Output directory", ja: "保存先"), outDir.path)
        }

        await checkAWS(profile, add)
        switch profile.transcriptionService {
        case .gemini: await checkGemini(profile, add)
        case .speech: await checkGoogle(profile, add)
        case .amazon: await checkTranscribe(profile, add)
        case .none: add(.ok, tr("Transcription", ja: "文字起こし"), tr("provider = none (recording only)", ja: "provider = none（録音のみ）"))
        }
        await checkSummary(profile, add)
        finish(checks)
    }

    /// [profiles.<name>.aws] があるとき、認証情報を取得して STS の GetCallerIdentity で確かめる
    func checkAWS(_ profile: Profile, _ add: (Level, String, String, ExitStatus) -> Void) async {
        guard profile.aws != nil || profile.summaryProvider == "aws" || profile.provider == "aws" else { return }
        let settings = profile.aws ?? AWSSettings()
        let provider: AWSCredentialsProvider
        do {
            provider = try AWSCredentialsProvider.resolve(profile: settings.profile, region: settings.region)
        } catch let e as CappyError {
            add(.fail, tr("AWS authentication", ja: "AWS 認証"), e.message + (e.hint.map { "\n" + $0 } ?? ""), .usage)
            return
        } catch {
            add(.fail, tr("AWS authentication", ja: "AWS 認証"), "\(error)", .usage)
            return
        }
        let region: String
        if let r = provider.region {
            region = r
            add(.ok, tr("AWS region", ja: "AWS リージョン"), r, .usage)
        } else {
            region = "us-east-1"
            add(.warn, tr("AWS region", ja: "AWS リージョン"),
                tr("Not set (set region in [profiles.\(profile.name).aws], AWS_REGION, or region in the AWS profile). Using us-east-1 for this check", ja: "未設定です（[profiles.\(profile.name).aws] の region、AWS_REGION、AWS のプロファイルの region のいずれかで指定）。確認には us-east-1 を使います"),
                .usage)
        }
        do {
            let creds = try await provider.credentials()
            let identity = try await STSClient(credentials: provider, region: region).getCallerIdentity()
            var detail = "\(provider.summary)\n   \(identity.arn)"
            if let exp = creds.expiration {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH:mm"
                detail += tr(" (credentials expire at \(f.string(from: exp)))", ja: "（認証情報の期限 \(f.string(from: exp))）")
            }
            add(.ok, tr("AWS authentication", ja: "AWS 認証"), detail, .transcription)
        } catch let e as CappyError {
            add(.fail, tr("AWS authentication", ja: "AWS 認証"), "\(provider.summary): \(e.message)" + (e.hint.map { "\n" + $0 } ?? ""), .transcription)
        } catch {
            add(.fail, tr("AWS authentication", ja: "AWS 認証"), "\(provider.summary): \(error)", .transcription)
        }
    }

    func checkSummary(_ profile: Profile, _ add: (Level, String, String, ExitStatus) -> Void) async {
        let s = profile.summary
        if profile.summaryProvider == "aws" {
            await checkBedrockSummary(profile, add)
            return
        }
        guard profile.summaryProvider == "google" else {
            add(.ok, tr("Summary", ja: "要約"), tr("provider = none (no summary)", ja: "provider = none（要約しない）"), .usage)
            return
        }
        guard let project = profile.summaryProjectID, !project.isEmpty else {
            add(.fail, tr("Summary settings", ja: "要約の設定"), tr("project_id is missing (set it in [profiles.\(profile.name).google] or [profiles.\(profile.name).summary])", ja: "project_id がありません（[profiles.\(profile.name).google] か [profiles.\(profile.name).summary] に設定）"), .usage)
            return
        }
        add(.ok, tr("Summary settings", ja: "要約の設定"), "Vertex AI project=\(project) region=\(s.region) model=\(s.model) effort=\(s.effort)"
            + (s.effectiveFallback(for: s.model).map { " fallback=\($0)" } ?? "") + (s.auto ? " auto" : ""), .usage)
        checkInstructions(profile, add)
        let family = SummaryModelFamily.of(s.model)
        let title = family == .gemini ? tr("Summary (Gemini)", ja: "要約（Gemini）") : tr("Summary (Claude)", ja: "要約（Claude）")
        let client: SummaryModelClient
        do {
            client = try SummaryClientFactory.make(profile: profile)
        } catch let e as CappyError {
            add(.fail, title, e.message + (e.hint.map { "\n" + $0 } ?? ""), .transcription)
            return
        } catch {
            add(.fail, title, "\(error)", .transcription)
            return
        }
        // トークン数の確認は課金されないので、アクセス確認に使う
        do {
            try await client.checkAccess(model: s.model, effort: s.effort)
            add(.ok, title, tr("\(s.model) (\(s.region)) is accessible", ja: "\(s.model)（\(s.region)）にアクセスできます"), .transcription)
        } catch let e as GoogleAPIError where e.httpStatus == 403 {
            add(.fail, title, tr("Permission denied: \(e.message)\nCheck that the Vertex AI API is enabled and roles/aiplatform.user is granted", ja: "権限がありません: \(e.message)\nVertex AI API の有効化と roles/aiplatform.user の付与を確認してください"), .transcription)
        } catch let e as GoogleAPIError where e.httpStatus == 404 {
            let hint = family == .gemini ? tr("Check the model ID and summary.region", ja: "モデル ID と summary.region を確認してください") : tr("Check that Claude is enabled in Model Garden", ja: "Model Garden で Claude を有効にしているか確認してください")
            add(.fail, title, tr("\(s.model) is not available in \(s.region): \(e.message)\n\(hint)", ja: "\(s.model) が \(s.region) で使えません: \(e.message)\n\(hint)"), .transcription)
        } catch {
            add(.warn, title, tr("Cannot check: \(error)", ja: "確認できません: \(error)"), .transcription)
        }
    }

    /// Amazon Transcribe: API・カスタム語彙・S3 バケット（リージョン・書き込み・削除・ライフサイクル）
    func checkTranscribe(_ profile: Profile, _ add: (Level, String, String, ExitStatus) -> Void) async {
        let title = "Amazon Transcribe"
        let provider: AmazonTranscribeProvider
        do {
            guard let p = try ProviderFactory.make(service: .amazon, profile: profile) as? AmazonTranscribeProvider else { return }
            provider = p
        } catch let e as CappyError {
            add(.fail, title, e.message + (e.hint.map { "\n" + $0 } ?? ""), e.status)
            return
        } catch {
            add(.fail, title, "\(error)", .transcription)
            return
        }
        let t = profile.awsTranscribe
        add(.ok, tr("Transcribe settings", ja: "Transcribe 設定"), "region=\(provider.region) bucket=\(provider.bucketName) language=\(profile.language)"
            + (t.diarization ? " diarization(max \(t.maxSpeakers))" : "")
            + (t.vocabularyName.map { " vocabulary=\($0)" } ?? "") + (t.languageModelName.map { " language_model=\($0)" } ?? ""), .usage)
        do {
            try await provider.checkAPI()
            add(.ok, title, tr("The API in \(provider.region) is accessible", ja: "\(provider.region) の API にアクセスできます"), .transcription)
        } catch let e as AWSAPIError {
            add(.fail, title, "\(e)" + (e.httpStatus == 400 || e.httpStatus == 403
                ? tr("\nAllow transcribe:StartTranscriptionJob / GetTranscriptionJob / DeleteTranscriptionJob / ListTranscriptionJobs in IAM", ja: "\nIAM で transcribe:StartTranscriptionJob / GetTranscriptionJob / DeleteTranscriptionJob / ListTranscriptionJobs を許可してください") : ""),
                .transcription)
            return
        } catch let e as CappyError {
            add(.fail, title, e.message + (e.hint.map { "\n" + $0 } ?? ""), .transcription)
            return
        } catch {
            add(.fail, title, "\(error)", .transcription)
            return
        }
        if let name = t.vocabularyName, !name.isEmpty {
            do {
                let v = try await provider.vocabulary(name)
                let ok = v.state == "READY" && v.language.lowercased() == profile.language.lowercased()
                add(ok ? .ok : .fail, tr("Custom vocabulary", ja: "カスタム語彙"), tr("\(name) (\(v.state), \(v.language))", ja: "\(name)（\(v.state)、\(v.language)）")
                    + (ok ? "" : tr("\nA READY vocabulary for \(profile.language) is required", ja: "\nREADY で、言語が \(profile.language) の語彙が必要です")), .transcription)
            } catch {
                add(.fail, tr("Custom vocabulary", ja: "カスタム語彙"), tr("Cannot check \(name): \(error)", ja: "\(name) を確認できません: \(error)"), .transcription)
            }
        }
        await checkS3Bucket(provider, add)
    }

    func checkS3Bucket(_ provider: AmazonTranscribeProvider, _ add: (Level, String, String, ExitStatus) -> Void) async {
        let bucket = provider.bucketName
        let s3 = provider.s3
        do {
            let region = try await s3.bucketRegion(bucket)
            add(region == provider.region ? .ok : .fail, tr("Bucket location", ja: "バケットの場所"),
                region == provider.region ? region : tr("\(region) (the bucket must be in \(provider.region), the same region as Amazon Transcribe)", ja: "\(region)（Amazon Transcribe と同じ \(provider.region) のバケットが必要です）"), .transcription)
        } catch let e as AWSAPIError where e.httpStatus == 404 {
            add(.fail, tr("Bucket", ja: "バケット"), tr("\(bucket) not found", ja: "\(bucket) が見つかりません"), .transcription)
            return
        } catch {
            add(.warn, tr("Bucket location", ja: "バケットの場所"), tr("Cannot check (s3:GetBucketLocation is required): \(error)", ja: "確認できません（s3:GetBucketLocation 権限が必要）: \(error)"), .transcription)
        }
        // 小さなオブジェクトで、書き込み・読み取り・削除を確かめる
        let object = S3ObjectRef(bucket: bucket, key: "cappy/.doctor/\(UUID().uuidString.lowercased()).txt")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cappy-doctor-\(UUID().uuidString).txt")
        do {
            try Data("cappy doctor\n".utf8).write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try await s3.upload(file: tmp, to: object, contentType: "text/plain")
            let readable = try await s3.exists(object)
            try await s3.delete(object)
            add(readable ? .ok : .fail, tr("Bucket permissions", ja: "バケットの権限"),
                readable ? tr("Can write, read and delete", ja: "書き込み・読み取り・削除できます") : tr("Cannot read the written object (s3:GetObject)", ja: "書き込んだオブジェクトを読めません（s3:GetObject）"), .transcription)
        } catch {
            add(.fail, tr("Bucket permissions", ja: "バケットの権限"), tr("\(error)\nCheck s3:PutObject / s3:GetObject / s3:DeleteObject", ja: "\(error)\ns3:PutObject / s3:GetObject / s3:DeleteObject を確認してください"), .transcription)
        }
        do {
            let rules = try await s3.lifecycleRules(bucket)
            let days = rules.filter { $0.enabled && ($0.prefix.isEmpty || "cappy/".hasPrefix($0.prefix)) }
                .compactMap(\.expirationDays).min()
            if let days, days <= 1 {
                add(.ok, tr("Lifecycle", ja: "ライフサイクル"), tr("Objects are deleted automatically after \(days) day(s)", ja: "\(days) 日後に自動削除されます"), .transcription)
            } else {
                add(.warn, tr("Lifecycle", ja: "ライフサイクル"), days.map { tr("Objects are deleted after \($0) days (1 day is recommended)", ja: "自動削除が \($0) 日後です（1 日を推奨）") } ?? tr("No expiration rule (a rule that deletes objects after 1 day is recommended)", ja: "自動削除ルールがありません（1 日後に削除するルールを推奨）"),
                    .transcription)
            }
        } catch {
            add(.warn, tr("Lifecycle", ja: "ライフサイクル"), tr("Cannot check (s3:GetLifecycleConfiguration is required): \(error)", ja: "確認できません（s3:GetLifecycleConfiguration 権限が必要）: \(error)"), .transcription)
        }
    }

    func checkInstructions(_ profile: Profile, _ add: (Level, String, String, ExitStatus) -> Void) {
        guard profile.summary.instructionsFile != nil else { return }
        do {
            _ = try SummaryClientFactory.instructions(profile: profile)
        } catch let e as CappyError {
            add(.fail, tr("Summary instructions", ja: "要約の追加指示"), e.message, .usage)
        } catch {}
    }

    /// Bedrock の Claude。課金されないリクエストで、要約のモデルと再試行先のモデルを使えるか確かめる
    func checkBedrockSummary(_ profile: Profile, _ add: (Level, String, String, ExitStatus) -> Void) async {
        let s = profile.summary
        let title = tr("Summary (Bedrock)", ja: "要約（Bedrock）")
        let client: BedrockSummaryClient
        do {
            guard let c = try SummaryClientFactory.make(profile: profile) as? BedrockSummaryClient else { return }
            client = c
        } catch let e as CappyError {
            add(.fail, title, e.message + (e.hint.map { "\n" + $0 } ?? ""), e.status)
            return
        } catch {
            add(.fail, title, "\(error)", .transcription)
            return
        }
        let fallback = s.effectiveFallback(for: s.model)
        add(.ok, tr("Summary settings", ja: "要約の設定"), "Amazon Bedrock region=\(client.endpointRegion) routing=\(s.region) model=\(s.model) effort=\(s.effort)"
            + (fallback.map { " fallback=\($0)" } ?? "") + (s.auto ? " auto" : ""), .usage)
        checkInstructions(profile, add)
        for (model, isFallback) in [(s.model, false)] + (fallback.map { [($0, true)] } ?? []) {
            let id = BedrockModels.modelID(model, routing: s.region)
            let label = isFallback ? tr("Summary fallback (Bedrock)", ja: "要約の再試行先（Bedrock）") : title
            do {
                try await client.checkAccess(model: model, effort: s.effort)
                add(.ok, label, tr("\(id) (\(client.endpointRegion)) is accessible", ja: "\(id)（\(client.endpointRegion)）にアクセスできます"), .transcription)
            } catch let e as AWSAPIError {
                let hint = Summarizer.bedrockHint(e, model: model, routing: s.region).map { "\n" + $0 } ?? ""
                // 再試行先は拒否されたときだけ使うので警告にとどめる
                add(isFallback ? .warn : .fail, label, "\(id): \(e.message)" + hint, .transcription)
            } catch let e as CappyError {
                add(.fail, label, e.message + (e.hint.map { "\n" + $0 } ?? ""), .transcription)
                return
            } catch {
                add(.warn, label, tr("Cannot check: \(error)", ja: "確認できません: \(error)"), .transcription)
            }
        }
    }

    func checkGoogle(_ profile: Profile, _ add: (Level, String, String, ExitStatus) -> Void) async {
        let g = profile.google
        guard g.projectID != nil, g.bucket != nil else {
            add(.fail, tr("Google settings", ja: "Google 設定"), tr("Set project_id and bucket in [profiles.\(profile.name).google]", ja: "project_id と bucket を [profiles.\(profile.name).google] に設定してください"), .usage)
            return
        }
        add(.ok, tr("Google settings", ja: "Google 設定"), "project=\(g.projectID!) location=\(g.location) model=\(g.model) bucket=\(g.bucket!)", .usage)
        if g.wordTimestamps && g.effectiveChunkSeconds > 20 * 60 {
            add(.warn, tr("Chunk length", ja: "分割長"), tr("With word timestamps, chirp_3 BatchRecognize accepts about 20 minutes per file (set chunk_minutes to 19 or less)", ja: "単語タイムスタンプ有効時、chirp_3 の BatchRecognize は 1 ファイル約 20 分までです（chunk_minutes を 19 以下に）"), .usage)
        }
        let auth: ApplicationDefaultCredentials
        do {
            auth = try ApplicationDefaultCredentials.load()
        } catch let e as CappyError {
            add(.fail, tr("Google authentication", ja: "Google 認証"), e.message + (e.hint.map { "\n" + $0 } ?? ""), .transcription)
            return
        } catch {
            add(.fail, tr("Google authentication", ja: "Google 認証"), "\(error)", .transcription)
            return
        }
        do {
            _ = try await auth.accessToken()
            add(.ok, tr("Google authentication", ja: "Google 認証"), await auth.summary, .transcription)
        } catch {
            add(.fail, tr("Google authentication", ja: "Google 認証"), "\(error)", .transcription)
            return
        }
        guard let provider = try? GoogleSpeechProvider(settings: g, auth: auth) else { return }
        do {
            try await provider.checkAPI()
            add(.ok, "Speech-to-Text API", tr("projects/\(g.projectID!)/locations/\(g.location) is accessible", ja: "projects/\(g.projectID!)/locations/\(g.location) にアクセスできます"), .transcription)
        } catch {
            add(.fail, "Speech-to-Text API", "\(error)", .transcription)
        }
        await checkBucket(g.bucket!, storage: provider.storage, add)
    }

    func loadAuth(_ add: (Level, String, String, ExitStatus) -> Void) async -> ApplicationDefaultCredentials? {
        let auth: ApplicationDefaultCredentials
        do {
            auth = try ApplicationDefaultCredentials.load()
        } catch let e as CappyError {
            add(.fail, tr("Google authentication", ja: "Google 認証"), e.message + (e.hint.map { "\n" + $0 } ?? ""), .transcription)
            return nil
        } catch {
            add(.fail, tr("Google authentication", ja: "Google 認証"), "\(error)", .transcription)
            return nil
        }
        do {
            _ = try await auth.accessToken()
            add(.ok, tr("Google authentication", ja: "Google 認証"), await auth.summary, .transcription)
            return auth
        } catch {
            add(.fail, tr("Google authentication", ja: "Google 認証"), "\(error)", .transcription)
            return nil
        }
    }

    func checkGemini(_ profile: Profile, _ add: (Level, String, String, ExitStatus) -> Void) async {
        let g = profile.gemini
        guard let project = profile.google.projectID, let bucket = profile.google.bucket else {
            add(.fail, tr("Gemini settings", ja: "Gemini 設定"), tr("Set project_id and bucket in [profiles.\(profile.name).google]", ja: "project_id と bucket を [profiles.\(profile.name).google] に設定してください"), .usage)
            return
        }
        add(.ok, tr("Gemini settings", ja: "Gemini 設定"), "project=\(project) location=\(g.location) model=\(g.model) live_model=\(g.liveModel) "
            + tr("bucket=\(bucket) chunk=\(g.chunkMinutes) min", ja: "bucket=\(bucket) chunk=\(g.chunkMinutes) 分"), .usage)
        guard let auth = await loadAuth(add) else { return }
        guard let provider = try? GeminiTranscribeProvider(settings: g, projectID: project, bucket: bucket, auth: auth) else { return }
        for (title, model) in [(tr("Transcription model", ja: "文字起こしモデル"), g.model), (tr("Live model", ja: "リアルタイム用モデル"), g.liveModel)] {
            var s = g
            s.model = model
            guard let p = try? GeminiTranscribeProvider(settings: s, projectID: project, bucket: bucket, auth: auth) else { continue }
            do {
                try await p.checkModel()
                add(.ok, title, tr("\(model) (\(g.location))", ja: "\(model)（\(g.location)）"), .transcription)
            } catch let e as GoogleAPIError where e.httpStatus == 404 {
                add(.fail, title, tr("\(model) not found in \(g.location): \(e.message)", ja: "\(model) が \(g.location) で見つかりません: \(e.message)"), .transcription)
            } catch let e as GoogleAPIError where e.httpStatus == 403 {
                add(.fail, title, tr("Permission denied: \(e.message)\nCheck that the Vertex AI API is enabled and roles/aiplatform.user is granted", ja: "権限がありません: \(e.message)\nVertex AI API の有効化と roles/aiplatform.user の付与を確認してください"), .transcription)
            } catch {
                add(.warn, title, tr("Cannot check: \(error)", ja: "確認できません: \(error)"), .transcription)
            }
        }
        await checkBucket(bucket, storage: provider.storage, add)
    }

    func checkBucket(_ bucket: String, storage: GCSClient, _ add: (Level, String, String, ExitStatus) -> Void) async {
        let need = ["storage.objects.create", "storage.objects.get", "storage.objects.delete", "storage.objects.list"]
        do {
            let granted = try await storage.testPermissions(bucket: bucket, permissions: need)
            let missing = need.filter { !granted.contains($0) }
            add(missing.isEmpty ? .ok : .fail, tr("Bucket permissions", ja: "バケットの権限"),
                missing.isEmpty ? tr("Can write, read and delete", ja: "書き込み・読み取り・削除できます") : tr("Missing: \(missing.joined(separator: ", "))", ja: "不足: \(missing.joined(separator: ", "))"), .transcription)
        } catch {
            add(.fail, tr("Bucket permissions", ja: "バケットの権限"), "\(error)", .transcription)
        }
        do {
            let info = try await storage.bucketInfo(bucket)
            add(info.uniformAccess ? .ok : .warn, tr("Bucket access control", ja: "バケットのアクセス制御"),
                info.uniformAccess ? tr("Uniform bucket-level access is enabled", ja: "均一なアクセス制御が有効です") : tr("Uniform bucket-level access is disabled (enabling it is recommended)", ja: "均一なアクセス制御が無効です（有効化を推奨）"), .transcription)
            if let age = info.deleteAgeDays, age <= 1 {
                add(.ok, tr("Lifecycle", ja: "ライフサイクル"), tr("Objects are deleted automatically after \(age) day(s)", ja: "\(age) 日後に自動削除されます"), .transcription)
            } else {
                add(.warn, tr("Lifecycle", ja: "ライフサイクル"),
                    info.deleteAgeDays.map { tr("Objects are deleted after \($0) days (1 day is recommended)", ja: "自動削除が \($0) 日後です（1 日を推奨）") } ?? tr("No expiration rule (a rule that deletes objects after 1 day is recommended)", ja: "自動削除ルールがありません（1 日後に削除するルールを推奨）"), .transcription)
            }
            if let loc = info.location {
                add(.ok, tr("Bucket location", ja: "バケットの場所"), loc, .transcription)
            }
        } catch let e as GoogleAPIError where e.httpStatus == 404 {
            add(.fail, tr("Bucket", ja: "バケット"), tr("\(bucket) not found", ja: "\(bucket) が見つかりません"), .transcription)
        } catch {
            add(.warn, tr("Bucket settings", ja: "バケットの設定"), tr("Cannot check (storage.buckets.get is required): \(error)", ja: "確認できません（storage.buckets.get 権限が必要）: \(error)"), .transcription)
        }
    }

    func finish(_ checks: [Check]) {
        let failures = checks.filter { $0.level == .fail }
        if failures.isEmpty {
            print(tr("\nNo problems found", ja: "\n問題は見つかりませんでした"))
            return
        }
        print(tr("\n\(failures.count) problem(s) found", ja: "\n\(failures.count) 件の問題があります"))
        // 権限 → 設定 → その他の順で終了コードを決める
        if failures.contains(where: { $0.category == .permission }) { Foundation.exit(ExitStatus.permission.rawValue) }
        if failures.contains(where: { $0.category == .usage }) { Foundation.exit(ExitStatus.usage.rawValue) }
        Foundation.exit(failures[0].category.rawValue)
    }
}
