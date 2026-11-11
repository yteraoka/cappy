import Foundation

/// 画面に出す文言の言語
public enum UILanguage: String, Sendable, CaseIterable {
    case en, ja

    /// "ja" / "ja_JP.UTF-8" / "ja-JP" なら日本語、それ以外は英語
    public static func from(_ value: String?) -> UILanguage? {
        guard let v = value?.trimmingCharacters(in: .whitespaces).lowercased(), !v.isEmpty else { return nil }
        if v == "c" || v == "posix" { return .en }
        return v.hasPrefix("ja") ? .ja : .en
    }

    /// 会議の言語コード（ja-JP など）から、作るファイル（transcript.md・summary.md）の言語を決める
    public static func forDocument(_ languageCode: String) -> UILanguage {
        languageCode.lowercased().hasPrefix("ja") ? .ja : .en
    }
}

/// 文言の切り替え。既定は英語で、CAPPY_LANG → LC_ALL → LC_MESSAGES → LANG の順に見て ja で始まれば日本語にする
public enum L10n {
    /// テストなどで一時的に言語を固定する（タスクローカル）
    @TaskLocal public static var override: UILanguage?

    public static let detected: UILanguage = detect(ProcessInfo.processInfo.environment)

    public static func detect(_ env: [String: String]) -> UILanguage {
        for key in ["CAPPY_LANG", "LC_ALL", "LC_MESSAGES", "LANG"] {
            if let lang = UILanguage.from(env[key]) { return lang }
        }
        return .en
    }

    public static var current: UILanguage { override ?? detected }
}

/// 画面に出す文言。英語と日本語を並べて書き、今の言語のほうを返す
@inline(__always)
public func tr(_ en: @autoclosure () -> String, ja: @autoclosure () -> String) -> String {
    L10n.current == .ja ? ja() : en()
}

/// 言語を指定して選ぶ（作るファイルの文言など）
@inline(__always)
public func tr(_ lang: UILanguage, _ en: @autoclosure () -> String, ja: @autoclosure () -> String) -> String {
    lang == .ja ? ja() : en()
}
