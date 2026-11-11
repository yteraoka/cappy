import ArgumentParser
import CappyKit
import Foundation

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "権限・認証・設定の診断"
    )

    @Flag(name: .customLong("request-permissions"), help: "未確認の権限について許可ダイアログを出す")
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
        add(osOK ? .ok : .fail, "macOS", "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)\(osOK ? "" : "（15 以降が必要）")")
        add(Permissions.hasEmbeddedUsageDescriptions ? .ok : .warn, "Info.plist",
            Permissions.hasEmbeddedUsageDescriptions ? "利用目的の文字列が埋め込まれています" : "埋め込まれていません（swift build で作った場合は Package.swift のリンカ設定を確認）")

        // 権限
        var audio = Permissions.audioCaptureStatus()
        if audio == .notDetermined && requestPermissions { audio = await Permissions.requestAudioCapture() }
        switch audio {
        case .authorized: add(.ok, "システムオーディオ録音", audio.rawValue)
        case .denied: add(.fail, "システムオーディオ録音", "拒否されています\n" + Permissions.audioCaptureHint, .permission)
        case .notDetermined: add(.warn, "システムオーディオ録音", "未確認（初回の録音時、または --request-permissions で許可を求めます）")
        case .unknown: add(.warn, "システムオーディオ録音", "状態を取得できません")
        }
        var mic = Permissions.microphoneStatus()
        if mic == .notDetermined && requestPermissions { mic = await Permissions.requestMicrophone() }
        switch mic {
        case .authorized: add(.ok, "マイク", mic.rawValue)
        case .denied: add(.fail, "マイク", "拒否されています\n" + Permissions.microphoneHint, .permission)
        case .notDetermined: add(.warn, "マイク", "未確認（初回の録音時、または --request-permissions で許可を求めます）")
        case .unknown: add(.warn, "マイク", "状態を取得できません")
        }

        // デバイス
        if let out = try? AudioDevices.defaultOutputDevice(), let info = try? AudioDevices.info(for: out) {
            add(.ok, "既定の出力", "\(info.name)（\(Int(info.sampleRate)) Hz）")
        } else {
            add(.fail, "既定の出力", "ありません", .io)
        }
        if let inp = try? AudioDevices.defaultInputDevice(), let info = try? AudioDevices.info(for: inp) {
            add(.ok, "既定の入力", "\(info.name)（\(Int(info.sampleRate)) Hz）")
        } else {
            add(.warn, "既定の入力", "ありません（--no-mic で録音できます）")
        }

        // 設定
        let config: CappyConfig
        do {
            config = try CappyConfig.load()
            add(config.fileExists ? .ok : .warn, "設定ファイル",
                config.fileExists ? config.path.path : "\(config.path.path) がありません（既定値を使います）")
        } catch let e as CappyError {
            add(.fail, "設定ファイル", e.message)
            finish(checks)
            return
        }
        let profile: Profile
        do {
            profile = try config.profile(named: common.profile)
            add(.ok, "プロファイル", "\(profile.name)（provider=\(profile.provider), summary=\(profile.summaryProvider), language=\(profile.language)）")
        } catch let e as CappyError {
            add(.fail, "プロファイル", e.message)
            finish(checks)
            return
        }
        let outDir = profile.outputDirectoryURL
        if let free = FileSecurity.availableBytes(at: FileManager.default.fileExists(atPath: outDir.path) ? outDir : outDir.deletingLastPathComponent()) {
            add(free > Int64(profile.diskWarnMB) << 20 ? .ok : .warn, "保存先", "\(outDir.path)（空き \(free >> 30) GB）")
        } else {
            add(.ok, "保存先", outDir.path)
        }

        if profile.provider == "gemini" {
            await checkGemini(profile, add)
        } else if profile.provider == "google" {
            await checkGoogle(profile, add)
        } else {
            add(.ok, "文字起こし", "provider = none（録音のみ）")
        }
        await checkAWS(profile, add)
        await checkSummary(profile, add)
        finish(checks)
    }

    /// [profiles.<name>.aws] があるとき、認証情報を取得して STS の GetCallerIdentity で確かめる
    func checkAWS(_ profile: Profile, _ add: (Level, String, String, ExitStatus) -> Void) async {
        guard profile.aws != nil || profile.summaryProvider == "bedrock" else { return }
        let settings = profile.aws ?? AWSSettings()
        let provider: AWSCredentialsProvider
        do {
            provider = try AWSCredentialsProvider.resolve(profile: settings.profile, region: settings.region)
        } catch let e as CappyError {
            add(.fail, "AWS 認証", e.message + (e.hint.map { "\n" + $0 } ?? ""), .usage)
            return
        } catch {
            add(.fail, "AWS 認証", "\(error)", .usage)
            return
        }
        let region: String
        if let r = provider.region {
            region = r
            add(.ok, "AWS リージョン", r, .usage)
        } else {
            region = "us-east-1"
            add(.warn, "AWS リージョン",
                "未設定です（[profiles.\(profile.name).aws] の region、AWS_REGION、AWS のプロファイルの region のいずれかで指定）。確認には us-east-1 を使います",
                .usage)
        }
        do {
            let creds = try await provider.credentials()
            let identity = try await STSClient(credentials: provider, region: region).getCallerIdentity()
            var detail = "\(provider.summary)\n   \(identity.arn)"
            if let exp = creds.expiration {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH:mm"
                detail += "（認証情報の期限 \(f.string(from: exp))）"
            }
            add(.ok, "AWS 認証", detail, .transcription)
        } catch let e as CappyError {
            add(.fail, "AWS 認証", "\(provider.summary): \(e.message)" + (e.hint.map { "\n" + $0 } ?? ""), .transcription)
        } catch {
            add(.fail, "AWS 認証", "\(provider.summary): \(error)", .transcription)
        }
    }

    func checkSummary(_ profile: Profile, _ add: (Level, String, String, ExitStatus) -> Void) async {
        let s = profile.summary
        if profile.summaryProvider == "bedrock" {
            await checkBedrockSummary(profile, add)
            return
        }
        guard profile.summaryProvider == "vertex" else {
            add(.ok, "要約", "provider = none（要約しない）", .usage)
            return
        }
        guard let project = profile.summaryProjectID, !project.isEmpty else {
            add(.fail, "要約の設定", "project_id がありません（[profiles.\(profile.name).google] か [profiles.\(profile.name).summary] に設定）", .usage)
            return
        }
        add(.ok, "要約の設定", "Vertex AI project=\(project) region=\(s.region) model=\(s.model) effort=\(s.effort)"
            + (s.effectiveFallback(for: s.model).map { " fallback=\($0)" } ?? "") + (s.auto ? " auto" : ""), .usage)
        checkInstructions(profile, add)
        let family = SummaryModelFamily.of(s.model)
        let title = family == .gemini ? "要約（Gemini）" : "要約（Claude）"
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
            add(.ok, title, "\(s.model)（\(s.region)）にアクセスできます", .transcription)
        } catch let e as GoogleAPIError where e.httpStatus == 403 {
            add(.fail, title, "権限がありません: \(e.message)\nVertex AI API の有効化と roles/aiplatform.user の付与を確認してください", .transcription)
        } catch let e as GoogleAPIError where e.httpStatus == 404 {
            let hint = family == .gemini ? "モデル ID と summary.region を確認してください" : "Model Garden で Claude を有効にしているか確認してください"
            add(.fail, title, "\(s.model) が \(s.region) で使えません: \(e.message)\n\(hint)", .transcription)
        } catch {
            add(.warn, title, "確認できません: \(error)", .transcription)
        }
    }

    func checkInstructions(_ profile: Profile, _ add: (Level, String, String, ExitStatus) -> Void) {
        guard profile.summary.instructionsFile != nil else { return }
        do {
            _ = try SummaryClientFactory.instructions(profile: profile)
        } catch let e as CappyError {
            add(.fail, "要約の追加指示", e.message, .usage)
        } catch {}
    }

    /// Bedrock の Claude。課金されないリクエストで、要約のモデルと再試行先のモデルを使えるか確かめる
    func checkBedrockSummary(_ profile: Profile, _ add: (Level, String, String, ExitStatus) -> Void) async {
        let s = profile.summary
        let title = "要約（Bedrock）"
        let client: BedrockClaudeClient
        do {
            guard let c = try SummaryClientFactory.make(profile: profile) as? BedrockClaudeClient else { return }
            client = c
        } catch let e as CappyError {
            add(.fail, title, e.message + (e.hint.map { "\n" + $0 } ?? ""), e.status)
            return
        } catch {
            add(.fail, title, "\(error)", .transcription)
            return
        }
        let fallback = s.effectiveFallback(for: s.model)
        add(.ok, "要約の設定", "Amazon Bedrock region=\(client.endpointRegion) routing=\(s.region) model=\(s.model) effort=\(s.effort)"
            + (fallback.map { " fallback=\($0)" } ?? "") + (s.auto ? " auto" : ""), .usage)
        checkInstructions(profile, add)
        for (model, isFallback) in [(s.model, false)] + (fallback.map { [($0, true)] } ?? []) {
            let id = BedrockClaudeClient.modelID(model, routing: s.region)
            let label = isFallback ? "要約の再試行先（Bedrock）" : title
            do {
                try await client.checkAccess(model: model, effort: s.effort)
                add(.ok, label, "\(id)（\(client.endpointRegion)）にアクセスできます", .transcription)
            } catch let e as AWSAPIError {
                let hint = Summarizer.bedrockHint(e, model: model, routing: s.region).map { "\n" + $0 } ?? ""
                // 再試行先は拒否されたときだけ使うので警告にとどめる
                add(isFallback ? .warn : .fail, label, "\(id): \(e.message)" + hint, .transcription)
            } catch let e as CappyError {
                add(.fail, label, e.message + (e.hint.map { "\n" + $0 } ?? ""), .transcription)
                return
            } catch {
                add(.warn, label, "確認できません: \(error)", .transcription)
            }
        }
    }

    func checkGoogle(_ profile: Profile, _ add: (Level, String, String, ExitStatus) -> Void) async {
        let g = profile.google
        guard g.projectID != nil, g.bucket != nil else {
            add(.fail, "Google 設定", "project_id と bucket を [profiles.\(profile.name).google] に設定してください", .usage)
            return
        }
        add(.ok, "Google 設定", "project=\(g.projectID!) location=\(g.location) model=\(g.model) bucket=\(g.bucket!)", .usage)
        if g.wordTimestamps && g.effectiveChunkSeconds > 20 * 60 {
            add(.warn, "分割長", "単語タイムスタンプ有効時、chirp_3 の BatchRecognize は 1 ファイル約 20 分までです（chunk_minutes を 19 以下に）", .usage)
        }
        let auth: ApplicationDefaultCredentials
        do {
            auth = try ApplicationDefaultCredentials.load()
        } catch let e as CappyError {
            add(.fail, "Google 認証", e.message + (e.hint.map { "\n" + $0 } ?? ""), .transcription)
            return
        } catch {
            add(.fail, "Google 認証", "\(error)", .transcription)
            return
        }
        do {
            _ = try await auth.accessToken()
            add(.ok, "Google 認証", await auth.summary, .transcription)
        } catch {
            add(.fail, "Google 認証", "\(error)", .transcription)
            return
        }
        guard let provider = try? GoogleSpeechProvider(settings: g, auth: auth) else { return }
        do {
            try await provider.checkAPI()
            add(.ok, "Speech-to-Text API", "projects/\(g.projectID!)/locations/\(g.location) にアクセスできます", .transcription)
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
            add(.fail, "Google 認証", e.message + (e.hint.map { "\n" + $0 } ?? ""), .transcription)
            return nil
        } catch {
            add(.fail, "Google 認証", "\(error)", .transcription)
            return nil
        }
        do {
            _ = try await auth.accessToken()
            add(.ok, "Google 認証", await auth.summary, .transcription)
            return auth
        } catch {
            add(.fail, "Google 認証", "\(error)", .transcription)
            return nil
        }
    }

    func checkGemini(_ profile: Profile, _ add: (Level, String, String, ExitStatus) -> Void) async {
        let g = profile.gemini
        guard let project = profile.geminiProjectID, let bucket = profile.google.bucket else {
            add(.fail, "Gemini 設定", "project_id と bucket を [profiles.\(profile.name).google] に設定してください", .usage)
            return
        }
        add(.ok, "Gemini 設定", "project=\(project) location=\(g.location) model=\(g.model) live_model=\(g.liveModel) "
            + "bucket=\(bucket) chunk=\(g.chunkMinutes) 分", .usage)
        guard let auth = await loadAuth(add) else { return }
        guard let provider = try? GeminiTranscribeProvider(settings: g, projectID: project, bucket: bucket, auth: auth) else { return }
        for (title, model) in [("文字起こしモデル", g.model), ("リアルタイム用モデル", g.liveModel)] {
            var s = g
            s.model = model
            guard let p = try? GeminiTranscribeProvider(settings: s, projectID: project, bucket: bucket, auth: auth) else { continue }
            do {
                try await p.checkModel()
                add(.ok, title, "\(model)（\(g.location)）", .transcription)
            } catch let e as GoogleAPIError where e.httpStatus == 404 {
                add(.fail, title, "\(model) が \(g.location) で見つかりません: \(e.message)", .transcription)
            } catch let e as GoogleAPIError where e.httpStatus == 403 {
                add(.fail, title, "権限がありません: \(e.message)\nVertex AI API の有効化と roles/aiplatform.user の付与を確認してください", .transcription)
            } catch {
                add(.warn, title, "確認できません: \(error)", .transcription)
            }
        }
        await checkBucket(bucket, storage: provider.storage, add)
    }

    func checkBucket(_ bucket: String, storage: GCSClient, _ add: (Level, String, String, ExitStatus) -> Void) async {
        let need = ["storage.objects.create", "storage.objects.get", "storage.objects.delete", "storage.objects.list"]
        do {
            let granted = try await storage.testPermissions(bucket: bucket, permissions: need)
            let missing = need.filter { !granted.contains($0) }
            add(missing.isEmpty ? .ok : .fail, "バケットの権限",
                missing.isEmpty ? "書き込み・読み取り・削除できます" : "不足: \(missing.joined(separator: ", "))", .transcription)
        } catch {
            add(.fail, "バケットの権限", "\(error)", .transcription)
        }
        do {
            let info = try await storage.bucketInfo(bucket)
            add(info.uniformAccess ? .ok : .warn, "バケットのアクセス制御",
                info.uniformAccess ? "均一なアクセス制御が有効です" : "均一なアクセス制御が無効です（有効化を推奨）", .transcription)
            if let age = info.deleteAgeDays, age <= 1 {
                add(.ok, "ライフサイクル", "\(age) 日後に自動削除されます", .transcription)
            } else {
                add(.warn, "ライフサイクル",
                    info.deleteAgeDays.map { "自動削除が \($0) 日後です（1 日を推奨）" } ?? "自動削除ルールがありません（1 日後に削除するルールを推奨）", .transcription)
            }
            if let loc = info.location {
                add(.ok, "バケットの場所", loc, .transcription)
            }
        } catch let e as GoogleAPIError where e.httpStatus == 404 {
            add(.fail, "バケット", "\(bucket) が見つかりません", .transcription)
        } catch {
            add(.warn, "バケットの設定", "確認できません（storage.buckets.get 権限が必要）: \(error)", .transcription)
        }
    }

    func finish(_ checks: [Check]) {
        let failures = checks.filter { $0.level == .fail }
        if failures.isEmpty {
            print("\n問題は見つかりませんでした")
            return
        }
        print("\n\(failures.count) 件の問題があります")
        // 権限 → 設定 → その他の順で終了コードを決める
        if failures.contains(where: { $0.category == .permission }) { Foundation.exit(ExitStatus.permission.rawValue) }
        if failures.contains(where: { $0.category == .usage }) { Foundation.exit(ExitStatus.usage.rawValue) }
        Foundation.exit(failures[0].category.rawValue)
    }
}
