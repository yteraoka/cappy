import Foundation

/// Google Cloud Speech-to-Text v2 の BatchRecognize（Cloud Storage 経由）
public struct GoogleSpeechProvider: TranscriptionProvider {
    public let name = "google"
    public var model: String? { settings.model }

    public let settings: GoogleSettings
    let projectID: String
    let bucket: String
    let auth: AccessTokenProvider
    let transport: HTTPTransport
    let retry: RetryPolicy
    let gcs: GCSClient
    let userProject: String?

    /// BatchRecognize 1 リクエストあたりのファイル数上限
    static let maxFilesPerRequest = 15

    public init(settings: GoogleSettings, auth: AccessTokenProvider, transport: HTTPTransport = URLSessionTransport(),
                retry: RetryPolicy = RetryPolicy(), userProject: String? = nil) throws {
        guard let project = settings.projectID, !project.isEmpty else {
            throw CappyError.usage(tr("Google project_id is not set", ja: "Google の project_id が設定されていません"),
                                   hint: tr("Set project_id in [profiles.<name>.google] of ~/.config/cappy/config.toml", ja: "~/.config/cappy/config.toml の [profiles.<name>.google] に project_id を書いてください"))
        }
        guard let bucket = settings.bucket, !bucket.isEmpty else {
            throw CappyError.usage(tr("Google bucket is not set", ja: "Google の bucket が設定されていません"),
                                   hint: tr("Set bucket in [profiles.<name>.google] of ~/.config/cappy/config.toml", ja: "~/.config/cappy/config.toml の [profiles.<name>.google] に bucket を書いてください"))
        }
        self.settings = settings
        self.projectID = project
        self.bucket = bucket
        self.auth = auth
        self.transport = transport
        self.retry = retry
        self.userProject = userProject ?? project
        self.gcs = GCSClient(auth: auth, transport: transport, userProject: self.userProject, retry: retry)
    }

    var endpoint: String {
        settings.location == "global" ? "https://speech.googleapis.com" : "https://\(settings.location)-speech.googleapis.com"
    }

    var recognizer: String { "projects/\(projectID)/locations/\(settings.location)/recognizers/_" }

    func objectPrefix(_ sessionID: String) -> String { "cappy/\(sessionID)/" }

    // MARK: submit

    struct UploadedFile: Codable, Equatable {
        var uri: String
        var offsetMs: Int64
        enum CodingKeys: String, CodingKey {
            case uri
            case offsetMs = "offset_ms"
        }
    }

    public func submit(_ track: AudioTrack, options: TranscriptionOptions) async throws -> JobHandle {
        let chunkDir = track.url.deletingLastPathComponent().appendingPathComponent(".chunks-\(track.id.rawValue)")
        let chunks = try SendFileConverter.split(track.url, maxSeconds: settings.effectiveChunkSeconds, into: chunkDir)
        defer { try? FileManager.default.removeItem(at: chunkDir) }
        guard chunks.count <= Self.maxFilesPerRequest else {
            throw CappyError.transcription(tr("The audio is too long (\(chunks.count) chunks, limit \(Self.maxFilesPerRequest))", ja: "音声が長すぎます（\(chunks.count) 分割、上限 \(Self.maxFilesPerRequest)）"),
                                           hint: tr("Increase chunk_minutes or consider word_timestamps = false", ja: "chunk_minutes を大きくするか、word_timestamps = false を検討してください"))
        }
        let ext = track.url.pathExtension.lowercased()
        let contentType = ext == "flac" ? "audio/flac" : "audio/wav"
        var files: [UploadedFile] = []
        for (i, chunk) in chunks.enumerated() {
            let name = chunks.count == 1
                ? "\(objectPrefix(track.sessionID))\(track.id.rawValue).\(ext)"
                : "\(objectPrefix(track.sessionID))\(track.id.rawValue)-\(String(format: "%03d", i)).\(ext)"
            let ref = GCSObjectRef(bucket: bucket, name: name)
            CappyLog.shared.info(tr("Upload started \(ref.uri)", ja: "アップロード開始 \(ref.uri)"))
            do {
                try await gcs.upload(file: chunk.url, to: ref, contentType: contentType)
            } catch let e as GoogleAPIError {
                throw CappyError.transcription(tr("Upload to Cloud Storage failed: \(e)", ja: "Cloud Storage へのアップロードに失敗しました: \(e)"),
                                               hint: e.httpStatus == 403 ? tr("Check the write permission on bucket \(bucket) (`cappy doctor`)", ja: "バケット \(bucket) への書き込み権限を確認してください（`cappy doctor`）") : nil)
            }
            files.append(UploadedFile(uri: ref.uri, offsetMs: chunk.offsetMs))
        }
        let output = "gs://\(bucket)/\(objectPrefix(track.sessionID))results/\(track.id.rawValue)/"
        var diarization = options.diarization
        var note: String?
        var operation: String
        do {
            operation = try await batchRecognize(files: files.map(\.uri), output: output, options: options, diarization: diarization)
        } catch let e as GoogleAPIError where diarization && Self.isDiarizationUnsupported(e) {
            // モデルが話者分離に対応しない場合は、話者分離なしで続行する
            note = tr("Disabled speaker diarization because it is not supported: \(e.message)", ja: "話者分離に対応していないため無効にしました: \(e.message)")
            CappyLog.shared.warning("\(track.id.rawValue): \(note!)")
            diarization = false
            operation = try await batchRecognize(files: files.map(\.uri), output: output, options: options, diarization: false)
        }
        let filesJSON = String(decoding: try JSONEncoder().encode(files), as: UTF8.self)
        var info: [String: String] = [
            "files": filesJSON,
            "output": output,
            "language": options.language,
            "diarization": diarization ? "true" : "false",
            "track_offset_ms": String(track.offsetMs),
            "content_type": contentType,
        ]
        if let note { info["diarization_note"] = note }
        if options.diarization { info["diarization_requested"] = "true" }
        return JobHandle(provider: name, track: track.id, id: operation, info: info)
    }

