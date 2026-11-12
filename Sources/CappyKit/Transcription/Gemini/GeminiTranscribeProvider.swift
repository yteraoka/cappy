import Foundation

/// Vertex AI の Gemini（gemini-3.5-transcribe）による録音済みファイルの文字起こし。
/// generateContent は同期 API なので、投入（submit）の中で分割・アップロード・認識まで行い、
/// 結果をジョブ情報（session.json）に保存する。分割ごとの結果はセッションディレクトリに一時保存し、
/// 途中で中断しても完了済みの分割は送り直さない。
public struct GeminiTranscribeProvider: TranscriptionProvider {
    public let name = "gemini"
    public var model: String? { settings.model }

    public let settings: GeminiSettings
    let projectID: String
    let bucket: String
    let auth: AccessTokenProvider
    let transport: HTTPTransport
    let retry: RetryPolicy
    let gcs: GCSClient
    let userProject: String?
    /// 同時に認識する分割の数
    let concurrency: Int

    public init(settings: GeminiSettings, projectID: String?, bucket: String?, auth: AccessTokenProvider,
                transport: HTTPTransport = URLSessionTransport(), retry: RetryPolicy = RetryPolicy(),
                concurrency: Int = 3) throws {
        guard let projectID, !projectID.isEmpty else {
            throw CappyError.usage(tr("project_id for Gemini transcription is not set", ja: "Gemini の文字起こしに使う project_id が設定されていません"),
                                   hint: tr("Set project_id in [profiles.<name>.google] of ~/.config/cappy/config.toml", ja: "~/.config/cappy/config.toml の [profiles.<name>.google] に project_id を書いてください"))
        }
        guard let bucket, !bucket.isEmpty else {
            throw CappyError.usage(tr("The bucket for the audio is not set", ja: "音声を置く bucket が設定されていません"),
                                   hint: tr("Set bucket in [profiles.<name>.google] of ~/.config/cappy/config.toml", ja: "~/.config/cappy/config.toml の [profiles.<name>.google] に bucket を書いてください"))
        }
        self.settings = settings
        self.projectID = projectID
        self.bucket = bucket
        self.auth = auth
        self.transport = transport
        self.retry = retry
        self.userProject = projectID
        self.gcs = GCSClient(auth: auth, transport: transport, userProject: projectID, retry: retry)
        self.concurrency = max(1, concurrency)
    }

    public func endpoint(method: String) -> String {
        "https://\(VertexAI.host(region: settings.location))/v1beta1/projects/\(projectID)/locations/\(settings.location)"
            + "/publishers/google/models/\(settings.model):\(method)"
    }

    func objectName(_ track: AudioTrack, index: Int, count: Int, ext: String) -> String {
        let base = "cappy/\(track.sessionID)/gemini/\(track.id.rawValue)"
        return count == 1 ? "\(base).\(ext)" : "\(base)-\(String(format: "%03d", index)).\(ext)"
    }

    // MARK: submit（認識まで行う）

    struct ChunkResult: Codable {
        var uri: String
        var offsetMs: Int64
        var segments: [Segment]
        var diarization: Bool
    }

