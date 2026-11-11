import Foundation
import Testing
@testable import CappyKit

@Suite struct AmazonTranscribeResultParserTests {
    /// 新しい形式: items に speaker_label がある
    @Test func itemsWithSpeakerLabels() throws {
        let json = """
        {"jobName": "j", "results": {
          "transcripts": [{"transcript": "こんにちは。よろしく お願いします。"}],
          "items": [
            {"id": 0, "type": "pronunciation", "start_time": "0.10", "end_time": "0.80", "speaker_label": "spk_0",
             "alternatives": [{"confidence": "0.9", "content": "こんにちは"}]},
            {"id": 1, "type": "punctuation", "alternatives": [{"confidence": "0.0", "content": "。"}]},
            {"id": 2, "type": "pronunciation", "start_time": "1.20", "end_time": "1.60", "speaker_label": "spk_1",
             "alternatives": [{"confidence": "0.7", "content": "よろしく"}]},
            {"id": 3, "type": "pronunciation", "start_time": "1.60", "end_time": "2.30", "speaker_label": "spk_1",
             "alternatives": [{"confidence": "0.5", "content": "お願いします"}]},
            {"id": 4, "type": "punctuation", "alternatives": [{"content": "。"}]}
          ]}, "status": "COMPLETED"}
        """
        let segs = try AmazonTranscribeResultParser.segments(fromJSON: Data(json.utf8), track: .remote, offsetMs: 10_000, language: "ja-JP")
        #expect(segs.count == 2)
        #expect(segs[0] == Segment(track: .remote, speaker: "spk_0", startMs: 10_100, endMs: 10_800, text: "こんにちは。", confidence: 0.9))
        #expect(segs[1].speaker == "spk_1")
        #expect(segs[1].text == "よろしくお願いします。")
        #expect(segs[1].startMs == 11_200)
        #expect(segs[1].endMs == 12_300)
        #expect(abs((segs[1].confidence ?? 0) - 0.6) < 1e-9)
    }

    /// 古い形式: speaker_labels.segments から話者を引く。英語は空白でつなぐ
    @Test func speakerLabelSegmentsAndSpaces() throws {
        let json = """
        {"results": {
          "speaker_labels": {"speakers": 2, "segments": [
            {"start_time": "0.0", "end_time": "1.0", "speaker_label": "spk_0"},
            {"start_time": "1.0", "end_time": "3.0", "speaker_label": "spk_1"}]},
          "items": [
            {"type": "pronunciation", "start_time": "0.1", "end_time": "0.4", "alternatives": [{"content": "Hello"}]},
            {"type": "pronunciation", "start_time": "0.5", "end_time": "0.9", "alternatives": [{"content": "there"}]},
            {"type": "punctuation", "alternatives": [{"content": "."}]},
            {"type": "pronunciation", "start_time": "1.2", "end_time": "1.5", "alternatives": [{"content": "Hi"}]}
          ]}}
        """
        let segs = try AmazonTranscribeResultParser.segments(fromJSON: Data(json.utf8), track: .remote, offsetMs: 0, language: "en-US")
        #expect(segs.map(\.text) == ["Hello there.", "Hi"])
        #expect(segs.map(\.speaker) == ["spk_0", "spk_1"])
        #expect(segs[0].confidence == nil)
    }

    /// 話者分離なし（mic）の長い発言は、文の終わりと長さで分ける
    @Test func longRunIsSplitBySentences() throws {
        var items: [[String: Any]] = []
        for i in 0..<20 {
            let start = Double(i) * 2
            items.append(["type": "pronunciation", "start_time": String(start), "end_time": String(start + 1.5),
                          "alternatives": [["content": "単語\(i)", "confidence": "1.0"]]])
            if i % 5 == 4 { items.append(["type": "punctuation", "alternatives": [["content": "。"]]]) }
        }
        let data = try JSONSerialization.data(withJSONObject: ["results": ["items": items]])
        let segs = try AmazonTranscribeResultParser.segments(fromJSON: data, track: .mic, offsetMs: 0, language: "ja-JP")
        #expect(segs.count == 4)
        #expect(segs.allSatisfy { $0.speaker == nil && $0.text.hasSuffix("。") })
        #expect(segs[0].text == "単語0単語1単語2単語3単語4。")
        #expect(segs[1].startMs == 10_000)
    }

