import Foundation
import Security
import Testing
@testable import CappyKit

@Suite struct GoogleResultParserTests {
    @Test func durations() {
        #expect(GoogleResultParser.durationMs("1.500s") == 1500)
        #expect(GoogleResultParser.durationMs("12s") == 12000)
        #expect(GoogleResultParser.durationMs(["seconds": "3", "nanos": 250_000_000]) == 3250)
        #expect(GoogleResultParser.durationMs(nil) == nil)
    }

    @Test func diarizedWordsAreSplitBySpeaker() throws {
        let json = """
        {"results": [
          {"alternatives": [{"transcript": "こんにちは。よろしく。", "confidence": 0.9,
            "words": [
              {"word": "こんにちは", "startOffset": "0.100s", "endOffset": "0.800s", "speakerLabel": "1", "confidence": 0.9},
              {"word": "。", "startOffset": "0.800s", "endOffset": "0.800s", "speakerLabel": "1", "confidence": 0.9},
              {"word": "よろしく", "startOffset": "1.200s", "endOffset": "1.900s", "speakerLabel": "2", "confidence": 0.7}
            ]}],
           "resultEndOffset": "2s", "languageCode": "ja-jp"},
          {"alternatives": [{}], "resultEndOffset": "3s"}
        ]}
        """
        let segs = try GoogleResultParser.segments(fromJSON: Data(json.utf8), track: .remote, offsetMs: 10_000, language: "ja-JP")
        #expect(segs.count == 2)
        #expect(segs[0] == Segment(track: .remote, speaker: "1", startMs: 10_100, endMs: 10_800, text: "こんにちは。", confidence: 0.9))
        #expect(segs[1].speaker == "2")
        #expect(segs[1].startMs == 11_200)
        #expect(segs[1].text == "よろしく")
    }

    @Test func withoutWordsUsesResultOffsets() throws {
        let json = """
        {"results": [
          {"alternatives": [{"transcript": " first ", "confidence": 0.8}], "resultEndOffset": "2.5s"},
          {"alternatives": [{"transcript": "second"}], "resultEndOffset": "4s"}
        ]}
        """
        let segs = try GoogleResultParser.segments(fromJSON: Data(json.utf8), track: .mic, offsetMs: 0, language: "en-US")
        #expect(segs.map(\.startMs) == [0, 2500])
        #expect(segs.map(\.endMs) == [2500, 4000])
        #expect(segs[0].text == "first")
        #expect(segs[0].speaker == nil)
    }

    @Test func wordsWithoutSpeakersKeepTranscript() throws {
        let json = """
        {"results": [{"alternatives": [{"transcript": "hello world",
          "words": [{"word": "hello", "startOffset": "1s", "endOffset": "1.5s"}, {"word": "world", "startOffset": "1.6s", "endOffset": "2s"}]}],
          "resultEndOffset": "2.2s"}]}
        """
        let segs = try GoogleResultParser.segments(fromJSON: Data(json.utf8), track: .mic, offsetMs: 0, language: "en-US")
        #expect(segs == [Segment(track: .mic, speaker: nil, startMs: 1000, endMs: 2000, text: "hello world", confidence: nil)])
    }

    @Test func snakeCaseKeys() throws {
        let json = """
        {"results": [{"alternatives": [{"transcript": "x", "words": [{"word": "x", "start_offset": "1s", "end_offset": "2s", "speaker_label": "A"}]}],
          "result_end_offset": "2s"}]}
        """
        let segs = try GoogleResultParser.segments(fromJSON: Data(json.utf8), track: .remote, offsetMs: 0, language: "ja-JP")
        #expect(segs.first?.speaker == "A")
        #expect(segs.first?.startMs == 1000)
    }
}

@Suite struct GoogleProviderTests {
    func settings() -> GoogleSettings {
        var g = GoogleSettings()
        g.projectID = "proj"
        g.bucket = "bkt"
        return g
    }

    func makeTrack() throws -> AudioTrack {
        let dir = try TestSupport.tempDir()
        let caf = dir.appendingPathComponent("remote.caf")
        try TestSupport.writeSineCAF(caf, seconds: 1, channels: 2)
        let r = try SendFileConverter.convert(input: caf, outputBase: dir.appendingPathComponent("remote"))
        return AudioTrack(id: .remote, url: r.url, offsetMs: 0, durationMs: r.durationMs, sessionID: "sid")
    }