    public func submit(_ track: AudioTrack, options: TranscriptionOptions) async throws -> JobHandle {
        let sessionDir = track.url.deletingLastPathComponent()
        let chunkDir = sessionDir.appendingPathComponent(".chunks-gemini-\(track.id.rawValue)")
        let cacheDir = sessionDir.appendingPathComponent(".gemini-\(track.id.rawValue)")
        let chunks = try SendFileConverter.split(track.url, maxSeconds: settings.chunkSeconds, into: chunkDir)
        defer { try? FileManager.default.removeItem(at: chunkDir) }
        try FileSecurity.createPrivateDirectory(cacheDir)

        let ext = track.url.pathExtension.lowercased()
        let mime = ext == "flac" ? "audio/flac" : "audio/wav"
        // 設定が変わったら一時保存した結果は使わない
        let key = [settings.model, options.language, String(options.diarization), String(options.wordTimestamps),
                   String(chunks.count), String(settings.chunkMinutes), settings.customVocabulary.joined(separator: ",")]
            .joined(separator: "|")
        let keyFile = cacheDir.appendingPathComponent("key")
        if (try? String(contentsOf: keyFile, encoding: .utf8)) != key {
            try? FileManager.default.removeItem(at: cacheDir)
            try FileSecurity.createPrivateDirectory(cacheDir)
            try FileSecurity.writeAtomically(Data(key.utf8), to: keyFile)
        }

        let total = chunks.count
        let progress = ProgressCounter()
        let results: [ChunkResult] = try await withThrowingTaskGroup(of: (Int, ChunkResult).self) { group in
            var out = [ChunkResult?](repeating: nil, count: total)
            var next = 0
            func launch(_ i: Int) {
                let chunk = chunks[i]
                let cacheFile = cacheDir.appendingPathComponent(String(format: "%03d.json", i))
                group.addTask {
                    if let data = try? Data(contentsOf: cacheFile),
                       let cached = try? JSONDecoder().decode(ChunkResult.self, from: data) {
                        return (i, cached)
                    }
                    let ref = GCSObjectRef(bucket: bucket, name: objectName(track, index: i, count: total, ext: ext))
                    do {
                        try await gcs.upload(file: chunk.url, to: ref, contentType: mime)
                    } catch let e as GoogleAPIError {
                        throw CappyError.transcription(tr("Upload to Cloud Storage failed: \(e)", ja: "Cloud Storage へのアップロードに失敗しました: \(e)"),
                                                       hint: e.httpStatus == 403 ? tr("Check the write permission on bucket \(bucket) (`cappy doctor`)", ja: "バケット \(bucket) への書き込み権限を確認してください（`cappy doctor`）") : nil)
                    }
                    let r = try await recognize(uri: ref.uri, mime: mime, chunk: chunk, track: track, options: options)
                    try FileSecurity.writeAtomically(try JSONEncoder().encode(r), to: cacheFile)
                    return (i, r)
                }
            }
            while next < min(concurrency, total) { launch(next); next += 1 }
            for try await (i, r) in group {
                out[i] = r
                let done = progress.increment()
                Console.status(tr("Recognizing \(track.id.displayName) (\(track.id.rawValue)) \(done)/\(total)", ja: "\(track.id.displayName)（\(track.id.rawValue)）を認識しています \(done)/\(total)"))
                if next < total { launch(next); next += 1 }
            }
            return out.compactMap { $0 }
        }
        Console.clearStatus()

        let diarization = options.diarization && results.allSatisfy(\.diarization)
        let segments = results.flatMap(\.segments).sorted { $0.startMs < $1.startMs }
        var info: [String: String] = [
            "files": String(decoding: try JSONEncoder().encode(results.map(\.uri)), as: UTF8.self),
            "segments": String(decoding: try JSONEncoder().encode(segments), as: UTF8.self),
            "diarization": diarization ? "true" : "false",
            "language": options.language,
        ]
        if options.diarization && !diarization {
            info["diarization_note"] = tr("Ran without speaker diarization because the model rejected it", ja: "モデルが話者分離を受け付けなかったため、話者分離なしで実行しました")
        }
        try? FileManager.default.removeItem(at: cacheDir)
        CappyLog.shared.info(tr("Recognized with Gemini track=\(track.id.rawValue) chunks=\(total) segments=\(segments.count)", ja: "Gemini で認識しました track=\(track.id.rawValue) chunks=\(total) segments=\(segments.count)"))
        return JobHandle(provider: name, track: track.id, id: "gemini:\(track.sessionID):\(track.id.rawValue)", info: info)
    }

    func recognize(uri: String, mime: String, chunk: SendFileConverter.Chunk, track: AudioTrack,
                   options: TranscriptionOptions) async throws -> ChunkResult {
        var diarization = options.diarization
        let body: Data
        do {
            body = try requestBody(uri: uri, mime: mime, options: options, diarization: diarization)
            let resp = try await call(body)
            return ChunkResult(uri: uri, offsetMs: chunk.offsetMs,
                               segments: try parse(resp, chunk: chunk, track: track, options: options),
                               diarization: diarization)
        } catch let e as GoogleAPIError where diarization && GoogleSpeechProvider.isDiarizationUnsupported(e) {
            CappyLog.shared.warning(tr("\(track.id.rawValue): disabled speaker diarization because it is not supported: \(e.message)", ja: "\(track.id.rawValue): 話者分離に対応していないため無効にしました: \(e.message)"))
            diarization = false
            let resp = try await call(try requestBody(uri: uri, mime: mime, options: options, diarization: false))
            return ChunkResult(uri: uri, offsetMs: chunk.offsetMs,
                               segments: try parse(resp, chunk: chunk, track: track, options: options),
                               diarization: false)
        }
    }

