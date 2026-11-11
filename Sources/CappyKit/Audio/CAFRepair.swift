import Foundation

/// 異常終了で長さが確定しなかった CAF を読めるように直す。
/// data チャンクのサイズを -1（ファイル末尾まで）にし、端数のバイトを切り詰める。
public enum CAFRepair {
    public struct Report: Sendable, Equatable {
        public var changed: Bool
        public var dataBytes: Int64
        public var truncatedBytes: Int64
    }

    public static func repair(_ url: URL) throws -> Report {
        let fh = try FileHandle(forUpdating: url)
        defer { try? fh.close() }
        let fileSize = Int64(try fh.seekToEnd())
        try fh.seek(toOffset: 0)
        guard let header = try fh.read(upToCount: 8), header.count == 8,
              String(decoding: header.prefix(4), as: UTF8.self) == "caff" else {
            throw CappyError.io("\(url.lastPathComponent) は CAF ファイルではありません")
        }
        var offset: Int64 = 8
        var bytesPerPacket: Int64 = 0
        while offset + 12 <= fileSize {
            try fh.seek(toOffset: UInt64(offset))
            guard let chunkHeader = try fh.read(upToCount: 12), chunkHeader.count == 12 else { break }
            let type = String(decoding: chunkHeader.prefix(4), as: UTF8.self)
            let size = chunkHeader.subdata(in: 4..<12).withUnsafeBytes { Int64(bigEndian: $0.loadUnaligned(as: Int64.self)) }
            let bodyStart = offset + 12
            if type == "desc" {
                if let desc = try fh.read(upToCount: 32), desc.count == 32 {
                    // mSampleRate(8) mFormatID(4) mFormatFlags(4) mBytesPerPacket(4) ...
                    bytesPerPacket = Int64(desc.subdata(in: 16..<20).withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
                }
            }
            if type == "data" {
                // data チャンクの先頭 4 バイトは edit count
                let audioStart = bodyStart + 4
                var audioBytes = fileSize - audioStart
                var truncated: Int64 = 0
                if bytesPerPacket > 0 {
                    truncated = audioBytes % bytesPerPacket
                    audioBytes -= truncated
                }
                let declaredEnd = size == -1 ? fileSize : bodyStart + size
                var changed = false
                if size != -1 && declaredEnd != fileSize - truncated {
                    try fh.seek(toOffset: UInt64(offset + 4))
                    var minusOne = Int64(-1).bigEndian
                    try fh.write(contentsOf: Data(bytes: &minusOne, count: 8))
                    changed = true
                }
                if truncated > 0 {
                    try fh.truncate(atOffset: UInt64(fileSize - truncated))
                    changed = true
                }
                return Report(changed: changed, dataBytes: audioBytes, truncatedBytes: truncated)
            }
            if size < 0 { break }
            offset = bodyStart + size
        }
        throw CappyError.io("\(url.lastPathComponent) に data チャンクがありません")
    }
}
