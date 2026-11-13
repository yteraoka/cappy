import Foundation

/// 終了コード（docs/usage.ja.md の「終了コード」の表）に対応するエラー分類
public enum ExitStatus: Int32, Sendable {
    case ok = 0
    case usage = 1          // 引数・設定の誤り
    case permission = 2     // 権限不足
    case targetNotFound = 3 // 録音対象のプロセスが見つからない
    case io = 4             // 録音中の I/O エラー
    case transcription = 5  // 文字起こしサービスのエラー
}

public struct CappyError: Error, CustomStringConvertible, Sendable {
    public let status: ExitStatus
    public let message: String
    public let hint: String?

    public init(_ status: ExitStatus, _ message: String, hint: String? = nil) {
        self.status = status
        self.message = message
        self.hint = hint
    }

    public var description: String {
        if let hint { return "\(message)\n\(hint)" }
        return message
    }

    public static func usage(_ m: String, hint: String? = nil) -> CappyError { .init(.usage, m, hint: hint) }
    public static func permission(_ m: String, hint: String? = nil) -> CappyError { .init(.permission, m, hint: hint) }
    public static func targetNotFound(_ m: String, hint: String? = nil) -> CappyError { .init(.targetNotFound, m, hint: hint) }
    public static func io(_ m: String, hint: String? = nil) -> CappyError { .init(.io, m, hint: hint) }
    public static func transcription(_ m: String, hint: String? = nil) -> CappyError { .init(.transcription, m, hint: hint) }
}

/// Core Audio の OSStatus を読みやすい文字列にする（four-char code なら文字で表示）
public func osStatusString(_ status: OSStatus) -> String {
    let u = UInt32(bitPattern: status)
    let bytes = [UInt8((u >> 24) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return "'\(String(decoding: bytes, as: UTF8.self))' (\(status))"
    }
    return "\(status)"
}
