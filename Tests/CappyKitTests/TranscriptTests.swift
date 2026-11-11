import Foundation
import Testing
@testable import CappyKit

@Suite struct TranscriptTests {
    func doc(_ segments: [Segment]) -> TranscriptDocument {
        TranscriptDocument(sessionID: "s1", name: "weekly-sync", startedAt: "2026-11-11T01:00:00.000Z",
                           provider: "google", model: "chirp_3", language: "ja-JP", mix: false,
                           diarization: ["remote": true], segments: segments, generatedAt: "2026-11-11T02:00:00.000Z")
    }

    @Test func mergeSortsByTimeAndDropsEmpty() {
        let mic = [Segment(track: .mic, speaker: nil, startMs: 1000, endMs: 2000, text: "はい", confidence: 0.9),
                   Segment(track: .mic, speaker: nil, startMs: 5000, endMs: 6000, text: "  ", confidence: nil)]
        let remote = [Segment(track: .remote, speaker: "1", startMs: 0, endMs: 900, text: "こんにちは", confidence: 0.8),
                      Segment(track: .remote, speaker: "2", startMs: 1000, endMs: 1500, text: "どうも", confidence: 0.8)]
        let merged = TranscriptMerger.merge([mic, remote])
        #expect(merged.map(\.text) == ["こんにちは", "はい", "どうも"])
    }

    @Test func speakerNaming() {
        let segs = [Segment(track: .remote, speaker: "7", startMs: 0, endMs: 1, text: "a", confidence: nil),
                    Segment(track: .mic, speaker: nil, startMs: 1, endMs: 2, text: "b", confidence: nil),
                    Segment(track: .remote, speaker: "3", startMs: 2, endMs: 3, text: "c", confidence: nil)]
        let n = SpeakerNaming(segments: segs, language: .ja)
        #expect(segs.map(n.label) == ["相手 1", "自分", "相手 2"])
        let en = SpeakerNaming(segments: segs, language: .en)
        #expect(segs.map(en.label) == ["Remote 1", "Me", "Remote 2"])
        // 話者が 1 人だけなら番号なし
        let single = [Segment(track: .remote, speaker: "1", startMs: 0, endMs: 1, text: "a", confidence: nil)]
        #expect(SpeakerNaming(segments: single, language: .ja).label(for: single[0]) == "相手")
        let mix = [Segment(track: .mix, speaker: "1", startMs: 0, endMs: 1, text: "a", confidence: nil),
                   Segment(track: .mix, speaker: "2", startMs: 0, endMs: 1, text: "a", confidence: nil)]
        #expect(SpeakerNaming(segments: mix, language: .ja).label(for: mix[1]) == "話者 2")
        #expect(SpeakerNaming(segments: mix, language: .en).label(for: mix[1]) == "Speaker 2")
    }

    @Test func markdownAndSRT() {
        let d = doc([Segment(track: .remote, speaker: nil, startMs: 1500, endMs: 3200, text: "始めましょう", confidence: 0.9),
                     Segment(track: .mic, speaker: nil, startMs: 65_000, endMs: 66_000, text: "はい", confidence: 0.9)])
        let md = TranscriptRenderer.markdown(d, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(md.hasPrefix("# weekly-sync\n"))
        #expect(md.contains("- 録音開始: 2026-11-11 10:00"))
        #expect(md.contains("**[00:00:01] 相手**: 始めましょう"))
        #expect(md.contains("**[00:01:05] 自分**: はい"))
        let srt = TranscriptRenderer.srt(d)
        #expect(srt == """
        1
        00:00:01,500 --> 00:00:03,200
        相手: 始めましょう

        2
        00:01:05,000 --> 00:01:06,000
        自分: はい


        """)
    }

    @Test func jsonRoundTrip() throws {
        let d = doc([Segment(track: .remote, speaker: "1", startMs: 0, endMs: 10, text: "x", confidence: 0.5)])
        let data = try TranscriptRenderer.json(d)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"start_ms\""))
        #expect(text.contains("\"session_id\""))
        #expect(try JSONDecoder().decode(TranscriptDocument.self, from: data) == d)
    }

    @Test func formatList() throws {
        #expect(try TranscriptFormat.parseList("md, json,srt,md") == [.md, .json, .srt])
        #expect(throws: CappyError.self) { try TranscriptFormat.parseList("md,docx") }
        #expect(throws: CappyError.self) { try TranscriptFormat.parseList("") }
    }
}

@Suite struct L10nTests {
    @Test func detection() {
        #expect(L10n.detect([:]) == .en)
        #expect(L10n.detect(["LANG": "ja_JP.UTF-8"]) == .ja)
        #expect(L10n.detect(["LANG": "en_US.UTF-8"]) == .en)
        #expect(L10n.detect(["LANG": "ja_JP.UTF-8", "LC_MESSAGES": "C"]) == .en)
        #expect(L10n.detect(["LANG": "en_US.UTF-8", "LC_ALL": "ja_JP.UTF-8"]) == .ja)
        #expect(L10n.detect(["LANG": "ja_JP.UTF-8", "CAPPY_LANG": "en"]) == .en)
        #expect(L10n.detect(["CAPPY_LANG": "ja"]) == .ja)
        #expect(L10n.detect(["LC_ALL": "", "LANG": "ja_JP"]) == .ja)
        #expect(UILanguage.forDocument("ja-JP") == .ja)
        #expect(UILanguage.forDocument("en-US") == .en)
    }

    @Test func overrideAndTrackLabels() {
        L10n.$override.withValue(.ja) {
            #expect(tr("Hello", ja: "こんにちは") == "こんにちは")
            #expect(TrackID.mic.displayName == "自分")
        }
        L10n.$override.withValue(.en) {
            #expect(tr("Hello", ja: "こんにちは") == "Hello")
            #expect(TrackID.remote.displayName == "Remote")
        }
        #expect(tr(.ja, "Me", ja: "自分") == "自分")
    }

    /// 作るファイルは表示言語ではなく会議の言語で書く
    @Test func documentsFollowMeetingLanguage() {
        let segs = [Segment(track: .remote, speaker: nil, startMs: 1500, endMs: 3200, text: "Let's start", confidence: nil),
                    Segment(track: .mic, speaker: nil, startMs: 65_000, endMs: 66_000, text: "OK", confidence: nil)]
        let d = TranscriptDocument(sessionID: "s1", name: "weekly", startedAt: "2026-11-11T01:00:00.000Z", provider: "gemini",
                                   model: nil, language: "en-US", mix: false, diarization: [:], segments: segs)
        L10n.$override.withValue(.ja) {
            let md = TranscriptRenderer.markdown(d, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
            #expect(md.contains("- Recording started: 2026-11-11 10:00"))
            #expect(md.contains("**[00:00:01] Remote**: Let's start"))
            #expect(md.contains("**[00:01:05] Me**: OK"))
            #expect(TranscriptRenderer.srt(d).contains("Remote: Let's start"))
            let user = SummaryPrompt.user(doc: d, meta: SessionMetadata(id: "s1", name: "weekly"))
            #expect(user.contains("Meeting: weekly"))
            #expect(user.contains("Speakers: Remote, Me"))
            #expect(user.hasSuffix("Write a summary of the meeting above."))
        }
    }
}
