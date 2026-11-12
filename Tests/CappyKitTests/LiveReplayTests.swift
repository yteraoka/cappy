import AVFoundation
import Foundation
import Testing
@testable import CappyKit

/// 録音済みの音声を実際の Live API（Vertex AI）に実時間で流し、確定した発言と認識途中の文字を表示する。
///   CAPPY_LIVE_REPLAY=<音声ファイル>   流す音声（session の remote.flac など）
///   CAPPY_LIVE_PROFILE=<name>          使うプロファイル（既定は default）
///   CAPPY_LIVE_SPEED=<倍率>            流す速さ（既定 1 = 実時間）
@Suite struct LiveReplayTests {
    static var file: String? { ProcessInfo.processInfo.environment["CAPPY_LIVE_REPLAY"] }

    @Test(.enabled(if: LiveReplayTests.file != nil), .timeLimit(.minutes(30)))
    func replayThroughVertexLive() async throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: try #require(Self.file))
        let speed = Double(env["CAPPY_LIVE_SPEED"] ?? "1") ?? 1
        let profile = try CappyConfig.load().profile(named: env["CAPPY_LIVE_PROFILE"])
        let project = try #require(profile.google.projectID)
        let connector = VertexLiveConnector(location: profile.gemini.location, auth: try ApplicationDefaultCredentials.load(),
                                            userProject: project)
        let config = LiveConfig.gemini(settings: profile.gemini, projectID: project, connector: connector)

        let began = Date()
        let stamp: @Sendable () -> String = { String(format: "%7.1fs", Date().timeIntervalSince(began)) }
        let state = ReplayState()
        var options = LiveTranscriber.Options(model: config.modelResource, language: profile.language, track: .remote)
        if let v = env["CAPPY_LIVE_TARGET_MS"].flatMap(Int64.init) { options.targetUtteranceMs = v }
        if let v = env["CAPPY_LIVE_MAX_MS"].flatMap(Int64.init) { options.maxUtteranceMs = v }
        let transcriber = LiveTranscriber(options: options, backend: config.backend) { event in
            switch event {
            case .segment(let s):
                state.add(s)
                print("\(stamp()) SEGMENT [\(TimeFormat.hms(ms: s.startMs))–\(TimeFormat.hms(ms: s.endMs))] (\(s.text.count) chars) \(s.text)")
            case .interim(_, let text?):
                // 認識途中の文字が全文か断片かを見るため、長さの変化と先頭・末尾を出す
                let prev = state.swapInterimLength(text.count)
                print("\(stamp()) interim len=\(text.count) (prev \(prev)) head=\(text.prefix(12)) tail=\(text.suffix(12))")
            case .interim(_, nil):
                _ = state.swapInterimLength(0)
            case .connected(_, let n): print("\(stamp()) connected session=\(n)")
            case .disconnected(_, let r): print("\(stamp()) DISCONNECTED \(r)")
            case .failed(_, let r): print("\(stamp()) FAILED \(r)")
            }
        }
        let sink = LiveAudioSink(transcriber: transcriber)
        let file = try AVAudioFile(forReading: url)
        try sink.start(format: file.processingFormat, track: .remote)
        let frames = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        var sentMs: Double = 0
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { break }
            try file.read(into: buf, frameCount: frames)
            if buf.frameLength == 0 { break }
            sink.consume(buf, at: 0)
            sentMs += Double(buf.frameLength) / file.processingFormat.sampleRate * 1000
            // 実時間（の speed 倍）に合わせて送る
            let wait = sentMs / speed / 1000 - Date().timeIntervalSince(began)
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        }
        print("\(stamp()) audio sent (\(Int(sentMs)) ms), finishing")
        try await sink.finish()
        let all = state.segments
        print("\(stamp()) done: segments=\(all.count) sessions=\(transcriber.sessions) dropped=\(transcriber.droppedMs)ms error=\(transcriber.lastError ?? "-")")
        #expect(!all.isEmpty)
    }
}

final class ReplayState: @unchecked Sendable {
    private let lock = NSLock()
    private var _segments: [Segment] = []
    private var interimLength = 0
    var segments: [Segment] { lock.withLock { _segments } }
    func add(_ s: Segment) { lock.withLock { _segments.append(s) } }
    func swapInterimLength(_ n: Int) -> Int {
        lock.withLock {
            defer { interimLength = n }
            return interimLength
        }
    }
}