    @Test func invalidJSON() {
        #expect(throws: CappyError.self) {
            try AmazonTranscribeResultParser.segments(fromJSON: Data("{}".utf8), track: .mic, offsetMs: 0, language: "ja-JP")
        }
    }
}

@Suite struct AmazonTranscribeProviderTests {
    static let creds = StaticAWSCredentials(AWSCredentials(accessKeyID: "AK", secretAccessKey: "SK"))

    func makeTrack() throws -> AudioTrack {
        let dir = try TestSupport.tempDir()
        let url = dir.appendingPathComponent("remote.flac")
        try Data("fLaC-dummy".utf8).write(to: url)
        return AudioTrack(id: .remote, url: url, offsetMs: 1500, durationMs: 60_000, sessionID: "sess-1")
    }

    func provider(_ stub: StubTransport, settings: TranscribeSettings = TranscribeSettings()) throws -> AmazonTranscribeProvider {
        try AmazonTranscribeProvider(settings: settings, region: "ap-northeast-1", bucket: "my-bucket", credentials: Self.creds,
                                     transport: stub, retry: .none, makeSuffix: { "abcd1234" })
    }

    static func target(_ call: StubTransport.Call) -> String? { call.headers["X-Amz-Target"] }

    @Test func submitUploadsAndStartsJob() async throws {
        let stub = StubTransport { call in
            if call.method == "PUT" { return HTTPResponse(status: 200, body: Data()) }
            return .json(["TranscriptionJob": ["TranscriptionJobStatus": "QUEUED"]])
        }
        var settings = TranscribeSettings()
        settings.vocabularyName = "cappy-terms"
        let p = try provider(stub, settings: settings)
        let track = try makeTrack()
        let job = try await p.submit(track, options: TranscriptionOptions(language: "ja-JP", diarization: true, maxSpeakers: 4))

        #expect(job.id == "cappy-sess-1-remote-abcd1234")
        #expect(job.info["object"] == "s3://my-bucket/cappy/sess-1/transcribe/remote.flac")
        #expect(job.info["diarization"] == "true")
        #expect(job.info["track_offset_ms"] == "1500")

        let put = stub.calls[0]
        #expect(put.method == "PUT")
        #expect(put.url == "https://my-bucket.s3.ap-northeast-1.amazonaws.com/cappy/sess-1/transcribe/remote.flac")
        #expect(put.uploadedFile == track.url)
        #expect(put.headers["X-Amz-Content-Sha256"] == (try S3Client.sha256Hex(file: track.url)))
        #expect(put.headers["Authorization"]?.contains("/ap-northeast-1/s3/aws4_request") == true)
        #expect(put.headers["Content-Type"] == "audio/flac")

        let start = stub.calls[1]
        #expect(start.url == "https://transcribe.ap-northeast-1.amazonaws.com/")
        #expect(Self.target(start) == "Transcribe.StartTranscriptionJob")
        #expect(start.headers["Content-Type"] == "application/x-amz-json-1.1")
        #expect(start.headers["Authorization"]?.contains("/ap-northeast-1/transcribe/aws4_request") == true)
        let body = try #require(try JSONSerialization.jsonObject(with: start.body ?? Data()) as? [String: Any])
        #expect(body["TranscriptionJobName"] as? String == "cappy-sess-1-remote-abcd1234")
        #expect(body["LanguageCode"] as? String == "ja-JP")
        #expect(body["MediaFormat"] as? String == "flac")
        #expect((body["Media"] as? [String: String]) == ["MediaFileUri": "s3://my-bucket/cappy/sess-1/transcribe/remote.flac"])
        let s = try #require(body["Settings"] as? [String: Any])
        #expect(s["ShowSpeakerLabels"] as? Bool == true)
        #expect(s["MaxSpeakerLabels"] as? Int == 4)
        #expect(s["VocabularyName"] as? String == "cappy-terms")
        #expect(body["OutputBucketName"] == nil)
    }