    nonisolated(unsafe) static let resultJSON: [String: Any] = [
        "results": [["alternatives": [["transcript": "テスト", "confidence": 0.95,
                                       "words": [["word": "テスト", "startOffset": "0.2s", "endOffset": "0.9s"]]]],
                     "resultEndOffset": "1s"]],
    ]

    @Test func fullFlowWithDiarizationFallback() async throws {
        let track = try makeTrack()
        let opName = "projects/proj/locations/us/operations/op1"
        let audioURI = "gs://bkt/cappy/sid/remote.flac"
        let resultURI = "gs://bkt/cappy/sid/results/remote/remote_transcript_x.json"
        let stub = StubTransport { call in
            switch (call.method, call.url) {
            case ("POST", let u) where u.hasPrefix("https://storage.googleapis.com/upload/"):
                return .json(["name": "cappy/sid/remote.flac"])
            case ("POST", let u) where u.hasSuffix(":batchRecognize"):
                let body = try! JSONSerialization.jsonObject(with: call.body!) as! [String: Any]
                let features = (body["config"] as! [String: Any])["features"] as! [String: Any]
                if features["diarizationConfig"] != nil {
                    return .json(["error": ["code": 400, "status": "INVALID_ARGUMENT",
                                            "message": "Recognizer does not support feature: speaker_diarization"]], status: 400)
                }
                return .json(["name": opName])
            case ("GET", let u) where u.hasSuffix(opName):
                return .json(["name": opName, "done": true,
                              "response": ["results": [audioURI: ["cloudStorageResult": ["uri": resultURI]]]]])
            case ("GET", let u) where u.contains("/o/cappy%2Fsid%2Fresults%2Fremote%2Fremote_transcript_x.json?alt=media"):
                return .json(Self.resultJSON)
            case ("GET", let u) where u.contains("/o?prefix="):
                return .json(["items": [["name": "cappy/sid/results/remote/remote_transcript_x.json"]]])
            case ("DELETE", _):
                return HTTPResponse(status: 204, body: Data())
            default:
                return .json(["error": ["code": 404, "message": "unexpected \(call.method) \(call.url)"]], status: 404)
            }
        }
        let provider = try GoogleSpeechProvider(settings: settings(), auth: StaticToken(), transport: stub, retry: .none)
        let job = try await provider.submit(track, options: TranscriptionOptions(language: "ja-JP", diarization: true))
        #expect(job.id == opName)
        #expect(job.info["diarization"] == "false")
        #expect(job.info["diarization_note"]?.contains("speaker_diarization") == true)

        let batch = stub.calls.filter { $0.url.hasSuffix(":batchRecognize") }
        #expect(batch.count == 2)
        #expect(batch[0].url == "https://us-speech.googleapis.com/v2/projects/proj/locations/us/recognizers/_:batchRecognize")
        #expect(batch[0].headers["Authorization"] == "Bearer test-token")
        #expect(batch[0].headers["x-goog-user-project"] == "proj")
        let body = try JSONSerialization.jsonObject(with: batch[1].body!) as! [String: Any]
        let config = body["config"] as! [String: Any]
        #expect(config["model"] as? String == "chirp_3")
        #expect(config["languageCodes"] as? [String] == ["ja-JP"])
        #expect(((config["features"] as! [String: Any])["enableWordTimeOffsets"] as? Bool) == true)
        #expect((body["files"] as? [[String: String]])?.first?["uri"] == audioURI)
        #expect(((body["recognitionOutputConfig"] as! [String: Any])["gcsOutputConfig"] as! [String: String])["uri"]
                == "gs://bkt/cappy/sid/results/remote/")

        #expect(try await provider.status(of: job) == .done)
        let segs = try await provider.result(of: job)
        #expect(segs == [Segment(track: .remote, speaker: nil, startMs: 200, endMs: 900, text: "テスト", confidence: 0.95)])

