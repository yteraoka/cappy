import AVFoundation
import Foundation

/// リングバッファから取り出した音声の配り先。
/// フェーズ 1 は FileSink（CAF 書き出し）、フェーズ 3 で StreamingSink を追加する。
public protocol AudioSink: AnyObject {
    func start(format: AVAudioFormat, track: TrackID) throws
    func consume(_ buffer: AVAudioPCMBuffer, at hostTime: UInt64)
    func finish() async throws
    /// consume 中に起きたエラー（consume は throw しないため、ここで報告する）
    var failure: Error? { get }
}

/// 録音中の原本を CAF（ネイティブ形式・Float32）で書き出す。
/// CAF は長さ未確定でも読めるため、異常終了しても recover で復旧できる。
public final class FileSink: AudioSink, @unchecked Sendable {
    public let url: URL
    private var file: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let lock = NSLock()
    private var _failure: Error?
    private var _framesWritten: Int64 = 0

    public init(url: URL) { self.url = url }

    public var failure: Error? { lock.withLock { _failure } }
    public var framesWritten: Int64 { lock.withLock { _framesWritten } }
    public var format: AVAudioFormat? { fileFormat }

    public func start(format: AVAudioFormat, track: TrackID) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
            file = f
            fileFormat = f.processingFormat
            FileSecurity.makePrivate(url)
        } catch {
            throw CappyError.io(tr("Cannot create \(url.lastPathComponent): \(error.localizedDescription)", ja: "\(url.lastPathComponent) を作成できません: \(error.localizedDescription)"))
        }
    }

    public func consume(_ buffer: AVAudioPCMBuffer, at hostTime: UInt64) {
        guard let file, let fileFormat, failure == nil, buffer.frameLength > 0 else { return }
        do {
            if buffer.format.isEqual(fileFormat) {
                try file.write(from: buffer)
                lock.withLock { _framesWritten += Int64(buffer.frameLength) }
                return
            }
            // 作り直しで形式が変わった場合（出力デバイスの切替など）は、最初の形式に変換して書く
            if converterInput == nil || !(converterInput!.isEqual(buffer.format)) {
                converter = AVAudioConverter(from: buffer.format, to: fileFormat)
                converterInput = buffer.format
                CappyLog.shared.info(tr("\(url.lastPathComponent): the input format changed; converting before writing ", ja: "\(url.lastPathComponent): 入力形式が変わったため変換して書き込みます ")
                    + "(\(Int(buffer.format.sampleRate))Hz/\(buffer.format.channelCount)ch → "
                    + "\(Int(fileFormat.sampleRate))Hz/\(fileFormat.channelCount)ch)")
            }
            guard let converter else { throw CappyError.io(tr("Cannot create the format converter", ja: "形式変換を作成できません")) }
            let ratio = fileFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var convError: NSError?
            let status = converter.convert(to: out, error: &convError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if status == .error { throw convError ?? CappyError.io(tr("Format conversion failed", ja: "形式変換に失敗しました")) }
            if out.frameLength > 0 {
                try file.write(from: out)
                lock.withLock { _framesWritten += Int64(out.frameLength) }
            }
        } catch {
            lock.withLock { if _failure == nil { _failure = error } }
            CappyLog.shared.error(tr("Failed to write \(url.lastPathComponent): \(error.localizedDescription)", ja: "\(url.lastPathComponent) への書き込みに失敗しました: \(error.localizedDescription)"))
        }
    }

    public func finish() async throws {
        try close()
    }

    /// 同期版の finish
    public func close() throws {
        file?.close()
        file = nil
        FileSecurity.makePrivate(url)
        if let failure { throw CappyError.io(tr("Failed to write \(url.lastPathComponent): \(failure.localizedDescription)", ja: "\(url.lastPathComponent) の書き込みに失敗しました: \(failure.localizedDescription)")) }
    }
}