    func parse(_ resp: HTTPResponse, chunk: SendFileConverter.Chunk, track: AudioTrack,
               options: TranscriptionOptions) throws -> [Segment] {
        guard let obj = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            throw CappyError.transcription(tr("Invalid Gemini response", ja: "Gemini の応答が不正です"))
        }
        return try GeminiTranscriptParser.segments(response: obj, track: track.id,
                                                   offsetMs: track.offsetMs + chunk.offsetMs,
                                                   chunkDurationMs: chunk.durationMs, language: options.language)
    }

    func requestBody(uri: String, mime: String, options: TranscriptionOptions, diarization: Bool) throws -> Data {
        var config: [String: Any] = ["languageCodes": [options.language]]
        if options.wordTimestamps { config["wordTimestamp"] = true }
        if diarization { config["diarization"] = true }
        if !settings.customVocabulary.isEmpty { config["customVocabulary"] = settings.customVocabulary }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["fileData": ["fileUri": uri, "mimeType": mime]]]]],
            "generationConfig": ["audioTranscriptionConfig": config],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    func call(_ body: Data) async throws -> HTTPResponse {
        let url = endpoint(method: "generateContent")
        return try await retry.run(tr("Transcription with Gemini", ja: "Gemini による文字起こし")) {
            guard let u = URL(string: url) else { throw CappyError.transcription(tr("Invalid URL: \(url)", ja: "URL が不正です: \(url)")) }
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            // 15 分の音声の認識には時間がかかる
            req.timeoutInterval = 900
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
            if let userProject { req.setValue(userProject, forHTTPHeaderField: "x-goog-user-project") }
            req.httpBody = body
            let r = try await transport.send(req)
            guard r.status == 200 else { throw GoogleAPIError.from(r) }
            return r
        }
    }

    // MARK: status / result / cleanup

    public func status(of job: JobHandle) async throws -> JobStatus {
        job.info["segments"] == nil ? .failed(tr("No recognition result (start over with --force)", ja: "認識結果がありません（--force でやり直してください）")) : .done
    }

    public func result(of job: JobHandle) async throws -> [Segment] {
        guard let s = job.info["segments"] else {
            throw CappyError.transcription(tr("No recognition result", ja: "認識結果がありません"), hint: tr("Start over with `cappy transcribe --force`", ja: "`cappy transcribe --force` でやり直してください"))
        }
        return try JSONDecoder().decode([Segment].self, from: Data(s.utf8))
    }

    public func cleanup(_ job: JobHandle) async throws {
        let uris = (try? JSONDecoder().decode([String].self, from: Data((job.info["files"] ?? "[]").utf8))) ?? []
        for ref in uris.compactMap(GCSObjectRef.init(uri:)) {
            try await gcs.delete(ref)
        }
        CappyLog.shared.info(tr("Deleted the audio in the bucket track=\(job.track.rawValue) objects=\(uris.count)", ja: "バケット上の音声を削除しました track=\(job.track.rawValue) objects=\(uris.count)"))
    }

    // MARK: doctor

    /// モデルが見えるか（publishers.models.get）を確認する
    public func checkModel() async throws {
        let url = "https://\(VertexAI.host(region: settings.location))/v1beta1/publishers/google/models/\(settings.model)"
        guard let u = URL(string: url) else { return }
        var req = URLRequest(url: u)
        req.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        if let userProject { req.setValue(userProject, forHTTPHeaderField: "x-goog-user-project") }
        let r = try await transport.send(req)
        guard r.status == 200 else { throw GoogleAPIError.from(r) }
    }

    public var storage: GCSClient { gcs }
}

final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() -> Int { lock.withLock { n += 1; return n } }
}

/// generateContent（audioTranscriptionConfig）の応答を Segment に変換する
public enum GeminiTranscriptParser {
    /// これより長い発言は単語の区切りで分ける（ms）
    static let maxSegmentMs: Int64 = 30_000

    struct Word {
        var text: String
        var startMs: Int64?
        var endMs: Int64?
    }

