import CoreAudio
import Darwin
import Foundation

/// Core Audio のプロパティ取得ヘルパー
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = address(selector, scope)
        return AudioObjectHasProperty(obj, &addr)
    }

    static func scalar<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                          default def: T) throws -> T where T: BitwiseCopyable {
        var addr = address(selector, scope)
        var value = def
        var size = UInt32(MemoryLayout<T>.size)
        let st = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, ptr)
        }
        guard st == noErr else { throw CoreAudioError(status: st, what: "property \(fourCC(selector)) of \(obj)") }
        return value
    }

    static func array<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         of: T.Type) throws -> [T] where T: BitwiseCopyable {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        var st = AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size)
        guard st == noErr else { throw CoreAudioError(status: st, what: "size of \(fourCC(selector))") }
        let count = Int(size) / MemoryLayout<T>.stride
        if count == 0 { return [] }
        var result = [T](unsafeUninitializedCapacity: count) { buf, initialized in
            initialized = 0
            st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, buf.baseAddress!)
            if st == noErr { initialized = Int(size) / MemoryLayout<T>.stride }
        }
        guard st == noErr else { throw CoreAudioError(status: st, what: "property \(fourCC(selector))") }
        if result.count > count { result.removeLast(result.count - count) }
        return result
    }

    static func string(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
        var addr = address(selector, scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, ptr)
        }
        guard st == noErr else { throw CoreAudioError(status: st, what: "string \(fourCC(selector))") }
        guard let v = value else { return "" }
        return v.takeRetainedValue() as String
    }

    static func fourCC(_ v: UInt32) -> String {
        let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
}

public struct CoreAudioError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public let what: String
    public var description: String { "Core Audio エラー \(osStatusString(status)): \(what)" }
}

// MARK: - デバイス

public struct AudioDeviceInfo: Sendable, Equatable {
    public var id: AudioDeviceID
    public var uid: String
    public var name: String
    public var sampleRate: Double
    public var inputChannels: Int
    public var outputChannels: Int
    public var inputStreamCount: Int
    public var isDefaultInput: Bool
    public var isDefaultOutput: Bool
}

public enum AudioDevices {
    public static func defaultOutputDevice() throws -> AudioDeviceID {
        try CA.scalar(CA.system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(kAudioObjectUnknown))
    }

    public static func defaultInputDevice() throws -> AudioDeviceID {
        try CA.scalar(CA.system, kAudioHardwarePropertyDefaultInputDevice, default: AudioDeviceID(kAudioObjectUnknown))
    }

    public static func all() throws -> [AudioDeviceInfo] {
        let ids = try CA.array(CA.system, kAudioHardwarePropertyDevices, of: AudioDeviceID.self)
        let defIn = (try? defaultInputDevice()) ?? 0
        let defOut = (try? defaultOutputDevice()) ?? 0
        return ids.compactMap { id in
            guard var info = try? info(for: id) else { return nil }
            info.isDefaultInput = id == defIn
            info.isDefaultOutput = id == defOut
            return info
        }
    }

    public static func info(for id: AudioDeviceID) throws -> AudioDeviceInfo {
        let uid = try CA.string(id, kAudioDevicePropertyDeviceUID)
        let name = (try? CA.string(id, kAudioObjectPropertyName)) ?? uid
        let rate = (try? CA.scalar(id, kAudioDevicePropertyNominalSampleRate, default: Float64(0))) ?? 0
        let inCh = channelCount(id, scope: kAudioObjectPropertyScopeInput)
        let outCh = channelCount(id, scope: kAudioObjectPropertyScopeOutput)
        let inStreams = (try? CA.array(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: AudioStreamID.self).count) ?? 0
        return AudioDeviceInfo(id: id, uid: uid, name: name, sampleRate: rate,
                               inputChannels: inCh, outputChannels: outCh, inputStreamCount: inStreams,
                               isDefaultInput: false, isDefaultOutput: false)
    }

    public static func device(uid: String) throws -> AudioDeviceInfo? {
        try all().first { $0.uid == uid }
    }

    static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = CA.address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

// MARK: - 音声プロセス

public struct AudioProcessInfo: Sendable, Equatable {
    public var objectID: AudioObjectID
    public var pid: Int32
    public var bundleID: String
    public var name: String
    public var isRunningOutput: Bool
    public var isRunningInput: Bool
}

public enum AudioProcesses {
    /// kAudioHardwarePropertyProcessObjectList で音声プロセスを列挙する
    public static func list() throws -> [AudioProcessInfo] {
        let ids = try CA.array(CA.system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        return ids.compactMap { info(objectID: $0) }
    }

    public static func info(objectID id: AudioObjectID) -> AudioProcessInfo? {
        guard let pid = try? CA.scalar(id, kAudioProcessPropertyPID, default: pid_t(-1)), pid > 0 else { return nil }
        let bundle = (try? CA.string(id, kAudioProcessPropertyBundleID)) ?? ""
        let out = ((try? CA.scalar(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0) != 0
        let inp = ((try? CA.scalar(id, kAudioProcessPropertyIsRunningInput, default: UInt32(0))) ?? 0) != 0
        return AudioProcessInfo(objectID: id, pid: pid, bundleID: bundle, name: processName(pid),
                                isRunningOutput: out, isRunningInput: inp)
    }

    /// PID からプロセスオブジェクト ID（kAudioHardwarePropertyTranslatePIDToProcessObject）
    public static func objectID(forPID pid: pid_t) -> AudioObjectID? {
        var addr = CA.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var result = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(CA.system, &addr, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &result)
        guard st == noErr, result != kAudioObjectUnknown else { return nil }
        return result
    }

    public static func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        if n > 0 {
            let path = cString(buf)
            // .app の中なら .app 名を返す
            if let range = path.range(of: ".app/") {
                let appPath = String(path[..<range.lowerBound])
                return (appPath as NSString).lastPathComponent
                    + (path.contains("Helper") ? " (" + (path as NSString).lastPathComponent + ")" : "")
            }
            return (path as NSString).lastPathComponent
        }
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        return cString(name)
    }

    private static func cString(_ buf: [CChar]) -> String {
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - ホストタイム

public enum HostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func now() -> UInt64 { mach_absolute_time() }

    public static func toNanos(_ ticks: UInt64) -> UInt64 {
        ticks &* UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    public static func toSeconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    /// ホストタイム差（秒、負もあり）
    public static func delta(_ a: UInt64, _ b: UInt64) -> Double {
        if a >= b { return toSeconds(a - b) }
        return -toSeconds(b - a)
    }
}
