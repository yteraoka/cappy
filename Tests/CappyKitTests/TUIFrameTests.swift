import Foundation
import Testing
@testable import CappyKit

@Suite struct TUIFrameTests {
    private typealias Line = RecordLauncher.Line

    private func lines(_ texts: [String]) -> [Line] { texts.map { Line(text: $0, style: .normal) } }

    /// 出力から、書き直した行の番号（1 始まり）を取り出す
    private func rewrittenRows(_ frame: String) -> [Int] {
        let pattern = try! NSRegularExpression(pattern: "\u{1B}\\[(\\d+);1H")
        return pattern.matches(in: frame, range: NSRange(frame.startIndex..., in: frame)).compactMap {
            Range($0.range(at: 1), in: frame).flatMap { Int(frame[$0]) }
        }
    }

    @Test func rewritesOnlyChangedRows() {
        var w = TUIFrameWriter()
        let first = w.frame(lines(["a", "b", "c"]), cursor: nil, width: 10, height: 3)!
        #expect(first.hasPrefix("\u{1B}[?2026h\u{1B}[?25l\u{1B}[2J")) // 初回は全体を消して書く
        #expect(first.hasSuffix("\u{1B}[?2026l"))
        #expect(rewrittenRows(first) == [1, 2, 3])

        // 変わらなければ何も書かない
        #expect(w.frame(lines(["a", "b", "c"]), cursor: nil, width: 10, height: 3) == nil)

        // 2 行目だけ変わった
        let second = w.frame(lines(["a", "B", "c"]), cursor: nil, width: 10, height: 3)!
        #expect(rewrittenRows(second) == [2])
        #expect(!second.contains("\u{1B}[2J"))
        #expect(second.contains("B\u{1B}[0m\u{1B}[K")) // 行末まで消す

        // カーソルだけ変わった: 行は書かず、カーソルを動かして表示する
        let cursor = w.frame(lines(["a", "B", "c"]), cursor: .init(row: 1, column: 4), width: 10, height: 3)!
        #expect(rewrittenRows(cursor).isEmpty)
        #expect(cursor.contains("\u{1B}[2;5H\u{1B}[?25h"))
        // 次の描画では最初にカーソルを隠す
        let hidden = w.frame(lines(["a", "b", "c"]), cursor: nil, width: 10, height: 3)!
        #expect(hidden.hasPrefix("\u{1B}[?2026h\u{1B}[?25l"))
        #expect(!hidden.contains("\u{1B}[?25h"))

        // 大きさが変わったら全体を書き直す
        let resized = w.frame(lines(["a", "b", "c"]), cursor: nil, width: 12, height: 3)!
        #expect(resized.contains("\u{1B}[2J"))
        #expect(rewrittenRows(resized) == [1, 2, 3])
    }

    @Test func asciiReplacesAmbiguousSymbolsWithoutChangingWidth() {
        let s = "▶ ● 録音 → 文字起こし ┌─┐│└┘ … ✓ ✗"
        let a = TUIFrameWriter.asciiSymbols(s)
        #expect(a == "> * 録音 > 文字起こし +-+|++ ~ v x")
        #expect(DisplayWidth.of(a) == DisplayWidth.of(s))
        #expect(TUIFrameWriter.asciiSymbols("abc 日本") == "abc 日本")
        var w = TUIFrameWriter(ascii: true)
        #expect(w.frame(lines(["▶ ok"]), cursor: nil, width: 10, height: 1)!.contains("> ok"))
    }

    @Test func emojiAndCombiningWidths() {
        #expect(DisplayWidth.of("⚠️") == 2)           // U+26A0 U+FE0F は絵文字として 2 桁
        #expect(DisplayWidth.of("⚠") == 1)            // U+FE0F がなければ 1 桁
        #expect(DisplayWidth.of("🔇💬") == 4)
        #expect(DisplayWidth.of("👍🏽") == 2)            // 肌の色の修飾も 1 文字
        #expect(DisplayWidth.of("か\u{3099}") == 2)    // 濁点を結合した「が」
        #expect(DisplayWidth.of("e\u{301}") == 1)
        #expect(DisplayWidth.fit("⚠️  録音", 8) == "⚠️  録音")
        #expect(DisplayWidth.of(DisplayWidth.fit("⚠️  録音は参加者への告知", 12)) == 12)
    }

    /// #21: ⚠️ を含むメッセージがあっても、各行は描く幅に収まる
    @Test func recordingScreenWithEmojiFitsTheWidth() {
        let screen = RecordingScreen(title: "● 録音中", details: [("録音対象", "zoom.us")], status: "● 録音中 00:00:05  自分 🔇ミュート  💬 相手: こんにちは",
                                     log: ["⚠️  録音は参加者への告知と同意を得たうえで行ってください。"], help: "Ctrl-C: 停止して保存")
        let width = TUIFrameWriter.contentWidth(90)
        let lines = screen.render(width: width, height: 20)
        #expect(lines.allSatisfy { DisplayWidth.of($0.text) == width })
        #expect(lines.contains { $0.text.contains("⚠️  録音は参加者") })
    }
}
