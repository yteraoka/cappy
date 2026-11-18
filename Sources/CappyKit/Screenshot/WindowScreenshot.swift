@preconcurrency import CoreGraphics
import AppKit
import Darwin
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
    /// 録音対象のプロセス（ヘルパーを含む）の実行ファイルを含むアプリ（一番外側の .app）。ウインドウを持つ親のアプリを探すのに使う
    public var processAppPaths: [String]
    /// --system（特定のアプリがない）。画面全体を撮る
    public var system: Bool

    public init(bundleIDs: [String] = [], pids: [Int32] = [], processAppPaths: [String] = [], system: Bool = false) {
        self.bundleIDs = bundleIDs
        self.pids = pids
        self.processAppPaths = processAppPaths
        self.system = system
    }

    /// session.json の録音対象から作る。executablePath でプロセスの実行ファイルを引き、それを含むアプリを求める
    public init(targets: [SessionTarget], executablePath: (Int32) -> String? = ScreenshotTarget.executablePath) {
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
        pids = Array(Set(pids)).sorted()
        let apps = Set(pids.compactMap { executablePath($0).flatMap(Self.appBundlePath(ofExecutable:)) })
        self.init(bundleIDs: bundleIDs, pids: pids, processAppPaths: apps.sorted(), system: system)
    }

    /// このアプリのウインドウを撮る対象にするか
    ///
    /// - 録音対象のプロセスそのもの
    /// - bundle ID が録音対象の bundle ID で始まる（--app com.google.Chrome → com.google.Chrome）
    /// - 録音対象のプロセス（ヘルパー）の実行ファイルがこのアプリの中にある
    ///   （Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper (Renderer).app → Google Chrome.app）
    public func matches(pid: Int32, bundleID: String?, appPath: String?) -> Bool {
        if pids.contains(pid) { return true }
        if let b = bundleID, !b.isEmpty, bundleIDs.contains(where: { b.hasPrefix($0) }) { return true }
        if let appPath, processAppPaths.contains(appPath) { return true }
        return false
    }

    /// 実行ファイルを含む一番外側のアプリ（/Applications/Google Chrome.app）。アプリの中になければ nil
    public static func appBundlePath(ofExecutable path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// プロセスの実行ファイルのパス
    public static func executablePath(_ pid: Int32) -> String? {
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        // n は終端の NUL を含まない長さ
        return String(decoding: buf.prefix(Int(n)).prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// ウインドウの候補（ScreenCaptureKit の SCWindow から必要なものだけ取り出したもの。選び方をテストできるようにする）
public struct ScreenshotWindowCandidate: Sendable, Equatable {
    public var index: Int
    public var pid: Int32
    public var bundleID: String?
    /// ウインドウを持つアプリ（.app）のパス
    public var appPath: String?
    public var title: String?
    public var width: Double
    public var height: Double
    public var layer: Int
    public var onScreen: Bool

    public init(index: Int, pid: Int32, bundleID: String?, appPath: String? = nil, title: String?,
                width: Double, height: Double, layer: Int, onScreen: Bool) {
        self.index = index
        self.pid = pid
        self.bundleID = bundleID
        self.appPath = appPath
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
            $0.layer == 0 && $0.width >= minimumSide && $0.height >= minimumSide && target.matches(pid: $0.pid, bundleID: $0.bundleID, appPath: $0.appPath)
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

    // CoreGraphics と ScreenCaptureKit は、どれもメインスレッドから呼ぶ。
    // また、コマンドラインツールでは WindowServer への接続（CGS）が初期化されていないため、そのまま
    // CGPreflightScreenCaptureAccess などを呼ぶと CGS_REQUIRE_INIT のアサーションでプロセスが終了する。
    // GUI アプリと同じく NSApplication を作って接続を初期化してから呼ぶ（run はしないので Dock には出ない）。

    @MainActor private static var connected = false

    /// WindowServer への接続を初期化する（初回だけ）
    @MainActor
    static func connectWindowServer() {
        guard !connected else { return }
        connected = true
        _ = NSApplication.shared
        _ = CGMainDisplayID()
    }

    /// 画面収録が許可されているか
    @MainActor
    public static var hasPermission: Bool {
        connectWindowServer()
        return CGPreflightScreenCaptureAccess()
    }

    /// 許可を求める（初回だけダイアログを出す。許可の反映はターミナルアプリの再起動後）
    @MainActor @discardableResult
    public static func requestPermission() -> Bool {
        connectWindowServer()
        return CGRequestScreenCaptureAccess()
    }

    /// 録音対象のウインドウ（--system なら画面全体）を撮って PNG で保存する
    @MainActor
    public static func capture(target: ScreenshotTarget, to url: URL) async throws -> Result {
        if !hasPermission {
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
            var appPaths: [Int32: String?] = [:]
            let candidates = windows.enumerated().compactMap { (i, w) -> ScreenshotWindowCandidate? in
                guard let app = w.owningApplication else { return nil }
                let pid = app.processID
                if appPaths[pid] == nil {
                    appPaths[pid] = .some(ScreenshotTarget.executablePath(pid).flatMap(ScreenshotTarget.appBundlePath(ofExecutable:)))
                }
                return ScreenshotWindowCandidate(index: i, pid: pid, bundleID: app.bundleIdentifier, appPath: appPaths[pid] ?? nil, title: w.title,
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
