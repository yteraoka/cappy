import Foundation
import Testing
@testable import CappyKit

/// 決まった答えを順に返す入出力
private final class ScriptedIO: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String]
    private var _output = ""
    var output: String { lock.withLock { _output } }

    init(_ answers: [String]) { self.answers = answers }

    var io: SetupIO {
        SetupIO(readLine: { [self] in lock.withLock { answers.isEmpty ? nil : answers.removeFirst() } },
                write: { [self] text in lock.withLock { _output += text } })
    }

    var remaining: Int { lock.withLock { answers.count } }
}

@Suite struct SetupWizardTests {
    let path = URL(fileURLWithPath: "/tmp/cappy-test-config.toml")

    private func profile(_ a: SetupAnswers) throws -> Profile {
        let text = SetupConfigFile.merged(existing: nil, answers: a)
        return try CappyConfig.parse(text, path: path).profile(named: a.profileName)
    }

    @Test func geminiFlowWritesALoadableProfile() throws {
        let s = ScriptedIO([
            "",                  // プロファイル名 → default
            "",                  // 文字起こし → google
            "ja-JP",
            "my-proj",
            "gs://Bad Bucket",   // 不正なバケット名 → 聞き直し
            "gs://my-bucket/",   // gs:// と末尾の / は取り除く
            "",                  // モデル → gemini-3.5-transcribe
            "",                  // Gemini のロケーション → global
            "",                  // 要約 → google（文字起こしと同じ）
            "2",                 // モデル → Claude
            "",                  // リージョン → global
            "n",                 // 自動で要約しない
            "~/Rec",
        ])
        let a = try SetupWizard(io: s.io, environment: SetupEnvironment(), existingProfiles: []).run()
        #expect(s.remaining == 0)
        #expect(s.output.contains("Enter a bucket name") || s.output.contains("バケット名を入力してください"))
        let p = try profile(a)
        #expect(p.name == "default")
        #expect(p.provider == "google")
        #expect(p.transcriptionService == .gemini)
        #expect(p.transcribeModel == "gemini-3.5-transcribe")
        #expect(p.language == "ja-JP")
        #expect(p.outputDir == "~/Rec")
        #expect(p.google.projectID == "my-proj")
        #expect(p.google.bucket == "my-bucket")
        #expect(p.gemini.location == "global")
        #expect(p.summaryProvider == "google")
        #expect(p.summary.model == SummarySettings.defaultBedrockModel)
        #expect(p.summary.region == "global")
        #expect(p.summary.auto == false)
        #expect(p.aws == nil)
    }

    @Test func speechToTextFlowUsesItsOwnLocation() throws {
        let s = ScriptedIO(["stt", "", "ja-JP", "proj", "bucket-1", "2", "eu", "3", ""])
        let a = try SetupWizard(io: s.io, environment: SetupEnvironment(), existingProfiles: []).run()
        #expect(s.remaining == 0)
        let p = try profile(a)
        #expect(p.transcriptionService == .speech)
        #expect(p.google.model == "chirp_3")
        #expect(p.google.location == "eu")
        #expect(p.gemini.location == "global")
        #expect(p.summaryProvider == "none")
    }

    @Test func awsFlowUsesProfileRegionAndBedrockScope() throws {
        let env = SetupEnvironment(awsProfiles: [.init(name: "default", region: "us-west-2"),
                                                 .init(name: "work", region: "ap-northeast-1", usesSSO: true)])
        let s = ScriptedIO([
            "aws",
            "2",                 // aws
            "en-US",
            "nope",              // ~/.aws/config にないプロファイル → 聞き直し
            "work",
            "",                  // リージョン → work の ap-northeast-1
            "s3://cappy-audio",
            "",                  // 要約 → aws（文字起こしと同じ）
            "",                  // モデル → claude-opus-5-5
            "",                  // 範囲 → jp（ap-northeast-1 から）
            "",                  // 自動で要約 → yes
            "",                  // 保存先 → 既定
        ])
        let a = try SetupWizard(io: s.io, environment: env, existingProfiles: []).run()
        #expect(s.remaining == 0)
        let p = try profile(a)
        #expect(p.provider == "aws")
        #expect(p.transcriptionService == .amazon)
        #expect(p.aws == AWSSettings(profile: "work", region: "ap-northeast-1", bucket: "cappy-audio"))
        #expect(p.summaryProvider == "aws")
        #expect(p.summary.model == "claude-opus-5-5")
        #expect(p.summary.region == "jp")
        #expect(p.summary.auto == true)
        #expect(p.outputDir == "~/Recordings/cappy")
        #expect(p.google.projectID == nil)
        #expect(!SetupConfigFile.render(a).contains("model = \"gemini"))
    }

