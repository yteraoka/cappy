import Foundation
import IOKit
import IOKit.pwr_mgt

/// システムスリープの通知を受ける（スリープ前に録音を停止して確定するため）
public final class SleepWatcher: @unchecked Sendable {
    // IOKit のメッセージ定数（iokit_common_msg マクロは Swift に取り込まれないため手で定義）
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let queue = DispatchQueue(label: "dev.cappy.power")
    private let onWillSleep: @Sendable () -> Void

    /// onWillSleep はスリープ前に同期的に呼ばれる。戻るとスリープを許可する（最大約 30 秒まで待てる）
    public init(onWillSleep: @escaping @Sendable () -> Void) {
        self.onWillSleep = onWillSleep
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            let me = Unmanaged<SleepWatcher>.fromOpaque(refcon).takeUnretainedValue()
            me.handle(messageType: messageType, argument: messageArgument)
        }, &notifier)
        if rootPort == 0 {
            CappyLog.shared.warning("スリープ通知を登録できませんでした")
        } else if let notifyPort {
            IONotificationPortSetDispatchQueue(notifyPort, queue)
        }
    }

    deinit { invalidate() }

    public func invalidate() {
        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
            notifier = 0
        }
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
        if rootPort != 0 {
            IOServiceClose(rootPort)
            rootPort = 0
        }
    }

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let id = Int(bitPattern: argument)
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, id)
        case Self.systemWillSleep:
            CappyLog.shared.info("スリープを検知しました")
            onWillSleep()
            IOAllowPowerChange(rootPort, id)
        default:
            break
        }
    }
}