    public static func segments(response obj: [String: Any], track: TrackID, offsetMs: Int64,
                                chunkDurationMs: Int64, language: String) throws -> [Segment] {
        if let fb = obj["promptFeedback"] as? [String: Any], let reason = fb["blockReason"] as? String {
            throw CappyError.transcription(tr("Gemini refused to process the audio (\(reason))", ja: "Gemini が音声の処理を拒否しました（\(reason)）"))
        }
        guard let candidate = (obj["candidates"] as? [[String: Any]])?.first else {
            return []
        }
        if let reason = candidate["finishReason"] as? String,
           !["STOP", "MAX_TOKENS", "FINISH_REASON_UNSPECIFIED"].contains(reason) {
            throw CappyError.transcription(tr("Gemini transcription stopped (\(reason))", ja: "Gemini の文字起こしが止まりました（\(reason)）"))
        }
        let parts = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let sep = GoogleResultParser.joiner(for: language)
        var out: [Segment] = []
        var untimed: [(text: String, speaker: String?)] = []
        for part in parts where part["thought"] as? Bool != true {
            let tx = GoogleResultParser.field(part, "audioTranscription") as? [String: Any]
            let text = ((part["text"] as? String) ?? (tx?["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let speaker = (tx.flatMap { GoogleResultParser.field($0, "speakerLabel") as? String }).flatMap { $0.isEmpty ? nil : $0 }
            let words: [Word] = ((tx?["words"] as? [[String: Any]]) ?? []).map { w in
                Word(text: (w["word"] as? String) ?? "",
                     startMs: GoogleResultParser.durationMs(GoogleResultParser.field(w, "startOffset")),
                     endMs: GoogleResultParser.durationMs(GoogleResultParser.field(w, "endOffset")))
            }
            var start = tx.flatMap { GoogleResultParser.durationMs(GoogleResultParser.field($0, "startOffset")) }
                ?? words.compactMap(\.startMs).first
            var end = tx.flatMap { GoogleResultParser.durationMs(GoogleResultParser.field($0, "endOffset")) }
                ?? words.compactMap(\.endMs).last
            if text.isEmpty && words.isEmpty { continue }
            guard let s = start else {
                untimed.append((text, speaker))
                continue
            }
            if end == nil || end! < s { end = s }
            start = s
            // 長い発言は単語の区切り（句点・間）で分ける
            if end! - s > maxSegmentMs, words.count > 1, words.allSatisfy({ $0.startMs != nil && $0.endMs != nil }) {
                out += split(words: words, speaker: speaker, track: track, offsetMs: offsetMs, sep: sep)
            } else {
                out.append(Segment(track: track, speaker: speaker, startMs: offsetMs + s, endMs: offsetMs + end!,
                                   text: text.isEmpty ? words.map(\.text).joined(separator: sep) : text, confidence: nil))
            }
        }
        // 時刻がない場合（単語タイムスタンプ無効など）は、文字数の比で分割内に割り振る
        if !untimed.isEmpty {
            let totalChars = max(1, untimed.reduce(0) { $0 + $1.text.count })
            var cursor: Int64 = 0
            for u in untimed {
                let len = Int64(Double(chunkDurationMs) * Double(u.text.count) / Double(totalChars))
                out.append(Segment(track: track, speaker: u.speaker, startMs: offsetMs + cursor,
                                   endMs: offsetMs + cursor + len, text: u.text, confidence: nil))
                cursor += len
            }
        }
        return out.sorted { $0.startMs < $1.startMs }
    }

    static func split(words: [Word], speaker: String?, track: TrackID, offsetMs: Int64, sep: String) -> [Segment] {
        let timed = words.map { (startMs: $0.startMs!, endMs: $0.endMs!, text: $0.text) }
        return groups(timed).compactMap { r in
            let group = words[r]
            let text = group.map(\.text).joined(separator: sep).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return Segment(track: track, speaker: speaker, startMs: offsetMs + group.first!.startMs!,
                           endMs: offsetMs + group.last!.endMs!, text: text, confidence: nil)
        }
    }

    /// 単語の並びを、長さ（30 秒）・文の終わり・間（0.8 秒）で区切った範囲。5 秒未満では文の終わりや間でも区切らない
    static func groups(_ words: [(startMs: Int64, endMs: Int64, text: String)]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var begin = 0
        for i in words.indices where i > begin {
            let prev = words[i - 1]
            let pause = words[i].startMs - prev.endMs
            let length = prev.endMs - words[begin].startMs
            let sentenceEnd = ["。", "？", "！", ".", "?", "!"].contains { prev.text.hasSuffix($0) }
            if length >= maxSegmentMs || (length >= 5_000 && (sentenceEnd || pause >= 800)) {
                out.append(begin..<i)
                begin = i
            }
        }
        if begin < words.count { out.append(begin..<words.count) }
        return out
    }
}
