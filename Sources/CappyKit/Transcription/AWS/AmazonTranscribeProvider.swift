import Foundation

/// Amazon Transcribe（バッチ）の設定（[profiles.<name>.transcribe]）
public struct TranscribeSettings: Sendable, Equatable {
    /// remote トラックで話者分離を行うか
    public var diarization: Bool = true
    /// 話者分離の最大人数（2〜30）
    public var maxSpeakers: Int = 10
    /// 事前に登録したカスタム語彙の名前（文字起こしと同じリージョンにあること）
    public var vocabularyName: String?
    /// 事前に作成したカスタム言語モデルの名前
    public var languageModelName: String?

    public init() {}
}

/// Amazon Transcribe の StartTranscriptionJob（S3 経由）。
/// 1 ファイル 8 時間・2 GB までなので分割しない。結果は Transcribe が管理する場所に置かせ、
/// GetTranscriptionJob が返す署名付き URL（有効期限 15 分）から取得する。
public struct AmazonTranscribeProvider: TranscriptionProvider {
    /// session.json に記録するサービス名（設定の provider = "aws" とは別。既存のセッションとの互換のため変えない）
    public let name = "transcribe"
    public var model: String? { nil }

    public static let maxDurationMs: Int64 = 8 * 3600 * 1000

    public let settings: TranscribeSettings
    public let region: String
    let bucket: String
    let credentials: AWSCredentialsSource
    let transport: HTTPTransport
    let retry: RetryPolicy
    public let s3: S3Client
    /// ジョブ名の末尾（テストでは固定する）
    let makeSuffix: @Sendable () -> String

    public init(settings: TranscribeSettings, region: String, bucket: String?, credentials: AWSCredentialsSource,
                transport: HTTPTransport = URLSessionTransport(), retry: RetryPolicy = RetryPolicy(),
                makeSuffix: @escaping @Sendable () -> String = { String(UUID().uuidString.lowercased().prefix(8)) }) throws {
        guard let bucket, !bucket.isEmpty else {
            throw CappyError.usage(tr("The S3 bucket for the audio is not set", ja: "音声を置く S3 の bucket が設定されていません"),
                                   hint: tr("Set bucket in [profiles.<name>.aws] of ~/.config/cappy/config.toml", ja: "~/.config/cappy/config.toml の [profiles.<name>.aws] に bucket を書いてください"))
        }
        self.settings = settings
        self.region = region
        self.bucket = bucket
        self.credentials = credentials
        self.transport = transport
        self.retry = retry
        self.s3 = S3Client(credentials: credentials, region: region, transport: transport, retry: retry)
        self.makeSuffix = makeSuffix
    }

    public var bucketName: String { bucket }

    func objectKey(_ track: AudioTrack, ext: String) -> String {
        "cappy/\(track.sessionID)/transcribe/\(track.id.rawValue).\(ext)"
    }

    /// ジョブ名（[0-9a-zA-Z._-]、200 文字まで、アカウント・リージョン内で一意）
    func jobName(_ track: AudioTrack) -> String {
        let safe = track.sessionID.replacingOccurrences(of: "[^0-9A-Za-z._-]", with: "-", options: .regularExpression)
        return String("cappy-\(safe)-\(track.id.rawValue)-\(makeSuffix())".prefix(200))
    }

    // MARK: API