        try await provider.cleanup(job)
        let deletes = stub.calls.filter { $0.method == "DELETE" }.map(\.url)
        #expect(deletes.count == 2)
        #expect(deletes.contains { $0.hasSuffix("/o/cappy%2Fsid%2Fremote.flac") })
    }

    @Test func runningAndFailedStatus() async throws {
        let stub = StubTransport { call in
            if call.url.hasSuffix("op-running") {
                return .json(["name": "op-running", "metadata": ["progressPercent": 42]])
            }
            if call.url.hasSuffix("op-file-error") {
                return .json(["name": "op-file-error", "done": true,
                              "response": ["results": ["gs://b/x.flac": ["error": ["code": 3, "message": "bad audio"]]]]])
            }
            return .json(["name": "op-error", "done": true, "error": ["code": 7, "message": "permission denied"]])
        }
        let provider = try GoogleSpeechProvider(settings: settings(), auth: StaticToken(), transport: stub, retry: .none)
        func job(_ id: String) -> JobHandle { JobHandle(provider: "google", track: .mic, id: id) }
        #expect(try await provider.status(of: job("op-running")) == .running(progress: 42))
        #expect(try await provider.status(of: job("op-file-error")) == .failed("bad audio"))
        #expect(try await provider.status(of: job("op-error")) == .failed("permission denied"))
    }

    @Test func transientErrorsAreRetried() async throws {
        let counter = Counter()
        let stub = StubTransport { _ in
            if counter.next() < 3 { return .json(["error": ["code": 503, "message": "unavailable"]], status: 503) }
            return .json(["name": "op", "metadata": [:]])
        }
        var retry = RetryPolicy()
        retry.sleep = { _ in }
        let provider = try GoogleSpeechProvider(settings: settings(), auth: StaticToken(), transport: stub, retry: retry)
        #expect(try await provider.status(of: JobHandle(provider: "google", track: .mic, id: "op")) == .running(progress: nil))
        #expect(stub.calls.count == 3)
    }

    @Test func permanentErrorsAreNotRetried() async throws {
        let stub = StubTransport { _ in .json(["error": ["code": 403, "status": "PERMISSION_DENIED", "message": "nope"]], status: 403) }
        var retry = RetryPolicy()
        retry.sleep = { _ in }
        let provider = try GoogleSpeechProvider(settings: settings(), auth: StaticToken(), transport: stub, retry: retry)
        await #expect(throws: GoogleAPIError.self) {
            _ = try await provider.status(of: JobHandle(provider: "google", track: .mic, id: "op"))
        }
        #expect(stub.calls.count == 1)
    }

    @Test func requiresProjectAndBucket() {
        #expect(throws: CappyError.self) { try GoogleSpeechProvider(settings: GoogleSettings(), auth: StaticToken()) }
    }

    @Test func splitsLongAudioIntoChunks() async throws {
        let dir = try TestSupport.tempDir()
        let caf = dir.appendingPathComponent("mic.caf")
        try TestSupport.writeSineCAF(caf, seconds: 5, channels: 1)
        let r = try SendFileConverter.convert(input: caf, outputBase: dir.appendingPathComponent("mic"))
        let track = AudioTrack(id: .mic, url: r.url, offsetMs: 0, durationMs: r.durationMs, sessionID: "sid")
        let stub = StubTransport { call in
            if call.url.hasSuffix(":batchRecognize") { return .json(["name": "op"]) }
            return .json([:])
        }
        var s = settings()
        s.chunkMinutes = 0
        let provider = try GoogleSpeechProvider(settings: s, auth: StaticToken(), transport: stub, retry: .none)
        // chunk_minutes は分単位なので、ここでは effectiveChunkSeconds を直接使わず split を確認する
        let chunks = try SendFileConverter.split(r.url, maxSeconds: 2, into: dir.appendingPathComponent("c"))
        #expect(chunks.count == 3)
        let job = try await provider.submit(track, options: TranscriptionOptions(language: "ja-JP", diarization: false))
        #expect(job.info["diarization"] == "false")
        // 一時ファイルは消える
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".chunks-mic").path))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

