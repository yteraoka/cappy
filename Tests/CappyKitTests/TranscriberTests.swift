import Foundation
import Testing
@testable import CappyKit

/// 状態を持つ偽プロバイダ
final class FakeProvider: TranscriptionProvider, @unchecked Sendable {
    let name = "google"
    let model: String? = "chirp_3"
    private let lock = NSLock()
    var submitted: [TrackID] = []
    var statusCalls = 0
    var cleaned: [TrackID] = []
    var pendingPolls = 2
    var failSubmitFor: TrackID?
    var rejectDiarizationAtRuntime = false
    var diarizationRequests: [Bool] = []

    func submit(_ track: AudioTrack, options: TranscriptionOptions) async throws -> JobHandle {
        try lock.withLock {
            if track.id == failSubmitFor { throw GoogleAPIError(httpStatus: 403, status: "PERMISSION_DENIED", message: "denied") }
            submitted.append(track.id)
            diarizationRequests.append(options.diarization)
            return JobHandle(provider: name, track: track.id, id: "op-\(track.id.rawValue)-\(submitted.count)",
                             info: ["diarization": options.diarization ? "true" : "false"])
        }
    }

    func status(of job: JobHandle) async throws -> JobStatus {
        lock.withLock {
            statusCalls += 1
            if rejectDiarizationAtRuntime, job.info["diarization"] == "true" {
                return .failed("speaker diarization is not supported for this model")
            }
            if pendingPolls > 0 { pendingPolls -= 1; return .running(progress: 50) }
            return .done
        }
    }

    func result(of job: JobHandle) async throws -> [Segment] {
        switch job.track {
        case .mic: return [Segment(track: .mic, speaker: nil, startMs: 2000, endMs: 3000, text: "自分の発言", confidence: 0.9)]
        case .remote: return [Segment(track: .remote, speaker: "1", startMs: 500, endMs: 1500, text: "相手の発言", confidence: 0.8)]
        case .mix: return [Segment(track: .mix, speaker: nil, startMs: 0, endMs: 1000, text: "ミックス", confidence: 0.8)]
        }
    }

    func cleanup(_ job: JobHandle) async throws {
        lock.withLock { cleaned.append(job.track) }
    }
}

@Suite struct TranscriberTests {
    func makeSession() throws -> SessionStore {
        let dir = try TestSupport.tempDir()
        try TestSupport.writeSineCAF(dir.appendingPathComponent("remote.caf"), seconds: 1, channels: 2)
        try TestSupport.writeSineCAF(dir.appendingPathComponent("mic.caf"), seconds: 1, channels: 1)
        var meta = SessionMetadata(id: "sid", name: "test")
        meta.startedAt = "2026-11-11T01:00:00.000Z"
        meta.tracks = [SessionTrack(id: .remote, file: "remote.caf", sampleRate: 48_000, channels: 2),
                       SessionTrack(id: .mic, file: "mic.caf", sampleRate: 48_000, channels: 1)]
        meta.recording.state = .finalized
        let store = SessionStore(directory: dir, metadata: meta)
        try store.save()
        return store
    }

    func options(mix: Bool = false, force: Bool = false) -> Transcriber.Options {
        Transcriber.Options(language: "ja-JP", mix: mix, formats: [.md, .json, .srt], force: force)
    }

    @Test func fullRunWritesOutputsAndCleansUp() async throws {
        let store = try makeSession()
        let p = FakeProvider()
        let urls = try await Transcriber(store: store, provider: p, options: options(), sleep: { _ in }).run()
        #expect(urls.map(\.lastPathComponent).sorted() == ["transcript.json", "transcript.md", "transcript.srt"])
        #expect(Set(p.submitted) == [.mic, .remote])
        #expect(p.diarizationRequests.count == 2)
        // mic には話者分離を要求しない
        let m = store.metadata
        #expect(m.recording.state == .converted)
        #expect(m.transcription?.state == .done)
        #expect(m.transcription?.cleanedUp == true)
        #expect(m.transcription?.jobs.allSatisfy { $0.state == .done && $0.handle != nil } == true)
        #expect(Set(p.cleaned) == [.mic, .remote])
        let doc = try JSONDecoder().decode(TranscriptDocument.self, from: Data(contentsOf: store.url(for: "transcript.json")))
        #expect(doc.segments.map(\.text) == ["相手の発言", "自分の発言"])
        let md = try String(contentsOf: store.url(for: "transcript.md"), encoding: .utf8)
        #expect(md.contains("**[00:00:00] 相手**: 相手の発言"))
    }