    /// Transcribe の JSON 1.1 API を呼ぶ
    func call(_ action: String, _ body: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let url = URL(string: "https://transcribe.\(region).amazonaws.com/")!
        let resp = try await retry.run(action) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
            req.setValue("Transcribe.\(action)", forHTTPHeaderField: "X-Amz-Target")
            req.httpBody = data
            SigV4Signer(credentials: try await credentials.credentials(), region: region, service: "transcribe").sign(&req)
            let r = try await transport.send(req)
            guard r.status == 200 else { throw AWSAPIError.from(r) }
            return r
        }
        // DeleteTranscriptionJob などは本文が空で返る
        guard !resp.body.isEmpty else { return [:] }
        return (try JSONSerialization.jsonObject(with: resp.body) as? [String: Any]) ?? [:]
    }

    // MARK: submit

    public func submit(_ track: AudioTrack, options: TranscriptionOptions) async throws -> JobHandle {
        if let d = track.durationMs, d > Self.maxDurationMs {
            throw CappyError.transcription(tr("The audio is too long (Amazon Transcribe accepts up to 8 hours per file)", ja: "音声が長すぎます（Amazon Transcribe は 1 ファイル 8 時間まで）"))
        }
        let ext = track.url.pathExtension.lowercased()
        let format = ext == "flac" ? "flac" : "wav"
        let object = S3ObjectRef(bucket: bucket, key: objectKey(track, ext: ext))
        CappyLog.shared.info(tr("Upload started \(object.uri)", ja: "アップロード開始 \(object.uri)"))
        do {
            try await s3.upload(file: track.url, to: object, contentType: ext == "flac" ? "audio/flac" : "audio/wav")
        } catch let e as AWSAPIError {
            throw CappyError.transcription(tr("Upload to S3 failed: \(e)", ja: "S3 へのアップロードに失敗しました: \(e)"),
                                           hint: e.httpStatus == 403 ? tr("Check the write permission (s3:PutObject) on bucket \(bucket) (`cappy doctor`)", ja: "バケット \(bucket) への書き込み権限（s3:PutObject）を確認してください（`cappy doctor`）") : nil)
        }
        var diarization = options.diarization
        var note: String?
        var job: String
        do {
            job = try await start(track, object: object, format: format, options: options, diarization: diarization)
        } catch let e as AWSAPIError where diarization && Self.isDiarizationUnsupported(e) {
            note = tr("Disabled speaker diarization because it is not supported: \(e.message)", ja: "話者分離に対応していないため無効にしました: \(e.message)")
            CappyLog.shared.warning("\(track.id.rawValue): \(note!)")
            diarization = false
            job = try await start(track, object: object, format: format, options: options, diarization: false)
        } catch let e as AWSAPIError {
            throw CappyError.transcription(tr("Cannot start the Amazon Transcribe job: \(e)", ja: "Amazon Transcribe のジョブを開始できません: \(e)"), hint: Self.hint(e, settings: settings))
        }
        var info: [String: String] = [
            "object": object.uri,
            "language": options.language,
            "diarization": diarization ? "true" : "false",
            "track_offset_ms": String(track.offsetMs),
            "region": region,
        ]
        if let note { info["diarization_note"] = note }
        return JobHandle(provider: name, track: track.id, id: job, info: info)
    }

    func startBody(_ track: AudioTrack, job: String, object: S3ObjectRef, format: String,
                   options: TranscriptionOptions, diarization: Bool) -> [String: Any] {
        var settingsBody: [String: Any] = [:]
        if diarization {
            settingsBody["ShowSpeakerLabels"] = true
            settingsBody["MaxSpeakerLabels"] = min(30, max(2, options.maxSpeakers ?? settings.maxSpeakers))
        }
        if let v = settings.vocabularyName, !v.isEmpty { settingsBody["VocabularyName"] = v }
        var body: [String: Any] = [
            "TranscriptionJobName": job,
            "LanguageCode": options.language,
            "Media": ["MediaFileUri": object.uri],
            "MediaFormat": format,
        ]
        if !settingsBody.isEmpty { body["Settings"] = settingsBody }
        if let m = settings.languageModelName, !m.isEmpty { body["ModelSettings"] = ["LanguageModelName": m] }
        return body
    }

    func start(_ track: AudioTrack, object: S3ObjectRef, format: String, options: TranscriptionOptions,
               diarization: Bool) async throws -> String {
        let job = jobName(track)
        _ = try await call("StartTranscriptionJob",
                           startBody(track, job: job, object: object, format: format, options: options, diarization: diarization))
        CappyLog.shared.info(tr("Amazon Transcribe job started job=\(job) diarization=\(diarization)", ja: "Amazon Transcribe のジョブを開始しました job=\(job) diarization=\(diarization)"))
        return job
    }

    static func isDiarizationUnsupported(_ e: AWSAPIError) -> Bool {
        guard e.httpStatus == 400 else { return false }
        let m = e.message.lowercased()
        return m.contains("speaker") || m.contains("diariz")
    }

    static func hint(_ e: AWSAPIError, settings: TranscribeSettings) -> String? {
        switch (e.httpStatus, e.code) {
        case (400, "BadRequestException") where e.message.lowercased().contains("vocabulary"):
            return tr("Check that custom vocabulary \(settings.vocabularyName ?? "") is in the same Region and language as the transcription and is READY", ja: "カスタム語彙 \(settings.vocabularyName ?? "") が文字起こしと同じリージョン・言語にあり、READY になっているか確認してください")
        case (403, _), (400, "AccessDeniedException"):
            return tr("Check that IAM allows transcribe:StartTranscriptionJob and others, and s3:GetObject on the audio (`cappy doctor`)", ja: "IAM で transcribe:StartTranscriptionJob などと、音声への s3:GetObject が許可されているか確認してください（`cappy doctor`）")
        case (_, "LimitExceededException"):
            return tr("A limit such as the number of concurrent jobs is exceeded. Run again later", ja: "同時に実行できるジョブ数などの上限を超えています。時間をおいて再実行してください")
        default:
            return nil
        }
    }

    // MARK: status / result / cleanup

    func getJob(_ job: JobHandle) async throws -> [String: Any] {
        let r = try await call("GetTranscriptionJob", ["TranscriptionJobName": job.id])
        guard let j = r["TranscriptionJob"] as? [String: Any] else {
            throw CappyError.transcription(tr("Invalid GetTranscriptionJob response", ja: "GetTranscriptionJob の応答が不正です"))
        }
        return j
    }

    public func status(of job: JobHandle) async throws -> JobStatus {
        let j: [String: Any]
        do {
            j = try await getJob(job)
        } catch let e as AWSAPIError where e.httpStatus == 400 && e.code == "BadRequestException" && e.message.lowercased().contains("couldn't be found") {
            return .failed(tr("Job \(job.id) not found (start over with --force)", ja: "ジョブ \(job.id) が見つかりません（--force でやり直してください）"))
        }
        switch j["TranscriptionJobStatus"] as? String {
        case "COMPLETED": return .done
        case "FAILED": return .failed(j["FailureReason"] as? String ?? tr("unknown error", ja: "不明なエラー"))
        case "QUEUED": return .pending
        default: return .running(progress: nil)
        }
    }

    public func result(of job: JobHandle) async throws -> [Segment] {
        let j = try await getJob(job)
        guard j["TranscriptionJobStatus"] as? String == "COMPLETED" else {
            throw CappyError.transcription(tr("The job has not finished yet: \(job.id)", ja: "ジョブがまだ完了していません: \(job.id)"))
        }
        guard let uri = (j["Transcript"] as? [String: Any])?["TranscriptFileUri"] as? String, let url = URL(string: uri) else {
            throw CappyError.transcription(tr("The result file location of \(job.id) is unknown", ja: "\(job.id) の結果ファイルの場所がわかりません"))
        }
        // Transcribe が管理する場所の署名付き URL（認証ヘッダーは付けない）
        let resp = try await retry.run(tr("Getting the result", ja: "結果の取得")) {
            let r = try await transport.send(URLRequest(url: url))
            if r.status >= 500 || r.status == 429 { throw AWSAPIError.from(r) }
            return r
        }
        guard resp.status == 200 else {
            throw CappyError.transcription(tr("Cannot get the result of \(job.id): \(AWSAPIError.from(resp))", ja: "\(job.id) の結果を取得できません: \(AWSAPIError.from(resp))"))
        }
        let offset = Int64(job.info["track_offset_ms"] ?? "0") ?? 0
        return try AmazonTranscribeResultParser.segments(fromJSON: resp.body, track: job.track, offsetMs: offset,
                                                         language: job.info["language"] ?? "ja-JP")
    }

    /// S3 の音声と、ジョブ（Transcribe が管理する結果も消える）を削除する
    public func cleanup(_ job: JobHandle) async throws {
        if let uri = job.info["object"], let object = S3ObjectRef(uri: uri) {
            try await s3.delete(object)
        }
        do {
            _ = try await call("DeleteTranscriptionJob", ["TranscriptionJobName": job.id])
        } catch let e as AWSAPIError where e.httpStatus == 400 && e.message.lowercased().contains("couldn't be found") {
            // すでに削除済み
        }
        CappyLog.shared.info(tr("Deleted the audio in S3 and the Transcribe job track=\(job.track.rawValue)", ja: "S3 上の音声と Transcribe のジョブを削除しました track=\(job.track.rawValue)"))
    }

    // MARK: doctor

    /// API に到達でき、権限があるかを確かめる（ListTranscriptionJobs）
    public func checkAPI() async throws {
        _ = try await call("ListTranscriptionJobs", ["MaxResults": 1])
    }

    /// カスタム語彙の状態（READY など）と言語
    public func vocabulary(_ name: String) async throws -> (state: String, language: String) {
        let r = try await call("GetVocabulary", ["VocabularyName": name])
        return (r["VocabularyState"] as? String ?? "-", r["LanguageCode"] as? String ?? "-")
    }
}

