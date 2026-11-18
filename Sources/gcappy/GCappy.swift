import AppKit
import CappyKit

/// gcappy: cappy のメニューバー版。
///
/// 録音・文字起こし・要約は同梱の `cappy record` を子プロセスで動かして行い、
/// ミュートとスクリーンショットは `cappy mic` / `cappy shot` と同じ登録簿（RecordingRegistry）経由で操作する。
/// 子プロセスは gcappy.app から起動するため、システムオーディオ録音とマイクの許可は gcappy に対して求められる。
@main
@MainActor
enum GCappyMain {
    static func main() {
        FileSecurity.restrictUmask()
        // 文言の言語（L10n）を最初に使う前に、ログインシェルの環境と表示言語を整える
        AppEnvironment.prepare()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Dock には出さず、メニューバーだけに置く（Info.plist の LSUIElement と同じ）
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
