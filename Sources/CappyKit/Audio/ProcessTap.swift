import CoreAudio
import Foundation

/// Core Audio の Process Tap（AudioHardwareCreateProcessTap）
final class ProcessTap: @unchecked Sendable {
    enum Mode: Equatable {
        /// 指定プロセスのステレオミックス
        case processes([AudioObjectID])
        /// 指定プロセスを除くシステム全体
        case systemExcluding([AudioObjectID])
    }

    let id: AudioObjectID
    let uid: String
    private(set) var mode: Mode
    /// 対象の音を本人に聞こえなくするか（テストで afplay の音を鳴らさずに録るため）
    let muted: Bool
    private var destroyed = false

    init(mode: Mode, muted: Bool = false) throws {
        self.mode = mode
        self.muted = muted
        let desc = Self.makeDescription(mode, muted: muted)
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr, tapID != kAudioObjectUnknown else {
            throw CoreAudioError(status: st, what: "AudioHardwareCreateProcessTap")
        }
        self.id = tapID
        do {
            self.uid = try CA.string(tapID, kAudioTapPropertyUID)
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
        CappyLog.shared.info(tr("Created the process tap id=\(tapID) mode=\(mode.logDescription)", ja: "タップを作成しました id=\(tapID) mode=\(mode.logDescription)"))
    }

    deinit { destroy() }

    static func makeDescription(_ mode: Mode, muted: Bool = false) -> CATapDescription {
        let desc: CATapDescription
        switch mode {
        case .processes(let ids):
            desc = CATapDescription(stereoMixdownOfProcesses: ids)
        case .systemExcluding(let ids):
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: ids)
        }
        desc.name = "cappy"
        desc.isPrivate = true          // 作成したプロセスからだけ見える
        desc.muteBehavior = muted ? .muted : .unmuted   // 通常は本人にもそのまま聞こえる
        return desc
    }

    /// タップのフォーマット（通常 48 kHz・Float32・2ch）
    func format() throws -> AudioStreamBasicDescription {
        try CA.scalar(id, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
    }

    /// 対象プロセスを差し替える（kAudioTapPropertyDescription を上書き）。失敗したら false
    func update(mode newMode: Mode) -> Bool {
        let desc = Self.makeDescription(newMode, muted: muted)
        var addr = CA.address(kAudioTapPropertyDescription)
        var ref: Unmanaged<CATapDescription> = .passUnretained(desc)
        let st = withUnsafeMutablePointer(to: &ref) { ptr in
            AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size), ptr)
        }
        withExtendedLifetime(desc) {}
        if st == noErr {
            mode = newMode
            CappyLog.shared.info(tr("Updated the tap targets mode=\(newMode.logDescription)", ja: "タップの対象を更新しました mode=\(newMode.logDescription)"))
            return true
        }
        CappyLog.shared.warning(tr("Could not update the tap targets: \(osStatusString(st))", ja: "タップの対象を更新できませんでした: \(osStatusString(st))"))
        return false
    }

    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        let st = AudioHardwareDestroyProcessTap(id)
        if st != noErr {
            CappyLog.shared.warning(tr("Failed to destroy the tap: \(osStatusString(st))", ja: "タップの破棄に失敗しました: \(osStatusString(st))"))
        }
    }
}

extension ProcessTap.Mode {
    var logDescription: String {
        switch self {
        case .processes(let ids): return "processes\(ids)"
        case .systemExcluding(let ids): return "system-excluding\(ids)"
        }
    }
}
