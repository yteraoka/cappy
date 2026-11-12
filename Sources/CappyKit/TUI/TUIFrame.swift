import Foundation

/// 画面の各行を端末に書き出すときの、前回との差分を作る。
///
/// ちらつきを抑えるため、次のようにする（#21）。
/// - 前回と変わった行だけを書き直す
/// - 1 回分の書き込みを Synchronized Output（`ESC[?2026h` … `ESC[?2026l`）で囲む（対応していない端末は無視する）
/// - 書いている間はカーソルを隠し、最後に必要なときだけ表示する
/// - 行は右端の 1 桁を空けて描き、`ESC[K` で行末まで消す。表示幅の数え方が端末とずれても、
///   折り返し（呼び出し側で `ESC[?7l` で止める）や前の文字の残りで画面が崩れないようにする
public struct TUIFrameWriter: Sendable {
    public typealias Line = RecordLauncher.Line

    private var previous: [String] = []
    private var previousCursor: Cursor?
    private var previousSize: (Int, Int)?
    /// あいまい幅の記号を ASCII にする（端末であいまい幅の文字を全角で表示している場合）
    public var ascii: Bool

    public struct Cursor: Equatable, Sendable {
        public var row: Int
        public var column: Int
        public init(row: Int, column: Int) {
            self.row = row
            self.column = column
        }
    }

    public init(ascii: Bool = false) {
        self.ascii = ascii
    }

    /// 内容を描く幅（右端の 1 桁を空ける）
    public static func contentWidth(_ terminalWidth: Int) -> Int { max(1, terminalWidth - 1) }

    /// 次の画面を書き出す文字列。前回と同じなら nil
    public mutating func frame(_ lines: [Line], cursor: Cursor?, width: Int, height: Int) -> String? {
        let rows = (0..<max(0, height)).map { i in i < lines.count ? render(lines[i]) : "" }
        let resized = previousSize.map { $0 != (width, height) } ?? true
        var out = ""
        if resized {
            // 大きさが変わったら全体を消して書き直す
            out += "\u{1B}[2J"
            previous = []
        }
        for (i, row) in rows.enumerated() where i >= previous.count || previous[i] != row {
            out += "\u{1B}[\(i + 1);1H" + row + "\u{1B}[0m\u{1B}[K"
        }
        previous = rows
        previousSize = (width, height)
        if out.isEmpty && cursor == previousCursor { return nil }
        previousCursor = cursor
        var frame = "\u{1B}[?2026h\u{1B}[?25l" + out
        if let cursor {
            frame += "\u{1B}[\(cursor.row + 1);\(cursor.column + 1)H\u{1B}[?25h"
        }
        return frame + "\u{1B}[?2026l"
    }

    /// 次は全体を書き直す（端末の画面が別のもので上書きされたときなど）
    public mutating func invalidate() {
        previous = []
        previousSize = nil
        previousCursor = nil
    }

    private func render(_ line: Line) -> String {
        line.segments.map { segment in
            let style: String
            switch segment.style {
            case .normal: style = ""
            case .title, .heading: style = "\u{1B}[1m"
            case .selected: style = "\u{1B}[7m"
            case .dim: style = "\u{1B}[2m"
            }
            let text = ascii ? Self.asciiSymbols(segment.text) : segment.text
            return "\u{1B}[0m" + style + text
        }.joined()
    }

    /// あいまい幅（East Asian Width = A）の記号を、同じ 1 桁の ASCII にする。桁がずれないので配置は変わらない
    public static func asciiSymbols(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { asciiMap[$0] != nil }) else { return s }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars { out.append(asciiMap[u] ?? u) }
        return String(out)
    }

    private static let asciiMap: [Unicode.Scalar: Unicode.Scalar] = [
        "▶": ">", "●": "*", "→": ">", "←": "<", "↑": "^", "↓": "v", "…": "~", "–": "-", "—": "-",
        "─": "-", "│": "|", "┌": "+", "┐": "+", "└": "+", "┘": "+", "‹": "<", "›": ">",
        "▮": "#", "▯": ".", "✓": "v", "✗": "x", "✎": ">",
    ]
}
