import Foundation

/// 文字起こしの実行と再開。状態はすべて session.json に記録する
public final class Transcriber: @unchecked Sendable {
    public struct Options: Sendable {
        public var language: String
        public var mix: Bool
        public var formats: [TranscriptFormat]
        public var diarization: Bool
        public var wordTimestamps: Bool
        public var minSpeakers: Int?
        public var maxSpeakers: Int?
        public var cleanup: Bool
        public var force: Bool
        public var location: String?
        /// ポーリング間隔（指数バックオフ）
        public var pollInitial: TimeInterval = 5
        public var pollMax: TimeInterval = 300
        public var pollFactor: Double = 1.5

        public init(language: String, mix: Bool, formats: [TranscriptFormat], diarization: Bool = true,
                    wordTimestamps: Bool = true, minSpeakers: Int? = nil, maxSpeakers: Int? = nil,
                    cleanup: Bool = true, force: Bool = false, location: String? = nil) {
            self.language = language
            self.mix = mix
            self.formats = formats
            self.diarization = diarization
            self.wordTimestamps = wordTimestamps
            self.minSpeakers = minSpeakers
            self.maxSpeakers = maxSpeakers
            self.cleanup = cleanup
            self.force = force
            self.location = location
        }
    }

    let store: SessionStore
    let provider: TranscriptionProvider
    let options: Options
    let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(store: SessionStore, provider: TranscriptionProvider, options: Options,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.store = store
        self.provider = provider
        self.options = options
        self.sleep = sleep
    }

    @discardableResult
    public func run() async throws -> [URL] {
        try ensureSendFiles()
        let meta = store.metadata

        // 完了済みなら transcript.json から出力し直すだけ
        if !options.force, let t = meta.transcription, t.state == .done,
           let doc = try? loadTranscript(), t.mix == options.mix {
            Console.print("文字起こしは完了済みです。transcript を出力し直します（再実行は --force）")
            return try TranscriptRenderer.write(doc, formats: options.formats, to: store.directory)
        }

        try prepareState()
        try await submitPending()
        try await pollUntilDone()
        let doc = try await collectResults()
        let urls = try TranscriptRenderer.write(doc, formats: options.formats.contains(.json) ? options.formats : options.formats + [.json],
                                                to: store.directory)
        try store.update { m in
            m.transcription?.state = .done
            m.transcription?.error = nil
            m.transcription?.updatedAt = TimeFormat.iso8601(Date())
        }
        CappyLog.shared.info("文字起こしが完了しました segments=\(doc.segments.count)")
        if options.cleanup {
            await cleanupRemote()
        }
        // json は再開・再出力のために常に書くが、指定がなければ一覧には出さない
        return urls.filter { u in options.formats.contains { $0.fileName == u.lastPathComponent } }
    }

    // MARK: 準備

    func ensureSendFiles() throws {
        let meta = store.metadata
        switch meta.recording.state {
        case .recording:
            throw CappyError.usage("このセッションは録音中か、異常終了しています",
                                   hint: "異常終了した場合は `cappy recover \(store.directory.path)` を実行してください")
        case .finalized:
            Console.print("送信用ファイルを作成しています…")
            try SessionProcessing.convert(store)
        case .converted:
            let missing = meta.tracks.contains { t in
                t.sendFile.map { !FileManager.default.fileExists(atPath: store.url(for: $0).path) } ?? true
            }
            if missing {
                Console.print("送信用ファイルが見つからないため作り直しています…")
                try SessionProcessing.convert(store)
            }
        }
        if options.mix {
            let tracks = store.metadata.tracks.filter { $0.id != .mix && $0.sendFile != nil }
            guard tracks.count >= 1 else { throw CappyError.usage("ミックスするトラックがありません") }
            let mixExists = store.metadata.track(.mix).flatMap(\.sendFile).map {
                FileManager.default.fileExists(atPath: store.url(for: $0).path)
            } ?? false
            if !mixExists {
                let inputs = tracks.map { (url: store.url(for: $0.sendFile!), offsetMs: $0.offsetMs) }
                let r = try SendFileConverter.mix(inputs: inputs, outputBase: store.url(for: "mix"))
                try store.update { m in
                    m.tracks.removeAll { $0.id == .mix }
                    var t = SessionTrack(id: .mix, file: r.url.lastPathComponent, sampleRate: SendFileConverter.sampleRate, channels: 1)
                    t.sendFile = r.url.lastPathComponent
                    t.frames = r.frames
                    t.durationMs = r.durationMs
                    m.tracks.append(t)
                }
            }
        }
    }

    func tracksToSend() -> [SessionTrack] {
        let tracks = store.metadata.tracks.filter { $0.sendFile != nil }
        if options.mix { return tracks.filter { $0.id == .mix } }
        return tracks.filter { $0.id != .mix }.sorted { $0.id < $1.id }
    }

