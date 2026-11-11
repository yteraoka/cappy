import AVFoundation
import Foundation

/// 送信用ファイル（16 kHz・モノラル・16 bit の FLAC、不可なら WAV）への変換、ミックス、分割
public enum SendFileConverter {
    public static let sampleRate: Double = 16_000

    public enum Container: String, Sendable {
        case flac, wav
        public var fileExtension: String { rawValue }
        public var mimeType: String { self == .flac ? "audio/flac" : "audio/wav" }
    }

    static var outputFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    }

    static func settings(_ c: Container) -> [String: Any] {
        switch c {
        case .flac:
            return [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                    AVEncoderBitDepthHintKey: 16]
        case .wav:
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false]
        }
    }

    /// 送信用の出力ファイルを開く（FLAC を試し、だめなら WAV）
    static func openOutput(base: URL, preferred: Container = .flac) throws -> (AVAudioFile, URL, Container) {
        var lastError: Error?
        for c in preferred == .flac ? [Container.flac, .wav] : [.wav] {
            let url = base.deletingPathExtension().appendingPathExtension(c.fileExtension)
            try? FileManager.default.removeItem(at: url)
            do {
                let f = try AVAudioFile(forWriting: url, settings: settings(c), commonFormat: .pcmFormatInt16, interleaved: true)
                FileSecurity.makePrivate(url)
                return (f, url, c)
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: url)
                CappyLog.shared.warning(tr("Cannot write \(c.rawValue); trying the next format: \(error.localizedDescription)", ja: "\(c.rawValue) で書き出せないため次の形式を試します: \(error.localizedDescription)"))
            }
        }
        throw CappyError.io(tr("Cannot create the file to send: \(lastError?.localizedDescription ?? "")", ja: "送信用ファイルを作成できません: \(lastError?.localizedDescription ?? "")"))
    }

    public struct Result: Sendable {
        public var url: URL
        public var container: Container
        public var frames: Int64
        public var durationMs: Int64 { Int64((Double(frames) / SendFileConverter.sampleRate * 1000).rounded()) }
    }

    /// CAF（任意の形式）→ 16 kHz・モノラル・16 bit
    public static func convert(input: URL, outputBase: URL, preferred: Container = .flac) throws -> Result {
        let inFile: AVAudioFile
        do {
            inFile = try AVAudioFile(forReading: input)
        } catch {
            throw CappyError.io(tr("Cannot read \(input.lastPathComponent): \(error.localizedDescription)", ja: "\(input.lastPathComponent) を読めません: \(error.localizedDescription)"),
                                hint: tr("Try repairing it with `cappy recover`", ja: "`cappy recover` で修復を試してください"))
        }
        let (outFile, outURL, container) = try openOutput(base: outputBase, preferred: preferred)
        let inFormat = inFile.processingFormat
        guard let converter = AVAudioConverter(from: inFormat, to: outputFormat) else {
            throw CappyError.io(tr("Cannot create the format converter (\(inFormat))", ja: "形式変換を作成できません（\(inFormat)）"))
        }
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let inCapacity: AVAudioFrameCount = 32_768
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inCapacity),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                            frameCapacity: AVAudioFrameCount(Double(inCapacity) * sampleRate / inFormat.sampleRate) + 1024)
        else { throw CappyError.io(tr("Cannot allocate a buffer", ja: "バッファを確保できません")) }

        var readError: Error?
        var eof = false
        var written: Int64 = 0
        while true {
            outBuf.frameLength = 0
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, inputStatus in
                if eof {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inFile.framePosition >= inFile.length {
                    eof = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try inFile.read(into: inBuf, frameCount: inCapacity)
                } catch {
                    readError = error
                    eof = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    eof = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuf
            }
            if status == .error {
                throw CappyError.io(tr("Format conversion failed: \(convError?.localizedDescription ?? "")", ja: "形式変換に失敗しました: \(convError?.localizedDescription ?? "")"))
            }
            if outBuf.frameLength > 0 {
                do {
                    try outFile.write(from: outBuf)
                } catch {
                    throw CappyError.io(tr("Cannot write \(outURL.lastPathComponent): \(error.localizedDescription)", ja: "\(outURL.lastPathComponent) に書き込めません: \(error.localizedDescription)"))
                }
                written += Int64(outBuf.frameLength)
            }
            if status == .endOfStream || (eof && outBuf.frameLength == 0) { break }
        }
        outFile.close()
        if let readError {
            // 末尾が壊れていても、読めたところまでで送信用ファイルを作る
            CappyLog.shared.warning(tr("Could not read the end of \(input.lastPathComponent): \(readError.localizedDescription)", ja: "\(input.lastPathComponent) の末尾を読めませんでした: \(readError.localizedDescription)"))
        }
        FileSecurity.makePrivate(outURL)
        return Result(url: outURL, container: container, frames: written)
    }

    /// 2 本の送信用ファイル（16 kHz モノラル）をミックスして 1 本にする
    public static func mix(inputs: [(url: URL, offsetMs: Int64)], outputBase: URL, preferred: Container = .flac) throws -> Result {
        let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        var files: [(AVAudioFile, Int64)] = []
        for input in inputs {
            let f = try AVAudioFile(forReading: input.url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard f.processingFormat.sampleRate == sampleRate, f.processingFormat.channelCount == 1 else {
                throw CappyError.io(tr("\(input.url.lastPathComponent) is not 16 kHz mono", ja: "\(input.url.lastPathComponent) は 16 kHz モノラルではありません"))
            }
            files.append((f, Int64(Double(input.offsetMs) / 1000 * sampleRate)))
        }
        let total = files.map { $0.1 + $0.0.length }.max() ?? 0
        let (outFile, outURL, container) = try openOutput(base: outputBase, preferred: preferred)
        let chunk: AVAudioFrameCount = 16_000
        guard let acc = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: chunk),
              let tmp = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: chunk),
              let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: chunk)
        else { throw CappyError.io(tr("Cannot allocate a buffer", ja: "バッファを確保できません")) }

        var pos: Int64 = 0
        while pos < total {
            let n = AVAudioFrameCount(min(Int64(chunk), total - pos))
            let a = acc.floatChannelData![0]
            for i in 0..<Int(n) { a[i] = 0 }
            for (file, offset) in files {
                // このチャンク [pos, pos+n) とファイルの区間 [offset, offset+length) の重なり
                let start = max(pos, offset)
                let end = min(pos + Int64(n), offset + file.length)
                guard end > start else { continue }
                file.framePosition = start - offset
                try file.read(into: tmp, frameCount: AVAudioFrameCount(end - start))
                let t = tmp.floatChannelData![0]
                let base = Int(start - pos)
                for i in 0..<Int(tmp.frameLength) { a[base + i] += t[i] }
            }
            let o = out.int16ChannelData![0]
            for i in 0..<Int(n) {
                let v = max(-1, min(1, a[i]))
                o[i] = Int16((v * 32767).rounded())
            }
            out.frameLength = n
            try outFile.write(from: out)
            pos += Int64(n)
        }
        outFile.close()
        FileSecurity.makePrivate(outURL)
        return Result(url: outURL, container: container, frames: total)
    }

    public struct Chunk: Sendable, Equatable {
        public var url: URL
        public var offsetMs: Int64
        public var durationMs: Int64
    }

    /// 送信用ファイルを maxSeconds ごとに分割する（1 本に収まるなら元ファイルをそのまま返す）
    public static func split(_ input: URL, maxSeconds: TimeInterval, into directory: URL) throws -> [Chunk] {
        let file = try AVAudioFile(forReading: input, commonFormat: .pcmFormatInt16, interleaved: true)
        let rate = file.processingFormat.sampleRate
        let maxFrames = Int64(maxSeconds * rate)
        let totalMs = Int64(Double(file.length) / rate * 1000)
        if file.length <= maxFrames {
            return [Chunk(url: input, offsetMs: 0, durationMs: totalMs)]
        }
        try FileSecurity.createPrivateDirectory(directory)
        let container: Container = input.pathExtension.lowercased() == "flac" ? .flac : .wav
        let stem = input.deletingPathExtension().lastPathComponent
        var chunks: [Chunk] = []
        let bufFrames: AVAudioFrameCount = 65_536
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: bufFrames) else {
            throw CappyError.io(tr("Cannot allocate a buffer", ja: "バッファを確保できません"))
        }
        var index = 0
        var start: Int64 = 0
        while start < file.length {
            let length = min(maxFrames, file.length - start)
            let base = directory.appendingPathComponent(String(format: "%@-%03d", stem, index))
            let (out, url, _) = try openOutput(base: base, preferred: container)
            file.framePosition = start
            var remaining = length
            while remaining > 0 {
                try file.read(into: buf, frameCount: AVAudioFrameCount(min(Int64(bufFrames), remaining)))
                if buf.frameLength == 0 { break }
                try out.write(from: buf)
                remaining -= Int64(buf.frameLength)
            }
            out.close()
            chunks.append(Chunk(url: url,
                                offsetMs: Int64(Double(start) / rate * 1000),
                                durationMs: Int64(Double(length) / rate * 1000)))
            start += length
            index += 1
        }
        return chunks
    }

    /// 音声ファイルの長さ（ms）
    public static func durationMs(of url: URL) -> Int64? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        return Int64(Double(f.length) / f.fileFormat.sampleRate * 1000)
    }
}
