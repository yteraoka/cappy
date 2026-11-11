import AVFoundation
import Foundation
@testable import CappyKit

enum TestSupport {
    static func tempDir(_ name: String = #function) throws -> URL {
        let safe = name.replacingOccurrences(of: "[^A-Za-z0-9]", with: "", options: .regularExpression)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cappy-tests")
            .appendingPathComponent("\(safe)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// サイン波の CAF（Float32・インターリーブ）を作る
    @discardableResult
    static func writeSineCAF(_ url: URL, seconds: Double, sampleRate: Double = 48_000, channels: AVAudioChannelCount = 2,
                             frequency: Double = 440, amplitude: Float = 0.5) throws -> AVAudioFormat {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: true)!
        let sink = FileSink(url: url)
        try sink.start(format: format, track: .remote)
        let total = Int(seconds * sampleRate)
        let chunk = 4800
        var written = 0
        while written < total {
            let n = min(chunk, total - written)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            let p = buf.floatChannelData![0]
            for i in 0..<n {
                let v = amplitude * Float(sin(2 * .pi * frequency * Double(written + i) / sampleRate))
                for c in 0..<Int(channels) { p[i * Int(channels) + c] = v }
            }
            sink.consume(buf, at: 0)
            written += n
        }
        try sink.close()
        return format
    }

    /// 読み込んだ音声のゼロ交差数から周波数を推定する
    static func estimateFrequency(_ url: URL) throws -> (frequency: Double, frames: Int64, sampleRate: Double, channels: Int) {
        let f = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let p = buf.floatChannelData![0]
        var crossings = 0
        for i in 1..<Int(buf.frameLength) where (p[i - 1] < 0) != (p[i] < 0) { crossings += 1 }
        let secs = Double(buf.frameLength) / f.processingFormat.sampleRate
        return (Double(crossings) / 2 / secs, f.length, f.fileFormat.sampleRate, Int(f.fileFormat.channelCount))
    }
}

/// 固定トークンを返す認証
struct StaticToken: AccessTokenProvider {
    func accessToken() async throws -> String { "test-token" }
    var quotaProjectID: String? { nil }
    var summary: String { "static" }
}

/// HTTP のスタブ
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Call: Sendable {
        var method: String
        var url: String
        var body: Data?
        var uploadedFile: URL?
        var headers: [String: String]
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    let handler: @Sendable (Call) -> HTTPResponse

    init(handler: @escaping @Sendable (Call) -> HTTPResponse) { self.handler = handler }

    var calls: [Call] { lock.withLock { _calls } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let call = Call(method: request.httpMethod ?? "GET", url: request.url!.absoluteString, body: request.httpBody,
                        uploadedFile: nil, headers: request.allHTTPHeaderFields ?? [:])
        lock.withLock { _calls.append(call) }
        return handler(call)
    }

    func upload(_ request: URLRequest, fromFile url: URL) async throws -> HTTPResponse {
        let call = Call(method: request.httpMethod ?? "POST", url: request.url!.absoluteString, body: nil,
                        uploadedFile: url, headers: request.allHTTPHeaderFields ?? [:])
        lock.withLock { _calls.append(call) }
        return handler(call)
    }
}

extension HTTPResponse {
    static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: obj))
    }
}
