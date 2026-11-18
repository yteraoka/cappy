import CappyKit
import Foundation

/// メニューで選んだ録音の設定（UserDefaults に保存する）
final class Preferences {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let profile = "profile"
        static let operation = "operation"
        static let mic = "mic"
        static let duration = "duration"
        static let askName = "askName"
        static let lastTarget = "lastTarget"
    }

    init() {
        defaults.register(defaults: [Key.askName: true, Key.mic: "on"])
    }

    /// プロファイル名（nil なら default）
    var profileName: String? {
        get { defaults.string(forKey: Key.profile) }
        set { defaults.set(newValue, forKey: Key.profile) }
    }

    /// 録音の後に何をするか（プロファイルで使えなければ、そのプロファイルの既定）
    func operation(for profile: Profile) -> LaunchOperation {
        let available = LaunchOperation.available(for: profile)
        if let raw = defaults.string(forKey: Key.operation), let op = LaunchOperation(rawValue: raw), available.contains(op) {
            return op
        }
        return LaunchOperation.preferred(for: profile)
    }

    func setOperation(_ op: LaunchOperation) {
        defaults.set(op.rawValue, forKey: Key.operation)
    }

    var mic: LaunchMic {
        get {
            switch defaults.string(forKey: Key.mic) {
            case "muted": return .muted
            case "off": return .off
            default: return .on
            }
        }
        set {
            let raw: String
            switch newValue {
            case .on: raw = "on"
            case .muted: raw = "muted"
            case .off: raw = "off"
            }
            defaults.set(raw, forKey: Key.mic)
        }
    }

    /// 自動停止までの時間（nil なら手動で止めるまで）
    var duration: String? {
        get {
            let d = defaults.string(forKey: Key.duration)
            return RecordLauncher.durations.contains(d) ? d : nil
        }
        set { defaults.set(newValue, forKey: Key.duration) }
    }

    /// 録音を始める前にセッション名を尋ねるか
    var askName: Bool {
        get { defaults.bool(forKey: Key.askName) }
        set { defaults.set(newValue, forKey: Key.askName) }
    }

    /// 前回録音した対象（bundle ID、または "system"）
    var lastTarget: String? {
        get { defaults.string(forKey: Key.lastTarget) }
        set { defaults.set(newValue, forKey: Key.lastTarget) }
    }
}

extension LaunchTarget {
    /// 前回の対象として保存するキー（PID は次回には意味がないので保存しない）
    var preferenceKey: String? {
        switch kind {
        case .app(let id): return id
        case .system: return "system"
        case .pid: return nil
        }
    }
}
