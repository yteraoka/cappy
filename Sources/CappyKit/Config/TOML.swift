import Foundation

/// 設定ファイル用の最小限の TOML パーサ。
/// 対応: テーブル（[a.b]）、ドット区切りキー、文字列（基本・リテラル）、整数、浮動小数、真偽値、配列、コメント。
/// 非対応: 複数行文字列、インラインテーブル、テーブル配列、日時。
public indirect enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var int: Int64? {
        switch self {
        case .integer(let i): return i
        case .float(let d): return Int64(d)
        default: return nil
        }
    }
    public var double: Double? {
        switch self {
        case .integer(let i): return Double(i)
        case .float(let d): return d
        default: return nil
        }
    }
    public var table: [String: TOMLValue]? { if case .table(let t) = self { return t }; return nil }
    public var array: [TOMLValue]? { if case .array(let a) = self { return a }; return nil }

    public subscript(key: String) -> TOMLValue? { table?[key] }
}

public struct TOMLError: Error, CustomStringConvertible {
    public let line: Int
    public let message: String
    public var description: String { "TOML の \(line) 行目: \(message)" }
}

public enum TOML {
    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        var root: [String: TOMLValue] = [:]
        var currentPath: [String] = []
        var lineNo = 0
        for rawLine in text.components(separatedBy: .newlines) {
            lineNo += 1
            var scanner = Scanner(chars: Array(rawLine), line: lineNo)
            scanner.skipWhitespace()
            if scanner.atEnd || scanner.peek == "#" { continue }
            if scanner.peek == "[" {
                scanner.advance()
                if scanner.peek == "[" { throw TOMLError(line: lineNo, message: "テーブル配列 [[...]] には対応していません") }
                let path = try scanner.parseKeyPath()
                scanner.skipWhitespace()
                guard scanner.peek == "]" else { throw TOMLError(line: lineNo, message: "] がありません") }
                scanner.advance()
                try scanner.expectLineEnd()
                currentPath = path
                try ensureTable(&root, path, line: lineNo)
                continue
            }
            let keyPath = try scanner.parseKeyPath()
            scanner.skipWhitespace()
            guard scanner.peek == "=" else { throw TOMLError(line: lineNo, message: "= がありません") }
            scanner.advance()
            scanner.skipWhitespace()
            let value = try scanner.parseValue()
            try scanner.expectLineEnd()
            try setValue(&root, currentPath + keyPath, value, line: lineNo)
        }
        return root
    }

    private static func ensureTable(_ root: inout [String: TOMLValue], _ path: [String], line: Int) throws {
        guard let first = path.first else { return }
        var child = root[first]?.table ?? [:]
        if let existing = root[first], existing.table == nil {
            throw TOMLError(line: line, message: "\(first) はテーブルではありません")
        }
        try ensureTable(&child, Array(path.dropFirst()), line: line)
        root[first] = .table(child)
    }

    private static func setValue(_ root: inout [String: TOMLValue], _ path: [String], _ value: TOMLValue, line: Int) throws {
        guard let first = path.first else { return }
        if path.count == 1 {
            if root[first] != nil { throw TOMLError(line: line, message: "キー \(first) が重複しています") }
            root[first] = value
            return
        }
        if let existing = root[first], existing.table == nil {
            throw TOMLError(line: line, message: "\(first) はテーブルではありません")
        }
        var child = root[first]?.table ?? [:]
        try setValue(&child, Array(path.dropFirst()), value, line: line)
        root[first] = .table(child)
    }

    private struct Scanner {
        let chars: [Character]
        let line: Int
        var pos = 0

        init(chars: [Character], line: Int) {
            self.chars = chars
            self.line = line
        }

        var atEnd: Bool { pos >= chars.count }
        var peek: Character? { atEnd ? nil : chars[pos] }
        mutating func advance() { pos += 1 }

        mutating func skipWhitespace() {
            while let c = peek, c == " " || c == "\t" { advance() }
        }

        mutating func expectLineEnd() throws {
            skipWhitespace()
            if atEnd || peek == "#" { return }
            throw TOMLError(line: line, message: "行末に余分な文字があります")
        }

        mutating func parseKeyPath() throws -> [String] {
            var parts: [String] = []
            while true {
                skipWhitespace()
                parts.append(try parseKey())
                skipWhitespace()
                if peek == "." { advance(); continue }
                return parts
            }
        }

        mutating func parseKey() throws -> String {
            if peek == "\"" { return try parseBasicString() }
            if peek == "'" { return try parseLiteralString() }
            var key = ""
            while let c = peek, c.isLetter || c.isNumber || c == "_" || c == "-" {
                key.append(c)
                advance()
            }
            guard !key.isEmpty else { throw TOMLError(line: line, message: "キーがありません") }
            return key
        }

        mutating func parseValue() throws -> TOMLValue {
            guard let c = peek else { throw TOMLError(line: line, message: "値がありません") }
            switch c {
            case "\"": return .string(try parseBasicString())
            case "'": return .string(try parseLiteralString())
            case "[": return try parseArray()
            case "{": throw TOMLError(line: line, message: "インラインテーブルには対応していません")
            default: return try parseScalar()
            }
        }

        mutating func parseArray() throws -> TOMLValue {
            advance() // [
            var items: [TOMLValue] = []
            while true {
                skipWhitespace()
                if peek == "]" { advance(); return .array(items) }
                items.append(try parseValue())
                skipWhitespace()
                if peek == "," { advance(); continue }
                if peek == "]" { advance(); return .array(items) }
                throw TOMLError(line: line, message: "配列の区切りが不正です（複数行の配列には対応していません）")
            }
        }

        mutating func parseScalar() throws -> TOMLValue {
            var token = ""
            while let c = peek, c != " ", c != "\t", c != ",", c != "]", c != "#" {
                token.append(c)
                advance()
            }
            switch token {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: break
            }
            let cleaned = token.replacingOccurrences(of: "_", with: "")
            if let i = Int64(cleaned) { return .integer(i) }
            if let d = Double(cleaned) { return .float(d) }
            throw TOMLError(line: line, message: "値を解釈できません: \(token)")
        }

        mutating func parseBasicString() throws -> String {
            advance() // "
            var out = ""
            while let c = peek {
                advance()
                if c == "\"" { return out }
                if c == "\\" {
                    guard let e = peek else { break }
                    advance()
                    switch e {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "\\": out.append("\\")
                    case "\"": out.append("\"")
                    case "u", "U":
                        let len = e == "u" ? 4 : 8
                        var hex = ""
                        for _ in 0..<len {
                            guard let h = peek else { break }
                            hex.append(h)
                            advance()
                        }
                        guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                            throw TOMLError(line: line, message: "不正なエスケープ \\\(e)\(hex)")
                        }
                        out.unicodeScalars.append(scalar)
                    default:
                        throw TOMLError(line: line, message: "不正なエスケープ \\\(e)")
                    }
                    continue
                }
                out.append(c)
            }
            throw TOMLError(line: line, message: "文字列が閉じていません")
        }

        mutating func parseLiteralString() throws -> String {
            advance() // '
            var out = ""
            while let c = peek {
                advance()
                if c == "'" { return out }
                out.append(c)
            }
            throw TOMLError(line: line, message: "文字列が閉じていません")
        }
    }
}