    @Test func noneSkipsServiceAndSummaryQuestions() throws {
        let s = ScriptedIO(["local", "3", "ja-JP", ""])
        let a = try SetupWizard(io: s.io, environment: SetupEnvironment(), existingProfiles: []).run()
        #expect(s.remaining == 0)
        let text = SetupConfigFile.render(a)
        #expect(!text.contains("summary"))
        let p = try profile(a)
        #expect(p.provider == "none")
        #expect(p.summaryProvider == "none")
    }

    @Test func googleTranscriptionWithAWSSummaryAsksForAWSWithoutBucket() throws {
        let s = ScriptedIO(["", "", "ja-JP", "proj", "bucket-1", "", "", "2", "", "ap-northeast-1", "", "", "n", ""])
        let env = SetupEnvironment(gcloudProject: "ignored")
        let a = try SetupWizard(io: s.io, environment: env, existingProfiles: []).run()
        #expect(s.remaining == 0)
        let p = try profile(a)
        #expect(p.provider == "google")
        #expect(p.summaryProvider == "aws")
        #expect(p.aws?.region == "ap-northeast-1")
        #expect(p.aws?.bucket == nil)
        #expect(s.output.contains("aws configure sso"))
    }

    @Test func detectedGcloudProjectIsTheDefault() throws {
        let s = ScriptedIO(["", "", "ja-JP", "", "b-123", "", "", "3", ""])
        let a = try SetupWizard(io: s.io, environment: SetupEnvironment(gcloudProject: "from-gcloud"), existingProfiles: []).run()
        #expect(a.googleProjectID == "from-gcloud")
        #expect(a.summaryProvider == "none")
        #expect(try profile(a).summaryProvider == "none")
    }

    @Test func existingProfileNeedsConfirmation() throws {
        // default はある → 置き換えない → 新しい名前（空は不可）
        let s = ScriptedIO(["", "n", "", "second", "3", "ja-JP", ""])
        let a = try SetupWizard(io: s.io, environment: SetupEnvironment(), existingProfiles: ["default"]).run()
        #expect(a.profileName == "second")
        #expect(s.remaining == 0)
    }