    static func isDiarizationUnsupported(_ e: GoogleAPIError) -> Bool {
        guard e.httpStatus == 400 || e.status == "INVALID_ARGUMENT" else { return false }
        let m = e.message.lowercased()
        return m.contains("diariz") || m.contains("speaker")
    }

    func requestBody(files: [String], output: String, options: TranscriptionOptions, diarization: Bool) -> [String: Any] {
        var features: [String: Any] = [
            "enableAutomaticPunctuation": true,
        ]
        if options.wordTimestamps {
            features["enableWordTimeOffsets"] = true
            features["enableWordConfidence"] = true
        }
        if diarization {
            var d: [String: Any] = [:]
            if let v = options.minSpeakers { d["minSpeakerCount"] = v }
            if let v = options.maxSpeakers { d["maxSpeakerCount"] = v }
            features["diarizationConfig"] = d
        }
        return [
            "config": [
                "autoDecodingConfig": [String: Any](),
                "model": settings.model,
                "languageCodes": [options.language],
                "features": features,
            ],
            "files": files.map { ["uri": $0] },
            "recognitionOutputConfig": ["gcsOutputConfig": ["uri": output]],
        ]
    }

    func batchRecognize(files: [String], output: String, options: TranscriptionOptions, diarization: Bool) async throws -> String {
        let body = requestBody(files: files, output: output, options: options, diarization: diarization)
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let url = "\(endpoint)/v2/\(recognizer):batchRecognize"
        let resp = try await retry.run("BatchRecognize") {
            var req = try await request(url, method: "POST")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            let r = try await transport.send(req)
            guard r.status == 200 else { throw GoogleAPIError.from(r) }
            return r
        }
        guard let obj = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              let name = obj["name"] as? String else {
            throw CappyError.transcription(tr("The BatchRecognize response has no operation name", ja: "BatchRecognize の応答にオペレーション名がありません"))
        }
        CappyLog.shared.info(tr("BatchRecognize started operation=\(name) files=\(files.count) diarization=\(diarization)", ja: "BatchRecognize を開始しました operation=\(name) files=\(files.count) diarization=\(diarization)"))
        return name
    }

    func request(_ url: String, method: String = "GET") async throws -> URLRequest {
        guard let u = URL(string: url) else { throw CappyError.transcription(tr("Invalid URL: \(url)", ja: "URL が不正です: \(url)")) }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        if let userProject { req.setValue(userProject, forHTTPHeaderField: "x-goog-user-project") }
        return req
    }

    // MARK: status / result