    func prepareState() throws {
        let meta = store.metadata
        if let t = meta.transcription, !options.force {
            let submitted = t.jobs.contains { $0.handle != nil }
            let compatible = t.provider == provider.name && t.mix == options.mix && t.language == options.language
            if submitted && !compatible {
                throw CappyError.usage(
                    "既存の文字起こしジョブ（\(t.provider), \(t.language)\(t.mix ? ", mix" : "")）と指定が異なります",
                    hint: "やり直す場合は --force を指定してください")
            }
            if compatible {
                if t.state == .failed {
                    // 失敗したジョブは投入し直す
                    try store.update { m in
                        for i in m.transcription!.jobs.indices where m.transcription!.jobs[i].state == .failed {
                            m.transcription!.jobs[i] = TranscriptionJobRecord(track: m.transcription!.jobs[i].track, state: .pending)
                        }
                        m.transcription!.state = .running
                        m.transcription!.error = nil
                    }
                }
                return
            }
        }
        var state = TranscriptionState(provider: provider.name, model: provider.model, language: options.language,
                                       location: options.location, mix: options.mix)
        state.jobs = tracksToSend().map { TranscriptionJobRecord(track: $0.id, state: .pending) }
        state.state = .running
        state.updatedAt = TimeFormat.iso8601(Date())
        guard !state.jobs.isEmpty else { throw CappyError.usage("送信するトラックがありません") }
        try store.update { m in m.transcription = state }
    }

    // MARK: 投入

    func submitPending() async throws {
        let sessionID = store.metadata.id
        for record in store.metadata.transcription?.jobs ?? [] where record.handle == nil {
            guard let track = store.metadata.track(record.track), let send = track.sendFile else { continue }
            let audio = AudioTrack(id: track.id, url: store.url(for: send), offsetMs: track.offsetMs,
                                   durationMs: track.durationMs, sessionID: sessionID)
            let opts = TranscriptionOptions(language: options.language,
                                            diarization: options.diarization && track.id != .mic,
                                            wordTimestamps: options.wordTimestamps,
                                            minSpeakers: options.minSpeakers, maxSpeakers: options.maxSpeakers)
            Console.print("\(track.id.displayName)（\(track.id.rawValue)）を送信しています…")
            let handle: JobHandle
            do {
                handle = try await provider.submit(audio, options: opts)
            } catch {
                try markFailed(track.id, error)
                throw wrap(error)
            }
            try store.update { m in
                guard let i = m.transcription?.jobs.firstIndex(where: { $0.track == track.id }) else { return }
                m.transcription!.jobs[i].handle = handle
                m.transcription!.jobs[i].state = .running
                m.transcription!.jobs[i].submittedAt = TimeFormat.iso8601(Date())
                if track.id != .mic {
                    m.transcription!.jobs[i].diarization = handle.info["diarization"] == "true"
                    m.transcription!.jobs[i].note = handle.info["diarization_note"]
                }
                m.transcription!.updatedAt = TimeFormat.iso8601(Date())
            }
        }
    }

    // MARK: ポーリング

    func pollUntilDone() async throws {
        var delay = options.pollInitial
        let started = Date()
        while true {
            var running: [TrackID: Int?] = [:]
            for record in store.metadata.transcription?.jobs ?? [] where record.state == .running {
                guard let handle = record.handle else { continue }
                let st: JobStatus
                do {
                    st = try await provider.status(of: handle)
                } catch {
                    try markFailed(record.track, error)
                    throw wrap(error)
                }
                switch st {
                case .pending:
                    running[record.track] = .some(nil)
                case .running(let p):
                    running[record.track] = p
                case .done:
                    try store.update { m in
                        guard let i = m.transcription?.jobs.firstIndex(where: { $0.track == record.track }) else { return }
                        m.transcription!.jobs[i].state = .done
                        m.transcription!.jobs[i].completedAt = TimeFormat.iso8601(Date())
                    }
                    Console.print("\(record.track.displayName)（\(record.track.rawValue)）の認識が完了しました")
                case .failed(let message):
                    if handle.info["diarization"] == "true", Self.mentionsDiarization(message) {
                        // 実行時に話者分離が拒否された場合は、話者分離なしで投入し直す
                        Console.print("話者分離が使えなかったため、話者分離なしで再送信します")
                        try await resubmitWithoutDiarization(record)
                        running[record.track] = .some(nil)
                        continue
                    }
                    let err = CappyError.transcription("\(record.track.rawValue) の文字起こしに失敗しました: \(message)")
                    try markFailed(record.track, err)
                    throw err
                }
            }
            if running.isEmpty { return }
            let progress = running.keys.sorted().map { t in
                "\(t.rawValue) \(running[t]!.flatMap { $0 }.map { "\($0)%" } ?? "…")"
            }.joined(separator: "  ")
            Console.status("認識中 \(TimeFormat.elapsed(Date().timeIntervalSince(started)))  \(progress)")
            try await sleep(delay)
            delay = min(options.pollMax, delay * options.pollFactor)
        }
    }

