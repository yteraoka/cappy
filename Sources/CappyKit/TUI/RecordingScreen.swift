import Foundation

/// `cappy tui` の録音中の画面（選んだ内容、ステータス行、メッセージ、キーの案内）
public struct RecordingScreen: Sendable {
    public typealias Line = RecordLauncher.Line

    public var title: String
    public var details: [(label: String, value: String)]
    /// 録音中のレベルメーターや、文字起こしの進み具合（Console.status の内容）
    public var status: String?
    /// これまでのメッセージ（Console.print の内容）
    public var log: [String]
    public var help: String

    public init(title: String, details: [(label: String, value: String)], status: String?, log: [String], help: String) {
        self.title = title
        self.details = details
        self.status = status
        self.log = log
        self.help = help
    }

    /// 画面の各行（幅に合わせて切り詰め・空白埋め済み）。メッセージは折り返し、入りきらなければ新しいものを残す
    public func render(width: Int, height: Int) -> [Line] {
        let w = max(20, width)
        var lines: [Line] = []
        func add(_ s: String, _ style: Line.Style = .normal) { lines.append(Line(text: DisplayWidth.fit(s, w), style: style)) }

        add(" cappy — " + title, .title)
        add("")
        let labelWidth = details.map { DisplayWidth.of($0.label) }.max() ?? 0
        for d in details {
            add("   " + d.label + String(repeating: " ", count: labelWidth - DisplayWidth.of(d.label)) + "  " + d.value)
        }
        add("")
        // 長いもの（エラーなど）は折り返す。録音中のステータスは 1 行に収まる長さ
        for l in DisplayWidth.wrap(status ?? "", w - 1).prefix(3) { add(" " + l, .heading) }
        add(String(repeating: "─", count: w), .dim)

        let footer = 2
        let room = max(1, height - lines.count - footer)
        let wrapped = log.flatMap { DisplayWidth.wrap($0, w - 1) }
        for l in wrapped.suffix(room) { add(" " + l) }
        while lines.count < height - footer { add("") }
        add("")
        add(" " + help, .dim)
        return Array(lines.prefix(max(height, 1)))
    }
}