    @Test func diarizationRejectedIsRetriedWithout() async throws {
        let starts = Counter()
        let stub = StubTransport { call in
            if call.method == "PUT" { return HTTPResponse(status: 200, body: Data()) }
            if starts.next() == 1 {
                return .json(["__type": "BadRequestException", "Message": "Speaker partitioning isn't supported for this language."], status: 400)
            }
            return .json([:])
        }
        let job = try await provider(stub).submit(try makeTrack(), options: TranscriptionOptions(language: "xx-XX", diarization: true))
        #expect(job.info["diarization"] == "false")
        #expect(job.info["diarization_note"]?.contains("Speaker partitioning") == true)
        let second = try #require(try JSONSerialization.jsonObject(with: stub.calls[2].body ?? Data()) as? [String: Any])
        #expect(second["Settings"] == nil)
    }

    @Test func uploadForbiddenHasHint() async throws {
        let stub = StubTransport { _ in
            HTTPResponse(status: 403, body: Data("<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>".utf8))
        }
        await #expect {
            _ = try await provider(stub).submit(try makeTrack(), options: TranscriptionOptions(language: "ja-JP", diarization: false))
        } throws: { e in
            (e as? CappyError)?.hint?.contains("s3:PutObject") == true
        }
    }

    @Test func statusMapping() async throws {
        for (status, expected) in [("QUEUED", JobStatus.pending), ("IN_PROGRESS", .running(progress: nil)), ("COMPLETED", .done),
                                   ("FAILED", .failed("bad audio"))] {
            let stub = StubTransport { _ in
                .json(["TranscriptionJob": ["TranscriptionJobStatus": status, "FailureReason": "bad audio"]])
            }
            let st = try await provider(stub).status(of: JobHandle(provider: "transcribe", track: .remote, id: "j1"))
            #expect(st == expected)
            let body = try #require(try JSONSerialization.jsonObject(with: stub.calls[0].body ?? Data()) as? [String: String])
            #expect(body == ["TranscriptionJobName": "j1"])
        }
        let missing = StubTransport { _ in
            .json(["__type": "BadRequestException", "Message": "The requested job couldn't be found."], status: 400)
        }
        let st = try await provider(missing).status(of: JobHandle(provider: "transcribe", track: .remote, id: "gone"))
        if case .failed = st {} else { Issue.record("failed になるはず: \(st)") }
    }

    @Test func resultDownloadsPresignedTranscript() async throws {
        let transcript = """
        {"results": {"items": [{"type": "pronunciation", "start_time": "0.5", "end_time": "1.0",
          "alternatives": [{"content": "はい", "confidence": "0.8"}]}]}}
        """
        let stub = StubTransport { call in
            if call.url.hasPrefix("https://s3.ap-northeast-1.amazonaws.com/aws-transcribe") {
                return HTTPResponse(status: 200, body: Data(transcript.utf8))
            }
            return .json(["TranscriptionJob": ["TranscriptionJobStatus": "COMPLETED",
                                               "Transcript": ["TranscriptFileUri": "https://s3.ap-northeast-1.amazonaws.com/aws-transcribe-x/j1.json?X-Amz-Signature=abc"]]])
        }
        let job = JobHandle(provider: "transcribe", track: .mic, id: "j1", info: ["track_offset_ms": "2000", "language": "ja-JP"])
        let segs = try await provider(stub).result(of: job)
        #expect(segs == [Segment(track: .mic, speaker: nil, startMs: 2500, endMs: 3000, text: "はい", confidence: 0.8)])
        #expect(stub.calls[1].headers["Authorization"] == nil)
    }

    @Test func cleanupDeletesObjectAndJob() async throws {
        let stub = StubTransport { call in
            // DeleteTranscriptionJob は本文が空の 200 を返す
            HTTPResponse(status: call.method == "DELETE" ? 204 : 200, body: Data())
        }
        try await provider(stub).cleanup(JobHandle(provider: "transcribe", track: .remote, id: "j1",
                                                   info: ["object": "s3://my-bucket/cappy/sess-1/transcribe/remote.flac"]))
        #expect(stub.calls.map(\.method) == ["DELETE", "POST"])
        #expect(stub.calls[0].url == "https://my-bucket.s3.ap-northeast-1.amazonaws.com/cappy/sess-1/transcribe/remote.flac")
        #expect(Self.target(stub.calls[1]) == "Transcribe.DeleteTranscriptionJob")
    }

    @Test func requiresBucket() {
        #expect(throws: CappyError.self) {
            try AmazonTranscribeProvider(settings: TranscribeSettings(), region: "ap-northeast-1", bucket: nil, credentials: Self.creds)
        }
    }
}