/// Amazon Transcribe の結果 JSON（results.items）を Segment に変換する
public enum AmazonTranscribeResultParser {
    struct Word {
        var text: String
        var startMs: Int64
        var endMs: Int64
        var speaker: String?
        var confidence: Double?
    }

    public static func segments(fromJSON data: Data, track: TrackID, offsetMs: Int64, language: String) throws -> [Segment] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [String: Any] else {
            throw CappyError.transcription(tr("Invalid Amazon Transcribe result", ja: "Amazon Transcribe の結果が不正です"))
        }
        let items = results["items"] as? [[String: Any]] ?? []
        let speakerAt = speakerTimeline(results)
        let sep = GoogleResultParser.joiner(for: language)

        var words: [Word] = []
        for item in items {
            let alt = (item["alternatives"] as? [[String: Any]])?.first
            let content = (alt?["content"] as? String) ?? ""
            if item["type"] as? String == "punctuation" {
                // 句読点は直前の単語に付ける
                if !words.isEmpty { words[words.count - 1].text += content }
                continue
            }
            guard let start = ms(item["start_time"]), let end = ms(item["end_time"]), !content.isEmpty else { continue }
            let speaker = (item["speaker_label"] as? String) ?? speakerAt(start)
            words.append(Word(text: content, startMs: start, endMs: max(start, end), speaker: speaker,
                              confidence: double(alt?["confidence"])))
        }