    func operation(_ job: JobHandle) async throws -> [String: Any] {
        let url = "\(endpoint)/v2/\(job.id)"
        let resp = try await retry.run(tr("Getting the operation", ja: "オペレーション取得")) {
            let r = try await transport.send(try await request(url))
            guard r.status == 200 else { throw GoogleAPIError.from(r) }
            return r
        }
        guard let obj = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            throw CappyError.transcription(tr("Invalid operation response", ja: "オペレーションの応答が不正です"))
        }
        return obj
    }

    public func status(of job: JobHandle) async throws -> JobStatus {
        let op = try await operation(job)
        if let err = op["error"] as? [String: Any] {
            return .failed(err["message"] as? String ?? tr("unknown error", ja: "不明なエラー"))
        }
        if op["done"] as? Bool == true {
            // ファイル単位のエラー
            for (_, value) in fileResults(op) {
                if let err = (value as? [String: Any])?["error"] as? [String: Any], (err["code"] as? Int ?? 0) != 0 {
                    return .failed(err["message"] as? String ?? tr("Recognition of the file failed", ja: "ファイルの認識に失敗しました"))
                }
            }
            return .done
        }
        let progress = ((op["metadata"] as? [String: Any])?["progressPercent"] as? NSNumber)?.intValue
        return .running(progress: progress)
    }

    func fileResults(_ op: [String: Any]) -> [String: Any] {
        ((op["response"] as? [String: Any])?["results"] as? [String: Any]) ?? [:]
    }

    func uploadedFiles(_ job: JobHandle) throws -> [UploadedFile] {
        guard let s = job.info["files"] else { return [] }
        return try JSONDecoder().decode([UploadedFile].self, from: Data(s.utf8))
    }

    public func result(of job: JobHandle) async throws -> [Segment] {
        let op = try await operation(job)
        guard op["done"] as? Bool == true else { throw CappyError.transcription(tr("The job has not finished yet: \(job.id)", ja: "ジョブがまだ完了していません: \(job.id)")) }
        if let err = op["error"] as? [String: Any] {
            throw CappyError.transcription(tr("Transcription failed: \(err["message"] as? String ?? "")", ja: "文字起こしに失敗しました: \(err["message"] as? String ?? "")"))
        }
        let results = fileResults(op)
        let language = job.info["language"] ?? "ja-JP"
        let trackOffset = Int64(job.info["track_offset_ms"] ?? "0") ?? 0
        var segments: [Segment] = []
        for file in try uploadedFiles(job) {
            guard let r = results[file.uri] as? [String: Any] else {
                throw CappyError.transcription(tr("The result does not include \(file.uri)", ja: "結果に \(file.uri) が含まれていません"))
            }
            if let err = r["error"] as? [String: Any], (err["code"] as? Int ?? 0) != 0 {
                throw CappyError.transcription(tr("Recognition of \(file.uri) failed: \(err["message"] as? String ?? "")", ja: "\(file.uri) の認識に失敗しました: \(err["message"] as? String ?? "")"))
            }
            let offset = trackOffset + file.offsetMs
            if let inline = (r["inlineResult"] as? [String: Any])?["transcript"] as? [String: Any] {
                let rs = inline["results"] as? [[String: Any]] ?? []
                segments += GoogleResultParser.segments(fromResults: rs, track: job.track, offsetMs: offset, language: language)
                continue
            }
            let uri = ((r["cloudStorageResult"] as? [String: Any])?["uri"] as? String) ?? (r["uri"] as? String)
            guard let uri, let ref = GCSObjectRef(uri: uri) else {
                throw CappyError.transcription(tr("The result file location of \(file.uri) is unknown", ja: "\(file.uri) の結果ファイルの場所がわかりません"))
            }
            let data = try await gcs.download(ref)
            segments += try GoogleResultParser.segments(fromJSON: data, track: job.track, offsetMs: offset, language: language)
        }
        return segments.sorted { $0.startMs < $1.startMs }
    }

    // MARK: cleanup

    public func cleanup(_ job: JobHandle) async throws {
        var refs = try uploadedFiles(job).compactMap { GCSObjectRef(uri: $0.uri) }
        if let output = job.info["output"], let prefix = GCSObjectRef(uri: output) {
            refs += try await gcs.list(bucket: prefix.bucket, prefix: prefix.name)
        }
        for ref in refs {
            try await gcs.delete(ref)
        }
        CappyLog.shared.info(tr("Deleted the audio and results in the bucket track=\(job.track.rawValue) objects=\(refs.count)", ja: "バケット上の音声と結果を削除しました track=\(job.track.rawValue) objects=\(refs.count)"))
    }

    // MARK: doctor

    /// 認証・API・バケットの確認
    public func checkAPI() async throws {
        let url = "\(endpoint)/v2/projects/\(projectID)/locations/\(settings.location)"
        let r = try await transport.send(try await request(url))
        guard r.status == 200 else { throw GoogleAPIError.from(r) }
    }

    public var storage: GCSClient { gcs }
    public var bucketName: String { bucket }
}