@Suite struct S3ClientTests {
    static let creds = StaticAWSCredentials(AWSCredentials(accessKeyID: "AK", secretAccessKey: "SK"))

    @Test func urls() {
        let s3 = S3Client(credentials: Self.creds, region: "ap-northeast-1")
        #expect(s3.url(bucket: "b", key: "a b/c+d.flac").absoluteString == "https://b.s3.ap-northeast-1.amazonaws.com/a%20b/c%2Bd.flac")
        #expect(s3.url(bucket: "my.bucket", key: "k").absoluteString == "https://s3.ap-northeast-1.amazonaws.com/my.bucket/k")
        #expect(s3.url(bucket: "b", query: "location=").absoluteString == "https://b.s3.ap-northeast-1.amazonaws.com/?location=")
        #expect(S3ObjectRef(uri: "s3://b/x/y.flac") == S3ObjectRef(bucket: "b", key: "x/y.flac"))
        #expect(S3ObjectRef(uri: "gs://b/x") == nil)
    }

    @Test func bucketRegionAndLifecycle() async throws {
        let stub = StubTransport { call in
            if call.url.hasSuffix("?location=") {
                return HTTPResponse(status: 200, body: Data(#"<?xml version="1.0"?><LocationConstraint xmlns="http://s3.amazonaws.com/doc/2006-03-01/">ap-northeast-1</LocationConstraint>"#.utf8))
            }
            return HTTPResponse(status: 200, body: Data("""
            <LifecycleConfiguration><Rule><ID>a</ID><Filter><Prefix>logs/</Prefix></Filter><Status>Enabled</Status>
            <Expiration><Days>30</Days></Expiration></Rule><Rule><ID>b</ID><Filter><Prefix></Prefix></Filter><Status>Enabled</Status>
            <Expiration><Days>1</Days></Expiration><NoncurrentVersionExpiration><NoncurrentDays>7</NoncurrentDays></NoncurrentVersionExpiration></Rule>
            </LifecycleConfiguration>
            """.utf8))
        }
        let s3 = S3Client(credentials: Self.creds, region: "ap-northeast-1", transport: stub, retry: .none)
        #expect(try await s3.bucketRegion("b") == "ap-northeast-1")
        let rules = try await s3.lifecycleRules("b")
        #expect(rules == [S3Client.LifecycleRule(enabled: true, prefix: "logs/", expirationDays: 30),
                          S3Client.LifecycleRule(enabled: true, prefix: "", expirationDays: 1)])

        let empty = StubTransport { _ in HTTPResponse(status: 200, body: Data("<LocationConstraint/>".utf8)) }
        #expect(try await S3Client(credentials: Self.creds, region: "us-east-1", transport: empty, retry: .none).bucketRegion("b") == "us-east-1")
        let none = StubTransport { _ in HTTPResponse(status: 404, body: Data("<Error><Code>NoSuchLifecycleConfiguration</Code></Error>".utf8)) }
        #expect(try await S3Client(credentials: Self.creds, region: "us-east-1", transport: none, retry: .none).lifecycleRules("b").isEmpty)
    }
}

@Suite struct TranscribeConfigTests {
    @Test func parsesTranscribeAndAWS() throws {
        let c = try CappyConfig.parse("""
        [profiles.a]
        provider = "transcribe"
        [profiles.a.aws]
        region = "ap-northeast-1"
        bucket = "my-cappy"
        delete_remote_after = false
        [profiles.a.transcribe]
        diarization = false
        max_speakers = 5
        vocabulary_name = "terms"
        """, path: URL(fileURLWithPath: "/tmp/x.toml"))
        let p = try c.profile(named: "a")
        #expect(p.provider == "transcribe")
        #expect(p.aws == AWSSettings(profile: nil, region: "ap-northeast-1", bucket: "my-cappy", deleteRemoteAfter: false))
        #expect(p.transcribe.diarization == false)
        #expect(p.transcribe.maxSpeakers == 5)
        #expect(p.transcribe.vocabularyName == "terms")
        #expect(throws: CappyError.self) {
            try CappyConfig.parse("[profiles.a.transcribe]\nmax_speakers = 31\n", path: URL(fileURLWithPath: "/tmp/x.toml"))
        }
    }
}
