import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// スクリーンショットを撮る相手（録音対象から作る）
public struct ScreenshotTarget: Sendable, Equatable {
    /// 録音対象の bundle ID（前方一致）
    public var bundleIDs: [String]
    /// 録音対象のプロセス
    public var pids: [Int32]
    /// 録音対象のプロセス（ヘルパーを含む）の bundle ID。ウインドウを持つ親のアプリを探すのに使う
    public var processBundleIDs: [String]
    /// --system（特定のアプリがない）。画面全体を撮る
    public var system: Bool

    public init(bundleIDs: [String] = [], pids: [Int32] = [], processBundleIDs: [String] = [], system: Bool = false) {
        self.bundleIDs = bundleIDs
        self.pids = pids
        self.processBundleIDs = processBundleIDs
        self.system = system
    }

    /// session.json の録音対象から作る。processes には録音中の音声プロセスの一覧を渡す（ヘルパーの bundle ID を引く）
    public init(targets: [SessionTarget], processes: [AudioProcessInfo] = []) {
        var bundleIDs: [String] = []
        var pids: [Int32] = []
        var system = false
        for t in targets {
            switch t.kind {
            case .system: system = true
            case .app: if let b = t.bundleID { bundleIDs.append(b) }
            case .pid: break
            }
            if let p = t.pid { pids.append(p) }
            pids.append(contentsOf: t.matchedPIDs ?? [])
        }
        let pidSet = Set(pids)
        let processBundleIDs = processes.filter { pidSet.contains($0.pid) && !$0.bundleID.isEmpty }.map(\.bundleID)
        self.init(bundleIDs: bundleIDs, pids: pids, processBundleIDs: Array(Set(processBundleIDs)).sorted(), system: system)
    }

    /// このアプリのウインドウを撮る対象にするか
    ///
    /// - 録音対象のプロセスそのもの
    /// - bundle ID が録音対象の bundle ID で始まる（--app com.google.Chrome → com.google.Chrome）
    /// - 録音対象のプロセスがこのアプリのヘルパー（com.google.Chrome.helper.renderer → com.google.Chrome）
    public func matches(pid: Int32, bundleID: String?) -> Bool {
        if pids.contains(pid) { return true }
        guard let b = bundleID, !b.isEmpty else { return false }
        if bundleIDs.contains(where: { b.hasPrefix($0) }) { return true }
        return processBundleIDs.contains { $0 == b || $0.hasPrefix(b + ".") }
    }
}

/// ウインドウの候補（ScreenCaptureKit の SCWindow から必要なものだけ取り出したもの。選び方をテストできるようにする）
public struct ScreenshotWindowCandidate: Sendable, Equatable {
    public var index: Int
    public var pid: Int32
    public var bundleID: String?
    public var title: String?
    public var width: Double
    public var height: Double
    public var layer: Int
    public var onScreen: Bool

    public init(index: Int, pid: Int32, bundleID: String?, title: String?, width: Double, height: Double, layer: Int, onScreen: Bool) {
        self.index = index
        self.pid = pid
        self.bundleID = bundleID
        self.title = title
        self.width = width
        self.height = height
        self.layer = layer
        self.onScreen = onScreen
    }

    var area: Double { width * height }
}

public enum WindowScreenshot {
    /// これより小さいウインドウ（ツールバーの小窓・通知など）は撮らない
    static let minimumSide: Double = 120

    /// 撮るウインドウを選ぶ。録音対象のアプリの通常のウインドウのうち、画面に出ているものを優先し、その中で一番大きいもの
    public static func choose(_ windows: [ScreenshotWindowCandidate], for target: ScreenshotTarget) -> ScreenshotWindowCandidate? {
        let candidates = windows.filter {
            $0.layer == 0 && $0.width >= minimumSide && $0.height >= minimumSide && target.matches(pid: $0.pid, bundleID: $0.bundleID)
        }
        let pool = candidates.contains(where: \.onScreen) ? candidates.filter(\.onScreen) : candidates
        // 同じ大きさなら前面（一覧の先）のもの
        return pool.max { a, b in a.area != b.area ? a.area < b.area : a.index > b.index }
    }