        // 話者ごとに区切り、さらに文の終わりや間で分ける
        var out: [Segment] = []
        var run: [Word] = []
        func flushRun() {
            guard !run.isEmpty else { return }
            let speaker = run[0].speaker
            for group in GeminiTranscriptParser.groups(run.map { (startMs: $0.startMs, endMs: $0.endMs, text: $0.text) }) {
                let ws = Array(run[group])
                let text = ws.map(\.text).joined(separator: sep).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let confs = ws.compactMap(\.confidence)
                out.append(Segment(track: track, speaker: speaker, startMs: offsetMs + ws.first!.startMs,
                                   endMs: offsetMs + ws.last!.endMs, text: text,
                                   confidence: confs.isEmpty ? nil : confs.reduce(0, +) / Double(confs.count)))
            }
            run = []
        }
        for w in words {
            if let last = run.last, last.speaker != w.speaker { flushRun() }
            run.append(w)
        }
        flushRun()
        return out
    }

    /// 古い形式（items に speaker_label がない）では speaker_labels.segments から時刻で話者を引く
    static func speakerTimeline(_ results: [String: Any]) -> (Int64) -> String? {
        let segs = ((results["speaker_labels"] as? [String: Any])?["segments"] as? [[String: Any]]) ?? []
        let spans: [(start: Int64, end: Int64, label: String)] = segs.compactMap { s in
            guard let a = ms(s["start_time"]), let b = ms(s["end_time"]), let l = s["speaker_label"] as? String else { return nil }
            return (a, b, l)
        }
        return { t in spans.first { t >= $0.start && t < $0.end }?.label ?? spans.last { t >= $0.start }?.label }
    }

    static func ms(_ v: Any?) -> Int64? {
        guard let d = double(v) else { return nil }
        return Int64((d * 1000).rounded())
    }

    static func double(_ v: Any?) -> Double? {
        if let s = v as? String { return Double(s) }
        return (v as? NSNumber)?.doubleValue
    }
}
