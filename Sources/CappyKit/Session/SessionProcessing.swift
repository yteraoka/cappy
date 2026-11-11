import AVFoundation
import Foundation

/// 録音後の処理（送信用ファイルの作成）と異常終了からの復旧
public enum SessionProcessing {
    /// 各トラックの CAF から送信用ファイル（16 kHz・モノラル）を作る
    public static func convert(_ store: SessionStore) throws {
        let meta = store.metadata
        var results: [TrackID: SendFileConverter.Result] = [:]
        for track in meta.tracks where track.id != .mix {
            let caf = store.url(for: track.file)
            guard FileManager.default.fileExists(atPath: caf.path) else {
                CappyLog.shared.warning("\(track.file) がないため変換を省略します")
                continue
            }
            let base = store.url(for: track.id.rawValue)
            let r = try SendFileConverter.convert(input: caf, outputBase: base)
            results[track.id] = r
            CappyLog.shared.info("送信用ファイルを作成しました \(r.url.lastPathComponent) duration=\(r.durationMs)ms")
        }
        try store.update { m in
            for i in m.tracks.indices {
                if let r = results[m.tracks[i].id] { m.tracks[i].sendFile = r.url.lastPathComponent }
            }
            m.recording.state = .converted
            m.recording.sendFormat = results.values.first.map { "\($0.container.rawValue) 16000Hz mono 16bit" }
        }
    }

    public struct RecoveryReport: Sendable {
        public var rebuiltSessionJSON: Bool
        public var repairedFiles: [String]
        public var tracks: [TrackID: Int64]
    }

    /// 異常終了したセッションを修復し、送信用ファイルと session.json を再生成する
    public static func recover(_ directory: URL) throws -> RecoveryReport {
        var rebuilt = false
        let store: SessionStore
        if let s = try? SessionStore.open(directory) {
            store = s
        } else {
            rebuilt = true
            var meta = SessionMetadata(id: UUID().uuidString.lowercased(), name: nameFromDirectory(directory))
            meta.startedAt = startFromDirectory(directory).map(TimeFormat.iso8601)
            store = SessionStore(directory: directory, metadata: meta)
        }
        var repaired: [String] = []
        var durations: [TrackID: Int64] = [:]
        var tracks = store.metadata.tracks
        for id in [TrackID.remote, .mic] where !tracks.contains(where: { $0.id == id }) {
            let file = "\(id.rawValue).caf"
            if FileManager.default.fileExists(atPath: store.url(for: file).path) {
                tracks.append(SessionTrack(id: id, file: file, sampleRate: 0, channels: 0))
            }
        }
        guard !tracks.isEmpty else {
            throw CappyError.usage("\(directory.path) に録音ファイル（remote.caf / mic.caf）がありません")
        }
        let wasRecording = store.metadata.recording.state == .recording
        for i in tracks.indices {
            let url = store.url(for: tracks[i].file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var file = try? AVAudioFile(forReading: url)
            if file == nil || wasRecording || rebuilt {
                let report = try CAFRepair.repair(url)
                if report.changed { repaired.append(tracks[i].file) }
                file = try? AVAudioFile(forReading: url)
            }
            guard let file else {
                throw CappyError.io("\(tracks[i].file) を修復できませんでした")
            }
            tracks[i].sampleRate = file.fileFormat.sampleRate
            tracks[i].channels = Int(file.fileFormat.channelCount)
            tracks[i].frames = file.length
            let ms = Int64((Double(file.length) / file.fileFormat.sampleRate * 1000).rounded())
            tracks[i].durationMs = ms
            durations[tracks[i].id] = ms
        }
        let caf = tracks.map { store.url(for: $0.file) }
        try store.update { m in
            m.tracks = tracks
            if m.endedAt == nil {
                let maxMs = durations.values.max() ?? 0
                if let s = m.startedAt.flatMap(TimeFormat.parseISO8601) {
                    m.endedAt = TimeFormat.iso8601(s.addingTimeInterval(Double(maxMs) / 1000))
                } else if let mtime = caf.compactMap({ try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }).max() {
                    m.endedAt = TimeFormat.iso8601(mtime)
                }
            }
            if m.recording.state == .recording {
                m.recording.stopReason = "recovered"
            }
            m.recording.state = .finalized
            m.recording.recoveredAt = TimeFormat.iso8601(Date())
        }
        try convert(store)
        return RecoveryReport(rebuiltSessionJSON: rebuilt, repairedFiles: repaired, tracks: durations)
    }

    static func nameFromDirectory(_ dir: URL) -> String? {
        let n = dir.lastPathComponent
        guard let r = n.firstIndex(of: "_") else { return nil }
        let name = String(n[n.index(after: r)...])
        return name.isEmpty ? nil : name
    }

    static func startFromDirectory(_ dir: URL) -> Date? {
        let n = dir.lastPathComponent
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HHmm"
        return f.date(from: String(n.prefix(15)))
    }
}
