import Foundation
import Testing
@testable import CappyKit

@Suite struct ScreenshotTests {
    private func window(_ index: Int, pid: Int32, _ bundleID: String?, _ title: String? = nil,
                        size: (Double, Double) = (1200, 800), layer: Int = 0, onScreen: Bool = true) -> ScreenshotWindowCandidate {
        ScreenshotWindowCandidate(index: index, pid: pid, bundleID: bundleID, title: title,
                                  width: size.0, height: size.1, layer: layer, onScreen: onScreen)
    }

    @Test func sKeyTakesScreenshotOnlyWhenNothingIsTyped() {
        var p = KeyInputParser()
        #expect(p.feed(UInt8(ascii: "s")) == .screenshot)
        #expect(p.feed(UInt8(ascii: "S")) == .screenshot)
        #expect(p.text.isEmpty)
        // ラベルの途中の s は文字として入る
        #expect(Array("ask".utf8).compactMap { p.feed($0) } == [.edited, .edited, .edited])
        #expect(p.text == "ask")
        #expect(p.feed(0x0D) == .marker(label: "ask"))
        // 日本語入力中の全角の ｓ / Ｓ
        #expect(Array("\u{FF53}".utf8).compactMap { p.feed($0) } == [.screenshot])
        #expect(Array("\u{FF33}".utf8).compactMap { p.feed($0) } == [.screenshot])
        #expect(p.text.isEmpty)
    }

    @Test func targetMatchesAppHelpersAndPIDs() {
        let chrome = "/Applications/Google Chrome.app"
        let helper = chrome + "/Contents/Frameworks/Google Chrome Framework.framework/Versions/140/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        let paths: [Int32: String] = [200: helper, 300: "/Applications/zoom.us.app/Contents/MacOS/zoom.us", 400: "/usr/libexec/somedaemon"]
        #expect(ScreenshotTarget.appBundlePath(ofExecutable: helper) == chrome)
        #expect(ScreenshotTarget.appBundlePath(ofExecutable: "/usr/libexec/somedaemon") == nil)

        // --pid でヘルパーを指定しても、ウインドウを持つ本体のアプリを撮る
        let byPID = ScreenshotTarget(targets: [SessionTarget(kind: .pid, pid: 200, matchedPIDs: [200])], executablePath: { paths[$0] })
        #expect(byPID.pids == [200])
        #expect(byPID.processAppPaths == [chrome])
        #expect(byPID.matches(pid: 100, bundleID: "com.google.Chrome", appPath: chrome))
        #expect(byPID.matches(pid: 200, bundleID: nil, appPath: nil))
        // 同じ会社の別のアプリ（bundle ID が前方一致するだけ）は対象にしない
        #expect(!byPID.matches(pid: 101, bundleID: "com.google", appPath: "/Applications/Google Drive.app"))
        #expect(!byPID.matches(pid: 300, bundleID: "us.zoom.xos", appPath: "/Applications/zoom.us.app"))

        let byApp = ScreenshotTarget(targets: [SessionTarget(kind: .app, bundleID: "us.zoom.xos", matchedPIDs: [300])], executablePath: { paths[$0] })
        #expect(byApp.matches(pid: 999, bundleID: "us.zoom.xos", appPath: nil))
        #expect(!byApp.matches(pid: 100, bundleID: "com.google.Chrome", appPath: chrome))

        // アプリの中にない実行ファイルは親のアプリを持たない
        #expect(ScreenshotTarget(targets: [SessionTarget(kind: .pid, pid: 400)], executablePath: { paths[$0] }).processAppPaths.isEmpty)
        #expect(ScreenshotTarget(targets: [SessionTarget(kind: .system)], executablePath: { _ in nil }).system)
    }

    @Test func choosesTheLargestVisibleWindowOfTheTarget() {
        let target = ScreenshotTarget(bundleIDs: ["us.zoom.xos"])
        let windows = [
            window(0, pid: 10, "com.apple.Terminal", "cappy", size: (2000, 1200)),            // 対象外のアプリ
            window(1, pid: 20, "us.zoom.xos", "Zoom Workplace", size: (900, 600)),
            window(2, pid: 20, "us.zoom.xos", "Zoom Meeting", size: (1400, 900)),
            window(3, pid: 20, "us.zoom.xos", nil, size: (3000, 30)),                           // 細長い帯
            window(4, pid: 20, "us.zoom.xos", "menu", size: (1600, 1000), layer: 25),           // 通常のウインドウではない
            window(5, pid: 20, "us.zoom.xos", "hidden", size: (2500, 1500), onScreen: false),   // 画面に出ていない
        ]
        #expect(WindowScreenshot.choose(windows, for: target)?.index == 2)
        // 画面に出ているものがなければ、出ていないものから選ぶ
        let offScreen = windows.map { var w = $0; w.onScreen = false; return w }
        #expect(WindowScreenshot.choose(offScreen, for: target)?.index == 5)
        // 同じ大きさなら前面のもの
        #expect(WindowScreenshot.choose([window(0, pid: 20, "us.zoom.xos"), window(1, pid: 20, "us.zoom.xos")], for: target)?.index == 0)
        #expect(WindowScreenshot.choose([windows[0]], for: target) == nil)
    }

    @Test func relativePathHasNumberAndTime() {
        #expect(WindowScreenshot.relativePath(number: 1, atMs: 0) == "screenshots/001_00-00-00.png")
        #expect(WindowScreenshot.relativePath(number: 12, atMs: 3_723_999) == "screenshots/012_01-02-03.png")
    }

    @Test func sessionJSONKeepsScreenshots() throws {
        var m = SessionMetadata(id: "abc", name: nil)
        let old = try SessionStore.encode(m)
        #expect(!String(decoding: old, as: UTF8.self).contains("screenshots"))
        #expect(try SessionStore.decode(old).screenshots == nil)

        m.screenshots = [SessionScreenshot(atMs: 65_000, file: "screenshots/001_00-01-05.png", bundleID: "us.zoom.xos", title: "Zoom Meeting")]
        let data = try SessionStore.encode(m)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"screenshots\""))
        #expect(text.contains("\"at_ms\" : 65000"))
        #expect(try SessionStore.decode(data) == m)
    }

    @Test func registryEntryFromOlderVersionHasNoScreenshotSupport() throws {
        let old = #"{"pid":1,"process_start":2,"session":"/tmp/s","has_mic":true,"mic_muted":false,"updated_at":"2026-01-01T00:00:00Z"}"#
        let e = try JSONDecoder().decode(RecordingRegistry.Entry.self, from: Data(old.utf8))
        #expect(e.screenshotAttempts == nil)

        var cur = e
        cur.screenshotAttempts = 1
        cur.lastScreenshot = "/tmp/s/screenshots/001_00-00-01.png"
        let round = try JSONDecoder().decode(RecordingRegistry.Entry.self, from: JSONEncoder().encode(cur))
        #expect(round == cur)
    }
}