    static func mentionsDiarization(_ m: String) -> Bool {
        let l = m.lowercased()
        return l.contains("diariz") || l.contains("speaker")
    }

    func resubmitWithoutDiarization(_ record: TranscriptionJobRecord) async throws {
        if let h = record.handle { try? await provider.cleanup(h) }
        guard let track = store.metadata.track(record.track), let send = track.sendFile else { return }
        let audio = AudioTrack(id: track.id, url: store.url(for: send), offsetMs: track.offsetMs,
                               durationMs: track.durationMs, sessionID: store.metadata.id)
        let opts = TranscriptionOptions(language: options.language, diarization: false, wordTimestamps: options.wordTimestamps)
        let handle = try await provider.submit(audio, options: opts)
        try store.update { m in
            guard let i = m.transcription?.jobs.firstIndex(where: { $0.track == record.track }) else { return }
            m.transcription!.jobs[i].handle = handle
            m.transcription!.jobs[i].diarization = false
            m.transcription!.jobs[i].note = "モデルが話者分離に対応していないため、話者分離なしで実行しました"
        }
    }

    // MARK: 結果

    func collectResults() async throws -> TranscriptDocument {
        let meta = store.metadata
        guard let t = meta.transcription else { throw CappyError.transcription("文字起こしの状態がありません") }
        var perTrack: [[Segment]] = []
        var diarization: [String: Bool] = [:]
        for record in t.jobs {
            guard let handle = record.handle else { continue }
            do {
                perTrack.append(try await provider.result(of: handle))
            } catch {
                try markFailed(record.track, error)
                throw wrap(error)
            }
            if record.track != .mic { diarization[record.track.rawValue] = record.diarization ?? false }
        }
        return TranscriptDocument(sessionID: meta.id, name: meta.name, startedAt: meta.startedAt,
                                  provider: provider.name, model: provider.model, language: t.language,
                                  mix: t.mix, diarization: diarization, segments: TranscriptMerger.merge(perTrack))
    }

    func loadTranscript() throws -> TranscriptDocument {
        let data = try Data(contentsOf: store.url(for: TranscriptFormat.json.fileName))
        return try JSONDecoder().decode(TranscriptDocument.self, from: data)
    }

    func cleanupRemote() async {
        var ok = true
        for record in store.metadata.transcription?.jobs ?? [] {
            guard let h = record.handle else { continue }
            do {
                try await provider.cleanup(h)
            } catch {
                ok = false
                CappyLog.shared.warning("クラウド上のファイルを削除できませんでした（ライフサイクルルールで削除されます）: \(error)")
                Console.print("警告: クラウド上のファイルを削除できませんでした: \(error)")
            }
        }
        _ = try? store.update { m in m.transcription?.cleanedUp = ok }
    }

    // MARK: エラー

    func markFailed(_ track: TrackID, _ error: Error) throws {
        let message = String(describing: error)
        CappyLog.shared.error("文字起こしエラー track=\(track.rawValue): \(message)")
        try store.update { m in
            if let i = m.transcription?.jobs.firstIndex(where: { $0.track == track }) {
                m.transcription!.jobs[i].state = .failed
                m.transcription!.jobs[i].error = message
            }
            m.transcription?.state = .failed
            m.transcription?.error = message
            m.transcription?.updatedAt = TimeFormat.iso8601(Date())
        }
    }

    func wrap(_ error: Error) -> Error {
        if error is CappyError { return error }
        if let g = error as? GoogleAPIError {
            var hint: String?
            if g.httpStatus == 401 || g.httpStatus == 403 {
                hint = "認証情報と権限を確認してください（`cappy doctor`）"
            } else if g.httpStatus == 429 {
                hint = "クォータを超えている可能性があります"
            }
            return CappyError.transcription("文字起こしサービスのエラー: \(g)", hint: hint)
        }
        return CappyError.transcription("文字起こしに失敗しました: \(error)")
    }
}

/// プロファイルからプロバイダを作る
public enum ProviderFactory {
    public static func make(name: String, profile: Profile, transport: HTTPTransport = URLSessionTransport()) throws -> TranscriptionProvider {
        switch name {
        case "gemini":
            let auth = try ApplicationDefaultCredentials.load(transport: transport)
            return try GeminiTranscribeProvider(settings: profile.gemini, projectID: profile.geminiProjectID,
                                                bucket: profile.google.bucket, auth: auth, transport: transport)
        case "google":
            let auth = try ApplicationDefaultCredentials.load(transport: transport)
            return try GoogleSpeechProvider(settings: profile.google, auth: auth, transport: transport)
        case "none":
            throw CappyError.usage("プロバイダが none のため、文字起こしは行いません（録音のみ）")
        default:
            throw CappyError.usage("未対応のプロバイダです: \(name)（gemini / google / none）")
        }
    }
}