    @Test func endOfInputCancels() {
        let s = ScriptedIO(["", ""])
        #expect(throws: SetupWizard.Cancelled.self) {
            try SetupWizard(io: s.io, environment: SetupEnvironment(), existingProfiles: []).run()
        }
    }

    @Test func mergeReplacesOnlyTheTargetProfile() throws {
        let existing = """
        # my settings
        [profiles.default]
        language = "ja-JP"  # keep

        [profiles.default.google]
        project_id = "old"

        # client profile
        [profiles.client.transcribe]
        provider = "none"

        [profiles."default".summary]
        auto = true
        """
        var a = SetupAnswers()
        a.profileName = "default"
        a.provider = "none"
        a.language = "en-US"
        let text = SetupConfigFile.merged(existing: existing, answers: a)
        #expect(text.contains("# my settings"))
        #expect(text.contains("# client profile"))
        #expect(!text.contains("project_id = \"old\""))
        #expect(!text.contains("auto = true"))
        let c = try CappyConfig.parse(text, path: path)
        #expect(Set(c.profiles.keys) == ["default", "client"])
        #expect(try c.profile(named: "default").language == "en-US")
        #expect(try c.profile(named: "client").provider == "none")
    }

    @Test func newFileHasAHeaderAndQuotesValues() throws {
        var a = SetupAnswers()
        a.provider = "none"
        a.outputDir = "~/My \"Recs\"\\x"
        let text = SetupConfigFile.merged(existing: nil, answers: a)
        #expect(text.hasPrefix("# cappy config (created by `cappy init`"))
        #expect(try CappyConfig.parse(text, path: path).profile(named: "default").outputDir == "~/My \"Recs\"\\x")
    }

    @Test func readsTheActiveGcloudConfiguration() throws {
        let dir = try TestSupport.tempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("configurations"), withIntermediateDirectories: true)
        try "work\n".write(to: dir.appendingPathComponent("active_config"), atomically: true, encoding: .utf8)
        try "[core]\naccount = a@example.com\nproject = work-proj\n".write(to: dir.appendingPathComponent("configurations/config_work"), atomically: true, encoding: .utf8)
        try "[core]\nproject = default-proj\n".write(to: dir.appendingPathComponent("configurations/config_default"), atomically: true, encoding: .utf8)
        #expect(SetupEnvironment.gcloudProject(configDir: dir.path) == "work-proj")
        let env = SetupEnvironment.detect(variables: ["CLOUDSDK_CONFIG": dir.path, "AWS_CONFIG_FILE": dir.appendingPathComponent("none").path],
                                          home: dir.path)
        #expect(env.gcloudProject == "work-proj")
        #expect(SetupEnvironment.detect(variables: ["GOOGLE_CLOUD_PROJECT": "env-proj", "CLOUDSDK_CONFIG": dir.path], home: dir.path).gcloudProject == "env-proj")
    }

    @Test func detectsAWSProfiles() throws {
        let dir = try TestSupport.tempDir()
        let config = dir.appendingPathComponent("config")
        try """
        [default]
        region = us-east-1
        [profile work]
        sso_session = corp
        region = ap-northeast-1
        """.write(to: config, atomically: true, encoding: .utf8)
        let env = SetupEnvironment.detect(variables: ["AWS_CONFIG_FILE": config.path, "AWS_PROFILE": "work"], home: dir.path)
        #expect(env.awsProfiles == [.init(name: "default", region: "us-east-1"), .init(name: "work", region: "ap-northeast-1", usesSSO: true)])
        #expect(env.awsProfileFromEnvironment == "work")
    }

    @Test func bedrockScopeFollowsTheRegion() {
        #expect(SetupWizard.bedrockScope(for: "ap-northeast-1") == "jp")
        #expect(SetupWizard.bedrockScope(for: "us-west-2") == "us")
        #expect(SetupWizard.bedrockScope(for: "eu-central-1") == "eu")
        #expect(SetupWizard.bedrockScope(for: "ap-southeast-2") == "au")
        #expect(SetupWizard.bedrockScope(for: "ap-south-1") == "apac")
        #expect(SetupWizard.bedrockScope(for: "sa-east-1") == "global")
    }
}

@Suite struct TranscribeConfigLayoutTests {
    let path = URL(fileURLWithPath: "/tmp/x.toml")

    private func parse(_ text: String) throws -> Profile {
        try CappyConfig.parse(text, path: path).profile(named: "p")
    }

    @Test func serviceFollowsProviderAndModel() {
        #expect(Profile.transcriptionService(provider: "google", model: nil) == .gemini)
        #expect(Profile.transcriptionService(provider: "google", model: "gemini-3.5-transcribe") == .gemini)
        #expect(Profile.transcriptionService(provider: "google", model: "chirp_3") == .speech)
        #expect(Profile.transcriptionService(provider: "aws", model: nil) == .amazon)
        #expect(Profile.transcriptionService(provider: "none", model: nil) == .none)
        #expect(Profile(name: "x").transcriptionService == .gemini)
    }

