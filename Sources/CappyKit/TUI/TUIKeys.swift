import Foundation

/// TUI のキー
public enum TUIKey: Equatable, Sendable {
    case up, down, left, right
    case pageUp, pageDown, home, end
    case enter, tab, backTab
    case backspace
    /// Ctrl-U（入力を消す）
    case clearLine
    /// Ctrl-C
    case interrupt
    /// ESC 単独
    case escape
    /// 文字の入力（UTF-8 の 1 文字）
    case char(String)
}

/// 端末から 1 バイトずつ読んだ入力を TUIKey にする（raw モード: ICANON・ECHO・ISIG なし）
///
/// ESC は矢印キーなどのシーケンスの始まりでもあるため、続くバイトが来なければ呼び出し側が
/// 少し待ってから `timeout()` を呼び、ESC 単独として扱う。
public struct TUIKeyParser: Sendable {
    private enum State: Sendable { case none, esc, csi, ss3 }

    private var state = State.none
    private var params: [UInt8] = []
    private var utf8: [UInt8] = []

    public init() {}

    /// ESC の続きを待っているか
    public var awaitingEscape: Bool { state == .esc }

    public mutating func feed(_ byte: UInt8) -> TUIKey? {
        switch state {
        case .esc:
            switch byte {
            case UInt8(ascii: "["): state = .csi; params.removeAll(); return nil
            case UInt8(ascii: "O"): state = .ss3; return nil
            case 0x1B: return .escape // ESC ESC: 前の ESC は単独、今の ESC で待ち直す
            default: state = .none; return nil // Alt+キーは無視する
            }
        case .csi:
            guard (0x40...0x7E).contains(byte) else {
                params.append(byte)
                return nil
            }
            state = .none
            // 修飾キー付き（ESC [ 1 ; 5 A など）も同じ矢印として扱う
            switch byte {
            case UInt8(ascii: "A"): return .up
            case UInt8(ascii: "B"): return .down
            case UInt8(ascii: "C"): return .right
            case UInt8(ascii: "D"): return .left
            case UInt8(ascii: "Z"): return .backTab
            case UInt8(ascii: "H"): return .home
            case UInt8(ascii: "F"): return .end
            case UInt8(ascii: "~"):
                switch String(decoding: params, as: UTF8.self) {
                case "3": return .backspace // Delete キー
                case "5": return .pageUp
                case "6": return .pageDown
                case "1", "7": return .home
                case "4", "8": return .end
                default: return nil
                }
            default: return nil
            }
        case .ss3:
            state = .none
            switch byte {
            case UInt8(ascii: "A"): return .up
            case UInt8(ascii: "B"): return .down
            case UInt8(ascii: "C"): return .right
            case UInt8(ascii: "D"): return .left
            case UInt8(ascii: "H"): return .home
            case UInt8(ascii: "F"): return .end
            default: return nil
            }
        case .none:
            break
        }
        switch byte {
        case 0x1B:
            utf8.removeAll()
            state = .esc
            return nil
        case 0x0D, 0x0A: utf8.removeAll(); return .enter
        case 0x09: utf8.removeAll(); return .tab
        case 0x7F, 0x08: utf8.removeAll(); return .backspace
        case 0x15: utf8.removeAll(); return .clearLine
        case 0x03: utf8.removeAll(); return .interrupt
        case 0x10: return .up   // Ctrl-P
        case 0x0E: return .down // Ctrl-N
        case 0x00..<0x20: return nil
        default: return appendUTF8(byte)
        }
    }

    /// ESC の後に続きが来なかった
    public mutating func timeout() -> TUIKey? {
        guard state == .esc else { return nil }
        state = .none
        return .escape
    }

    private mutating func appendUTF8(_ byte: UInt8) -> TUIKey? {
        if utf8.isEmpty {
            guard Self.sequenceLength(byte) > 0 else { return nil }
        } else if byte & 0xC0 != 0x80 {
            utf8.removeAll()
            return appendUTF8(byte)
        }
        utf8.append(byte)
        guard utf8.count >= Self.sequenceLength(utf8[0]) else { return nil }
        defer { utf8.removeAll() }
        return String(validating: utf8, as: UTF8.self).map(TUIKey.char)
    }

    private static func sequenceLength(_ lead: UInt8) -> Int {
        switch lead {
        case 0x00..<0x80: return 1
        case 0xC2..<0xE0: return 2
        case 0xE0..<0xF0: return 3
        case 0xF0..<0xF5: return 4
        default: return 0
        }
    }
}

/// 端末での表示幅（東アジアの文字と絵文字を 2 桁として数える）
public enum DisplayWidth {
    public static func of(_ s: String) -> Int {
        s.reduce(0) { $0 + of($1) }
    }

    /// 1 文字（書記素クラスタ）の幅。端末は 1 文字を基本の文字の幅で描き、結合文字（濁点・アクセントなど）は重ねる。
    /// 絵文字として表示するもの（U+FE0F 付きの ⚠️、🔇 など）は 2 桁
    public static func of(_ c: Character) -> Int {
        let scalars = c.unicodeScalars
        guard let first = scalars.first else { return 0 }
        if scalars.contains(where: { $0.value == 0xFE0F }) || first.properties.isEmojiPresentation { return 2 }
        return of(first)
    }

    public static func of(_ u: Unicode.Scalar) -> Int {
        let v = u.value
        if v == 0xFE0F || v == 0x200D || (0x0300...0x036F).contains(v) || v == 0x3099 || v == 0x309A { return 0 }
        let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v)
        return wide ? 2 : 1
    }

    /// 表示上の桁 [from, to) の部分を切り出す（全角文字が境界にかかれば、その分は空白にする）
    public static func slice(_ s: String, from: Int, to: Int) -> String {
        guard to > from else { return "" }
        var out = ""
        var col = 0
        for ch in s {
            let cw = of(ch)
            defer { col += cw }
            if col >= to { break }
            if col + cw <= from { continue }
            if col >= from && col + cw <= to {
                out.append(ch)
            } else {
                out += String(repeating: " ", count: min(col + cw, to) - max(col, from))
            }
        }
        let w = of(out)
        return w < to - from ? out + String(repeating: " ", count: to - from - w) : out
    }

    /// 表示幅 width ごとに折り返す（改行でも分ける）
    public static func wrap(_ s: String, _ width: Int) -> [String] {
        guard width > 0 else { return [] }
        var result: [String] = []
        for part in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            var w = 0
            for ch in part {
                let cw = of(ch)
                if w + cw > width {
                    result.append(line)
                    line = ""
                    w = 0
                }
                line.append(ch)
                w += cw
            }
            result.append(line)
        }
        return result
    }

    /// 表示幅 width に収まるよう末尾を切り、足りなければ空白で埋める
    public static func fit(_ s: String, _ width: Int) -> String {
        guard width > 0 else { return "" }
        var out = ""
        var w = 0
        if of(s) <= width {
            return s + String(repeating: " ", count: width - of(s))
        }
        for ch in s {
            let cw = of(ch)
            if w + cw > width - 1 { break }
            out.append(ch)
            w += cw
        }
        out += "…"
        w += 1
        return out + String(repeating: " ", count: max(0, width - w))
    }
}
