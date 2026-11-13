import Foundation
import Testing
@testable import CappyKit

@Suite struct SilenceCheckTests {
    @Test func hasAudioIgnoresSilentTracksAndMix() {
        #expect(SilenceCheck.hasAudio(tracks: [.remote, .mic], silent: []))
        #expect(SilenceCheck.hasAudio(tracks: [.remote, .mic], silent: [.mic]))
        #expect(SilenceCheck.hasAudio(tracks: [.remote, .mic], silent: [.remote]))
        #expect(!SilenceCheck.hasAudio(tracks: [.remote, .mic], silent: [.remote, .mic]))
        // マイクなし（--no-mic）で相手側が無音
        #expect(!SilenceCheck.hasAudio(tracks: [.remote], silent: [.remote]))
        // mix は判定に使わない
        #expect(!SilenceCheck.hasAudio(tracks: [.remote, .mix], silent: [.remote]))
    }

    @Test func warnsOnceWhenRemoteStaysSilent() {
        var w = RemoteSilenceWatch(warnAfter: 60)
        #expect(w.update(elapsed: 0.5, overallPeak: nil) == nil)
        #expect(w.update(elapsed: 59.5, overallPeak: 0) == nil)
        #expect(!w.isWarning)
        #expect(w.update(elapsed: 60, overallPeak: 0) == .stillSilent)
        #expect(w.isWarning)
        #expect(w.update(elapsed: 120, overallPeak: 0) == nil)
        #expect(w.update(elapsed: 130, overallPeak: 0.2) == .soundDetected)
        #expect(!w.isWarning)
        #expect(w.update(elapsed: 140, overallPeak: 0.2) == nil)
    }

    @Test func noWarningWhenSoundArrivesInTime() {
        var w = RemoteSilenceWatch(warnAfter: 60)
        #expect(w.update(elapsed: 10, overallPeak: 0.01) == nil)
        #expect(w.update(elapsed: 600, overallPeak: 0.01) == nil)
        #expect(!w.isWarning)
        #expect(!w.warned)
    }
}