    @Test func speechToTextSettings() throws {
        let p = try parse("""
        [profiles.p.google]
        project_id = "proj"
        bucket = "b1"
        delete_remote_after = false

        [profiles.p.transcribe]
        provider = "google"
        model = "chirp_2"
        location = "eu"
        chunk_minutes = 30
        live_model = "live-x"
        diarization = false
        word_timestamps = false
        min_speakers = 2
        max_speakers = 4
        custom_vocabulary = ["cappy"]
        """)
        #expect(p.transcriptionService == .speech)
        #expect(p.google.projectID == "proj" && p.google.bucket == "b1" && !p.google.deleteRemoteAfter)
        #expect(p.google.model == "chirp_2")
        #expect(p.google.location == "eu")
        #expect(p.google.chunkMinutes == 30)
        #expect(p.google.minSpeakers == 2 && p.google.maxSpeakers == 4)
        // model / location / chunk_minutes はそのモデルのサービスだけに当てる
        #expect(p.gemini.model == "gemini-3.5-transcribe")
        #expect(p.gemini.location == "global")
        #expect(p.gemini.chunkMinutes == 14)
        // diarization などは、それを持つすべてのサービスに当てる
        #expect(!p.google.diarization && !p.gemini.diarization && !p.awsTranscribe.diarization)
        #expect(!p.google.wordTimestamps && !p.gemini.wordTimestamps)
        #expect(p.awsTranscribe.maxSpeakers == 4)
        #expect(p.gemini.liveModel == "live-x")
        #expect(p.gemini.customVocabulary == ["cappy"])
    }

    @Test func geminiSettings() throws {
        let p = try parse("""
        [profiles.p.transcribe]
        location = "us"
        chunk_minutes = 10
        """)
        #expect(p.provider == "google")
        #expect(p.transcriptionService == .gemini)
        #expect(p.gemini.location == "us")
        #expect(p.gemini.chunkSeconds == 600)
        #expect(p.google.location == "us")
        #expect(p.google.chunkMinutes == nil)
        #expect(throws: CappyError.self) { try parse("[profiles.p.transcribe]\nchunk_minutes = 20\n") }
    }

    @Test func amazonTranscribeSettings() throws {
        let p = try parse("""
        [profiles.p.aws]
        region = "ap-northeast-1"
        bucket = "b2"

        [profiles.p.transcribe]
        provider = "aws"
        max_speakers = 5
        vocabulary_name = "terms"
        language_model_name = "lm"
        """)
        #expect(p.transcriptionService == .amazon)
        #expect(p.aws == AWSSettings(profile: nil, region: "ap-northeast-1", bucket: "b2"))
        #expect(p.awsTranscribe.maxSpeakers == 5)
        #expect(p.awsTranscribe.vocabularyName == "terms")
        #expect(p.awsTranscribe.languageModelName == "lm")
        // 要約は省略すると文字起こしと同じクラウド（Bedrock の既定のモデル）
        #expect(p.summaryProvider == "aws")
        #expect(p.summary.model == SummarySettings.defaultBedrockModel)
    }

    @Test func rejectsSettingsThatDoNotApply() {
        #expect(throws: CappyError.self) { try parse("[profiles.p.transcribe]\nprovider = \"aws\"\nmodel = \"chirp_3\"\n") }
        #expect(throws: CappyError.self) { try parse("[profiles.p.transcribe]\nprovider = \"aws\"\nlocation = \"us\"\n") }
        #expect(throws: CappyError.self) { try parse("[profiles.p.transcribe]\nprovider = \"aws\"\nmax_speakers = 31\n") }
        #expect(throws: CappyError.self) { try parse("[profiles.p.summary]\nprovider = \"vertex\"\n") }
        #expect {
            try parse("[profiles.p.transcribe]\nprovider = \"gemini\"\n")
        } throws: { error in
            (error as? CappyError)?.message.contains("google / aws / none") == true
        }
    }
}

@Suite struct ExampleConfigTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// 設定例をそのまま読み込める
    @Test(arguments: ["config.example.toml", "config.example.ja.toml"])
    func examplesLoad(_ file: String) throws {
        let url = Self.root.appendingPathComponent(file)
        let c = try CappyConfig.load(from: url)
        #expect(c.profiles.count == 5)
        #expect(try c.profile(named: "default").transcriptionService == .gemini)
        #expect(try c.profile(named: "default").gemini.location == "global")
        #expect(try c.profile(named: "aws").transcriptionService == .amazon)
        #expect(try c.profile(named: "aws").summaryProvider == "aws")
        #expect(try c.profile(named: "client-a").google.location == "eu")
        #expect(try c.profile(named: "local-only").summaryProvider == "none")
    }
}
