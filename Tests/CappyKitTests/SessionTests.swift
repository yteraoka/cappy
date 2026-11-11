import Foundation
import Testing
@testable import CappyKit

@Suite struct SessionTests {
    @Test func roundTripUsesSnakeCaseKeys() throws {
        var m = SessionMetadata(id: "abc", name: "weekly-sync")
        m.startedAt = "2026-11-11T01:00:00.000Z"
        m.targets = [SessionTarget(kind: .app, bundleID: "us.zoom.xos", matchedPIDs: [123]), SessionTarget(kind: .system)]
        var t = SessionTrack(id: .remote, file: "remote.caf", sampleRate: 48_000, channels: 2, offsetMs: 0)
        t.sendFile = "remote.flac"
        m.tracks = [t]
        m.gaps = [SessionGap(startMs: 1000, endMs: 1200, reason: "output_device_changed")]
        m.markers = [SessionMarker(atMs: 5000, label: "議題 2")]
        var tr = TranscriptionState(provider: "google", model: "chirp_3", language: "ja-JP", location: "us", mix: false)
        var job = TranscriptionJobRecord(track: .remote, state: .running)
        job.handle = JobHandle(provider: "google", track: .remote, id: "projects/p/locations/us/operations/1", info: ["k": "v"])
        tr.jobs = [job]
        m.transcription = tr

        let data = try SessionStore.encode(m)
        let text = String(decoding: data, as: UTF8.self)
        for key in ["started_at", "tool_version", "offset_ms", "sample_rate", "send_file", "bundle_id", "matched_pids", "start_ms", "at_ms"] {
            #expect(text.contains("\"\(key)\""), "missing \(key)")
        }
        let back = try SessionStore.decode(data)
        #expect(back == m)
    }

    @Test func storeWritesPrivateFiles() throws {
        FileSecurity.restrictUmask()
        let parent = try TestSupport.tempDir()
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        let dir = try SessionStore.createDirectory(in: parent, start: start, name: "weekly sync/1")
        #expect(dir.lastPathComponent.hasSuffix("_weekly-sync-1"))
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o700)

        let store = SessionStore(directory: dir, metadata: SessionMetadata(id: "x", name: nil))
        try store.update { $0.name = "renamed" }
        let fattrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((fattrs[.posixPermissions] as? Int) == 0o600)
        let reopened = try SessionStore.open(dir)
        #expect(reopened.metadata.name == "renamed")

        // 同名のディレクトリがあれば連番を付ける
        let dir2 = try SessionStore.createDirectory(in: parent, start: start, name: "weekly sync/1")
        #expect(dir2.lastPathComponent == dir.lastPathComponent + "-2")
    }

    @Test func openMissingSessionIsUsageError() throws {
        let dir = try TestSupport.tempDir()
        do {
            _ = try SessionStore.open(dir)
            Issue.record("should throw")
        } catch let e as CappyError {
            #expect(e.status == .usage)
        }
    }

    @Test func gapMergerMergesAdjacentSameReason() {
        var gaps: [SessionGap] = []
        GapMerger.append(SessionGap(startMs: 100, endMs: 110, reason: "buffer_overflow"), to: &gaps)
        GapMerger.append(SessionGap(startMs: 500, endMs: 520, reason: "buffer_overflow"), to: &gaps)
        GapMerger.append(SessionGap(startMs: 5000, endMs: 5010, reason: "buffer_overflow"), to: &gaps)
        GapMerger.append(SessionGap(startMs: 5100, endMs: 5400, reason: "output_device_changed"), to: &gaps)
        #expect(gaps.count == 3)
        #expect(gaps[0] == SessionGap(startMs: 100, endMs: 520, reason: "buffer_overflow"))
    }
}