@Suite struct GoogleAuthTests {
    /// PKCS#1 の RSA 鍵を PKCS#8 PrivateKeyInfo に包む（テスト用の最小 DER エンコーダ）
    static func wrapPKCS8(_ pkcs1: Data) -> Data {
        func len(_ n: Int) -> [UInt8] {
            if n < 0x80 { return [UInt8(n)] }
            var bytes: [UInt8] = []
            var v = n
            while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        let version: [UInt8] = [0x02, 0x01, 0x00]
        let alg: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let octet: [UInt8] = [0x04] + len(pkcs1.count) + [UInt8](pkcs1)
        let body = version + alg + octet
        return Data([0x30] + len(body.count) + body)
    }

    @Test func pkcs8ServiceAccountKeySignsJWT() throws {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error)!
        let pkcs1 = SecKeyCopyExternalRepresentation(key, &error)! as Data
        let pkcs8 = Self.wrapPKCS8(pkcs1)
        #expect(try RSAKey.pkcs1(fromPKCS8: pkcs8) == pkcs1)

        let pem = "-----BEGIN PRIVATE KEY-----\n" + pkcs8.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) + "\n-----END PRIVATE KEY-----\n"
        let loaded = try RSAKey.privateKey(fromPEM: pem)
        let jwt = try JWT.sign(email: "sa@proj.iam.gserviceaccount.com", scope: "s", audience: "https://oauth2.googleapis.com/token",
                               key: loaded, keyID: "kid1", now: Date(timeIntervalSince1970: 1000))
        let parts = jwt.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        func b64(_ s: String) -> Data {
            var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while t.count % 4 != 0 { t += "=" }
            return Data(base64Encoded: t)!
        }
        let claims = try JSONSerialization.jsonObject(with: b64(parts[1])) as! [String: Any]
        #expect(claims["iss"] as? String == "sa@proj.iam.gserviceaccount.com")
        #expect(claims["exp"] as? Int == 4600)
        let header = try JSONSerialization.jsonObject(with: b64(parts[0])) as! [String: String]
        #expect(header["kid"] == "kid1")
        let pub = SecKeyCopyPublicKey(key)!
        let ok = SecKeyVerifySignature(pub, .rsaSignatureMessagePKCS1v15SHA256,
                                       Data("\(parts[0]).\(parts[1])".utf8) as CFData, b64(parts[2]) as CFData, &error)
        #expect(ok)
    }

    @Test func authorizedUserRefresh() async throws {
        let json = #"{"type":"authorized_user","client_id":"cid","client_secret":"sec","refresh_token":"rt","quota_project_id":"qp"}"#
        let stub = StubTransport { call in
            let body = String(decoding: call.body ?? Data(), as: UTF8.self)
            guard call.url == "https://oauth2.googleapis.com/token", body.contains("grant_type=refresh_token"),
                  body.contains("refresh_token=rt") else { return .json([:], status: 400) }
            return .json(["access_token": "ya29.x", "expires_in": 3599])
        }
        let creds = try ApplicationDefaultCredentials.parse(Data(json.utf8), path: "/tmp/adc.json", transport: stub)
        #expect(try await creds.accessToken() == "ya29.x")
        #expect(try await creds.accessToken() == "ya29.x")
        #expect(stub.calls.count == 1) // キャッシュされる
        #expect(await creds.quotaProjectID == "qp")
    }

    @Test func refreshFailureIsTranscriptionError() async throws {
        let json = #"{"type":"authorized_user","client_id":"cid","client_secret":"sec","refresh_token":"rt"}"#
        let stub = StubTransport { _ in .json(["error": "invalid_grant", "error_description": "Token has been expired"], status: 400) }
        let creds = try ApplicationDefaultCredentials.parse(Data(json.utf8), path: "/tmp/adc.json", transport: stub)
        do {
            _ = try await creds.accessToken()
            Issue.record("should throw")
        } catch let e as CappyError {
            #expect(e.status == .transcription)
            #expect(e.message.contains("Token has been expired"))
        }
    }

    @Test func unsupportedType() {
        #expect(throws: CappyError.self) {
            try ApplicationDefaultCredentials.parse(Data(#"{"type":"external_account"}"#.utf8), path: "/x", transport: StubTransport { _ in .json([:]) })
        }
    }

    @Test func helpers() {
        #expect(GCSObjectRef(uri: "gs://b/a/b.json") == GCSObjectRef(bucket: "b", name: "a/b.json"))
        #expect(GCSObjectRef(uri: "s3://b/x") == nil)
        #expect(GCSClient.encodeObject("cappy/a b.flac") == "cappy%2Fa%20b.flac")
        #expect(FormEncoding.encode(["b": "x y", "a": "1&2"]) == "a=1%262&b=x%20y")
    }
}
