import Foundation

/// 録音中のキー入力（端末から 1 バイトずつ）を解釈する。
///
/// - 何も入力していないときの Space（全角スペースも）: マイクのミュートの切り替え
/// - Enter: マーカー（入力した文字があればラベルにする）
/// - Backspace: 1 文字消す、Ctrl-U: 入力を消す
/// - 矢印キーなどのエスケープシーケンスやその他の制御文字は無視する
public struct KeyInputParser: Sendable {
    public enum Event: Equatable, Sendable {
        case toggleMute
        case marker(label: String?)
        /// 入力中の文字が変わった（表示を更新する）
        case edited
    }

    private enum Escape: Sendable { case none, esc, sequence }

    /// 入力中のラベル
    public private(set) var text = ""
    private var utf8: [UInt8] = []
    private var escape = Escape.none

    public init() {}

    public mutating func feed(_ byte: UInt8) -> Event? {
        switch escape {
        case .esc:
            // ESC [ / ESC O の後に続くシーケンス、それ以外（Alt+キー）は 1 文字で終わり
            escape = (byte == UInt8(ascii: "[") || byte == UInt8(ascii: "O")) ? .sequence : .none
            return nil
        case .sequence:
            if (0x40...0x7E).contains(byte) { escape = .none }
            return nil
        case .none:
            break
        }
        switch byte {
        case 0x1B:
            utf8.removeAll()
            escape = .esc
            return nil
        case 0x0D, 0x0A:
            utf8.removeAll()
            let label = text.trimmingCharacters(in: .whitespaces)
            text = ""
            return .marker(label: label.isEmpty ? nil : label)
        case 0x7F, 0x08:
            utf8.removeAll()
            guard !text.isEmpty else { return nil }
            text.removeLast()
            return .edited
        case 0x15:
            utf8.removeAll()
            guard !text.isEmpty else { return nil }
            text = ""
            return .edited
        case 0x20 where text.isEmpty:
            return .toggleMute
        case 0x00..<0x20:
            return nil
        default:
            return appendUTF8(byte)
        }
    }

    private mutating func appendUTF8(_ byte: UInt8) -> Event? {
        if utf8.isEmpty {
            guard Self.sequenceLength(byte) > 0 else { return nil } // 継続バイトだけが来た
        } else if byte & 0xC0 != 0x80 {
            // 途中で別の文字が始まった（壊れた入力）。前の分は捨てて読み直す
            utf8.removeAll()
            return appendUTF8(byte)
        }
        utf8.append(byte)
        guard utf8.count >= Self.sequenceLength(utf8[0]) else { return nil }
        defer { utf8.removeAll() }
        guard let s = String(validating: utf8, as: UTF8.self) else { return nil }
        if text.isEmpty && s == "\u{3000}" { return .toggleMute } // 日本語入力中の Space
        text += s
        return .edited
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