    @Test func resumesWithoutResubmitting() async throws {
        let store = try makeSession()
        // 1 回目: 投入まで済んだ状態を作る
        let p1 = FakeProvider()
        p1.failSubmitFor = .remote
        do {
            _ = try await Transcriber(store: store, provider: p1, options: options(), sleep: { _ in }).run()
            Issue.record("should fail")
        } catch let e as CappyError {
            #expect(e.status == .transcription)
        }
        #expect(store.metadata.transcription?.state == .failed)
        #expect(p1.submitted == [.mic])
        // 2 回目: mic のジョブは再利用し、失敗した remote だけ投入し直す
        let p2 = FakeProvider()
        _ = try await Transcriber(store: store, provider: p2, options: options(), sleep: { _ in }).run()
        #expect(p2.submitted == [.remote])
        #expect(store.metadata.transcription?.state == .done)
    }

    @Test func doneSessionOnlyRerenders() async throws {
        let store = try makeSession()
        _ = try await Transcriber(store: store, provider: FakeProvider(), options: options(), sleep: { _ in }).run()
        try FileManager.default.removeItem(at: store.url(for: "transcript.srt"))
        let p = FakeProvider()
        let urls = try await Transcriber(store: store, provider: p,
                                         options: Transcriber.Options(language: "ja-JP", mix: false, formats: [.srt]),
                                         sleep: { _ in }).run()
        #expect(urls.map(\.lastPathComponent) == ["transcript.srt"])
        #expect(p.submitted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.url(for: "transcript.srt").path))
    }

    @Test func mixSendsSingleTrack() async throws {
        let store = try makeSession()
        let p = FakeProvider()
        _ = try await Transcriber(store: store, provider: p, options: options(mix: true), sleep: { _ in }).run()
        #expect(p.submitted == [.mix])
        #expect(FileManager.default.fileExists(atPath: store.url(for: "mix.flac").path))
        #expect(store.metadata.transcription?.mix == true)
    }

    @Test func mismatchedRunRequiresForce() async throws {
        let store = try makeSession()
        _ = try await Transcriber(store: store, provider: FakeProvider(), options: options(), sleep: { _ in }).run()
        // done の場合は mix が違えば実行し直しが必要
        try store.update { $0.transcription?.state = .running }
        await #expect(throws: CappyError.self) {
            _ = try await Transcriber(store: store, provider: FakeProvider(), options: options(mix: true), sleep: { _ in }).run()
        }
        let p = FakeProvider()
        _ = try await Transcriber(store: store, provider: p, options: options(mix: true, force: true), sleep: { _ in }).run()
        #expect(p.submitted == [.mix])
    }

    @Test func runtimeDiarizationRejectionResubmits() async throws {
        let store = try makeSession()
        let p = FakeProvider()
        p.rejectDiarizationAtRuntime = true
        p.pendingPolls = 0
        _ = try await Transcriber(store: store, provider: p, options: options(), sleep: { _ in }).run()
        let remote = store.metadata.transcription?.jobs.first { $0.track == .remote }
        #expect(remote?.diarization == false)
        #expect(remote?.note != nil)
        #expect(p.submitted.filter { $0 == .remote }.count == 2)
    }

    @Test func recordingStateIsRejected() async throws {
        let store = try makeSession()
        try store.update { $0.recording.state = .recording }
        do {
            _ = try await Transcriber(store: store, provider: FakeProvider(), options: options(), sleep: { _ in }).run()
            Issue.record("should throw")
        } catch let e as CappyError {
            #expect(e.status == .usage)
        }
    }
}
