import Foundation

/// AWS のイベントストリーム（application/vnd.amazon.eventstream）の 1 メッセージ。
///
/// 形式: 全体の長さ（4）| ヘッダーの長さ（4）| 前半の CRC32（4）| ヘッダー | 本文 | 全体の CRC32（4）。数値はビッグエンディアン。
/// ヘッダー: 名前の長さ（1）| 名前 | 型（1）| 値
public struct EventStreamMessage: Sendable, Equatable {
    public enum HeaderValue: Sendable, Equatable {
        case bool(Bool)
        case byte(Int8)
        case short(Int16)
        case int(Int32)
        case long(Int64)
        case bytes(Data)
        case string(String)
        case timestamp(Int64)
        case uuid(Data)
    }

    public var headers: [String: HeaderValue]
    public var payload: Data

    public init(headers: [String: HeaderValue], payload: Data) {
        self.headers = headers
        self.payload = payload
    }

    public func string(_ name: String) -> String? {
        if case .string(let s)? = headers[name] { return s }
        return nil
    }

    public enum DecodeError: Error, Equatable {
        case truncated
        case lengthMismatch
        case preludeCRC
        case messageCRC
        case badHeader
    }

    // MARK: 書き出し

    public func encode() -> Data {
        var h = Data()
        // 順序を固定する（テストのため）
        for name in headers.keys.sorted() {
            let n = Data(name.utf8)
            h.append(UInt8(n.count))
            h.append(n)
            switch headers[name]! {
            case .bool(let b): h.append(b ? 0 : 1)
            case .byte(let v): h.append(2); h.append(UInt8(bitPattern: v))
            case .short(let v): h.append(3); h.append(be: UInt16(bitPattern: v))
            case .int(let v): h.append(4); h.append(be: UInt32(bitPattern: v))
            case .long(let v): h.append(5); h.append(be: UInt64(bitPattern: v))
            case .bytes(let d): h.append(6); h.append(be: UInt16(d.count)); h.append(d)
            case .string(let s):
                let d = Data(s.utf8)
                h.append(7); h.append(be: UInt16(d.count)); h.append(d)
            case .timestamp(let v): h.append(8); h.append(be: UInt64(bitPattern: v))
            case .uuid(let d): h.append(9); h.append(d.prefix(16))
            }
        }
        let total = 12 + h.count + payload.count + 4
        var out = Data(capacity: total)
        out.append(be: UInt32(total))
        out.append(be: UInt32(h.count))
        out.append(be: CRC32.checksum(out))
        out.append(h)
        out.append(payload)
        out.append(be: CRC32.checksum(out))
        return out
    }

    // MARK: 読み込み

    public static func decode(_ data: Data) throws -> EventStreamMessage {
        let b = [UInt8](data)
        guard b.count >= 16 else { throw DecodeError.truncated }
        let total = Int(readU32(b, 0))
        let headerLength = Int(readU32(b, 4))
        guard total == b.count, 12 + headerLength + 4 <= total else { throw DecodeError.lengthMismatch }
        guard CRC32.checksum(Data(b[0..<8])) == readU32(b, 8) else { throw DecodeError.preludeCRC }
        guard CRC32.checksum(Data(b[0..<(total - 4)])) == readU32(b, total - 4) else { throw DecodeError.messageCRC }
        var headers: [String: HeaderValue] = [:]
        var p = 12
        let end = 12 + headerLength
        func need(_ n: Int) throws { if p + n > end { throw DecodeError.badHeader } }
        while p < end {
            try need(1)
            let nameLength = Int(b[p]); p += 1
            try need(nameLength + 1)
            let name = String(decoding: b[p..<(p + nameLength)], as: UTF8.self); p += nameLength
            let type = b[p]; p += 1
            let value: HeaderValue
            switch type {
            case 0: value = .bool(true)
            case 1: value = .bool(false)
            case 2: try need(1); value = .byte(Int8(bitPattern: b[p])); p += 1
            case 3: try need(2); value = .short(Int16(bitPattern: UInt16(b[p]) << 8 | UInt16(b[p + 1]))); p += 2
            case 4: try need(4); value = .int(Int32(bitPattern: readU32(b, p))); p += 4
            case 5, 8:
                try need(8)
                let v = Int64(bitPattern: UInt64(readU32(b, p)) << 32 | UInt64(readU32(b, p + 4)))
                value = type == 5 ? .long(v) : .timestamp(v)
                p += 8
            case 6, 7:
                try need(2)
                let n = Int(UInt16(b[p]) << 8 | UInt16(b[p + 1])); p += 2
                try need(n)
                let d = Data(b[p..<(p + n)]); p += n
                value = type == 6 ? .bytes(d) : .string(String(decoding: d, as: UTF8.self))
            case 9: try need(16); value = .uuid(Data(b[p..<(p + 16)])); p += 16
            default: throw DecodeError.badHeader
            }
            headers[name] = value
        }
        return EventStreamMessage(headers: headers, payload: Data(b[end..<(total - 4)]))
    }

    static func readU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(be value: T) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

/// CRC-32（IEEE 802.3、zlib と同じ）
public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
