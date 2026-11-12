import Foundation

/// 選択肢を枠で囲んだ小さなウィンドウにして、画面の行に重ねて描く
public enum TUIMenuBox {
    public typealias Line = RecordLauncher.Line

    /// - Parameters:
    ///   - current: ✓ を付ける位置（今の値。なければ nil）
    ///   - selected: 反転して見せる位置
    ///   - belowRow: この行のすぐ下に出す（下に収まらなければ上にずらす）
    ///   - textColumn: 選択肢の文字を始める桁（枠と「 ✓ 」の分だけ左から枠を描く）
    ///   - title: 上の枠に入れる見出し（確認の問いかけなど）
    public static func overlay(options: [String], current: Int?, selected: Int, belowRow: Int, textColumn: Int,
                               title: String? = nil, on lines: inout [Line], width: Int, height: Int) {
        typealias Segment = Line.Segment
        guard !options.isEmpty else { return }
        // 収まらなければ枠の中でスクロールする
        let rows = min(options.count, max(1, min(lines.count, height) - 3))
        let first = min(max(0, selected - rows / 2), options.count - rows)
        // 枠の内側は「 ✓ 」+ 選択肢 + 「 」
        let titleWidth = title.map { DisplayWidth.of($0) + 4 } ?? 0
        let inner = min(max((options.map { DisplayWidth.of($0) }.max() ?? 0) + 4, titleWidth), width - 2)
        let boxWidth = inner + 2
        let column = max(0, min(textColumn - 4, width - boxWidth))
        var top = belowRow + 1
        if top + rows + 2 > lines.count { top = max(0, lines.count - rows - 2) }

        var box: [[Segment]] = []
        if let title {
            let t = DisplayWidth.fit(" " + title + " ", min(inner - 1, DisplayWidth.of(title) + 2))
            box.append([Segment(text: "┌─", style: .normal), Segment(text: t, style: .heading),
                        Segment(text: String(repeating: "─", count: max(0, inner - 1 - DisplayWidth.of(t))) + "┐", style: .normal)])
        } else {
            box.append([Segment(text: "┌" + String(repeating: "─", count: inner) + "┐", style: .normal)])
        }
        for j in first..<(first + rows) {
            let label = DisplayWidth.fit((j == current ? " ✓ " : "   ") + options[j] + " ", inner)
            box.append([Segment(text: "│", style: .normal),
                        Segment(text: label, style: j == selected ? .selected : .normal),
                        Segment(text: "│", style: .normal)])
        }
        if first > 0 || first + rows < options.count {
            let info = " \(selected + 1)/\(options.count) "
            let left = max(0, inner - DisplayWidth.of(info) - 1)
            box.append([Segment(text: "└" + String(repeating: "─", count: left) + info
                                + String(repeating: "─", count: max(0, inner - left - DisplayWidth.of(info))) + "┘", style: .normal)])
        } else {
            box.append([Segment(text: "└" + String(repeating: "─", count: inner) + "┘", style: .normal)])
        }
        for (k, parts) in box.enumerated() where lines.indices.contains(top + k) {
            lines[top + k].overlay(parts, at: column, width: width)
        }
    }
}
