import AVFoundation
import Foundation

/// システムオーディオ録音・マイクの許可状態
public enum PermissionStatus: String, Sendable {
    case authorized = "許可済み"
    case denied = "拒否"
    case notDetermined = "未確認"
    case unknown = "不明"
}

public enum Permissions {
    public static let audioCaptureSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
    public static let microphoneSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    public static let audioCaptureHint = """
    システム設定 > プライバシーとセキュリティ > 画面収録とシステムオーディオ録音 >「システムオーディオ録音のみ」で、
    実行元のターミナルアプリ（Terminal / iTerm など）を許可してください。
      open "\(audioCaptureSettingsURL)"
    """

    public static let microphoneHint = """
    システム設定 > プライバシーとセキュリティ > マイク で、実行元のターミナルアプリを許可してください。
      open "\(microphoneSettingsURL)"
    """

    // システムオーディオ録音（kTCCServiceAudioCapture）には公開 API がないため、
    // TCC.framework の TCCAccessPreflight / TCCAccessRequest を動的に呼び出す。
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    nonisolated(unsafe) private static let tccHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

    public static func audioCaptureStatus() -> PermissionStatus {
        guard let h = tccHandle, let sym = dlsym(h, "TCCAccessPreflight") else { return .unknown }
        let fn = unsafeBitCast(sym, to: PreflightFn.self)
        switch fn(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .notDetermined
        }
    }

    /// 許可ダイアログを出して結果を待つ
    public static func requestAudioCapture() async -> PermissionStatus {
        guard let h = tccHandle, let sym = dlsym(h, "TCCAccessRequest") else { return .unknown }
        let fn = unsafeBitCast(sym, to: RequestFn.self)
        let granted: Bool = await withCheckedContinuation { cont in
            fn(service, nil) { ok in cont.resume(returning: ok) }
        }
        return granted ? .authorized : .denied
    }

    public static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    public static func requestMicrophone() async -> PermissionStatus {
        let ok = await AVCaptureDevice.requestAccess(for: .audio)
        return ok ? .authorized : .denied
    }

    /// 録音前の確認。未確認なら許可を求め、拒否なら終了コード 2 のエラーにする
    public static func ensure(systemAudio: Bool, microphone: Bool) async throws {
        if systemAudio {
            var st = audioCaptureStatus()
            if st == .notDetermined {
                Console.print("システムオーディオ録音の許可を求めています…")
                st = await requestAudioCapture()
                if st == .denied, audioCaptureStatus() == .notDetermined {
                    // ダイアログを出せない環境（SSH 経由など）では要求が即座に失敗するが、状態は未確認のまま
                    Console.print("警告: システムオーディオ録音の許可を確認できませんでした。相手側が無音になる場合は許可してください。\n"
                        + audioCaptureHint)
                    st = .notDetermined
                }
            }
            if st == .denied {
                throw CappyError.permission("システムオーディオ録音が許可されていません", hint: audioCaptureHint)
            }
        }
        if microphone {
            var st = microphoneStatus()
            if st == .notDetermined {
                Console.print("マイクの許可を求めています…")
                st = await requestMicrophone()
            }
            if st == .denied {
                throw CappyError.permission("マイクが許可されていません", hint: microphoneHint)
            }
        }
    }

    /// バイナリに Info.plist（利用目的の文字列）が埋め込まれているか
    public static var hasEmbeddedUsageDescriptions: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["NSAudioCaptureUsageDescription"] != nil && info["NSMicrophoneUsageDescription"] != nil
    }
}