    /// スクリーンショットのファイル名（screenshots/001_00-12-34.png）
    public static func relativePath(number: Int, atMs: Int64) -> String {
        let total = max(0, atMs) / 1000
        let name = String(format: "%03d_%02d-%02d-%02d.png", number, total / 3600, (total / 60) % 60, total % 60)
        return "screenshots/" + name
    }

    public struct Result: Sendable {
        /// 撮ったウインドウのアプリの bundle ID（画面全体なら nil）
        public var bundleID: String?
        public var appName: String?
        public var title: String?
        /// 画面全体を撮ったか
        public var wholeDisplay: Bool
    }

    public static let screenCaptureSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    public static var permissionHint: String {
        tr("""
        Allow the terminal app you run cappy from (Terminal, iTerm, ...) in
        System Settings > Privacy & Security > Screen & System Audio Recording > "Screen & System Audio Recording", then restart the terminal app.
          open "\(screenCaptureSettingsURL)"
        """, ja: """
        システム設定 > プライバシーとセキュリティ > 画面収録とシステムオーディオ録音 >「画面とシステムオーディオ録音」で、
        実行元のターミナルアプリ（Terminal / iTerm など）を許可し、ターミナルアプリを再起動してください。
          open "\(screenCaptureSettingsURL)"
        """)
    }

    /// 画面収録が許可されているか
    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// 許可を求める（初回だけダイアログを出す。許可の反映はターミナルアプリの再起動後）
    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// 録音対象のウインドウ（--system なら画面全体）を撮って PNG で保存する
    public static func capture(target: ScreenshotTarget, to url: URL) async throws -> Result {
        if !CGPreflightScreenCaptureAccess() {
            // 初回は許可を求めるダイアログを出す（許可しても反映はターミナルアプリの再起動後）
            requestPermission()
            throw CappyError.permission(tr("Screen recording is not allowed (needed for screenshots)", ja: "画面収録が許可されていません（スクリーンショットに必要です）"),
                                        hint: permissionHint)
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            throw CappyError.permission(tr("Cannot list the windows: \(error.localizedDescription)", ja: "ウインドウの一覧を取得できません: \(error.localizedDescription)"),
                                        hint: permissionHint)
        }

        let filter: SCContentFilter
        let result: Result
        if target.system {
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw CappyError.targetNotFound(tr("No display to capture", ja: "撮影できるディスプレイがありません"))
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            result = Result(bundleID: nil, appName: nil, title: nil, wholeDisplay: true)
        } else {
            let windows = content.windows
            let candidates = windows.enumerated().compactMap { (i, w) -> ScreenshotWindowCandidate? in
                guard let app = w.owningApplication else { return nil }
                return ScreenshotWindowCandidate(index: i, pid: app.processID, bundleID: app.bundleIdentifier, title: w.title,
                                                 width: Double(w.frame.width), height: Double(w.frame.height),
                                                 layer: w.windowLayer, onScreen: w.isOnScreen)
            }
            guard let chosen = choose(candidates, for: target) else {
                throw CappyError.targetNotFound(tr("No window of the recording target was found", ja: "録音対象のアプリのウインドウが見つかりません"),
                                                hint: tr("Minimized windows cannot be captured", ja: "最小化したウインドウは撮れません"))
            }
            let window = windows[chosen.index]
            filter = SCContentFilter(desktopIndependentWindow: window)
            result = Result(bundleID: chosen.bundleID, appName: window.owningApplication?.applicationName,
                            title: chosen.title.flatMap { $0.isEmpty ? nil : $0 }, wholeDisplay: false)
        }

        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        config.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CappyError.io(tr("Failed to capture the screenshot: \(error.localizedDescription)", ja: "スクリーンショットを撮れませんでした: \(error.localizedDescription)"))
        }
        try FileSecurity.createPrivateDirectory(url.deletingLastPathComponent())
        try FileSecurity.writeAtomically(try pngData(image), to: url)
        return result
    }

    static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw CappyError.io(tr("Cannot encode the screenshot as PNG", ja: "スクリーンショットを PNG にできません"))
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CappyError.io(tr("Cannot encode the screenshot as PNG", ja: "スクリーンショットを PNG にできません"))
        }
        return data as Data
    }
}
