import Foundation
import Testing
@testable import CappyKit

@Suite struct TOMLTests {
    @Test func parsesTablesAndValues() throws {
        let doc = try TOML.parse("""
        # comment
        title = "cappy"   # trailing
        count = 1_000
        ratio = 0.5
        on = true
        list = ["a", 'b', 3]

        [profiles.default]
        provider = "google"

        [profiles.default.google]
        project_id = "my-project"
        "quoted key" = 'C:\\path'
        a.b = "dotted"
        """)
        #expect(doc["title"]?.string == "cappy")
        #expect(doc["count"]?.int == 1000)
        #expect(doc["ratio"]?.double == 0.5)
        #expect(doc["on"]?.bool == true)
        #expect(doc["list"]?.array?.count == 3)
        #expect(doc["profiles"]?["default"]?["provider"]?.string == "google")
        #expect(doc["profiles"]?["default"]?["google"]?["project_id"]?.string == "my-project")
        #expect(doc["profiles"]?["default"]?["google"]?["quoted key"]?.string == "C:\\path")
        #expect(doc["profiles"]?["default"]?["google"]?["a"]?["b"]?.string == "dotted")
    }

    @Test func escapes() throws {
        let doc = try TOML.parse(#"s = "a\tb\n\u3042\"""#)
        #expect(doc["s"]?.string == "a\tb\nあ\"")
    }

    @Test func rejectsDuplicateKeys() {
        #expect(throws: TOMLError.self) { try TOML.parse("a = 1\na = 2") }
    }

    @Test func rejectsGarbage() {
        #expect(throws: TOMLError.self) { try TOML.parse("a = ") }
        #expect(throws: TOMLError.self) { try TOML.parse("a = \"unterminated") }
        #expect(throws: TOMLError.self) { try TOML.parse("[[arr]]") }
        #expect(throws: TOMLError.self) { try TOML.parse("a = 1 b") }
    }
}

@Suite struct ConfigTests {
    let specExample = """
    [profiles.default]
    language = "ja-JP"
    output_dir = "~/Recordings/cappy"

    [profiles.default.google]
    project_id = "my-project"
    bucket = "my-cappy-bucket"
    delete_remote_after = true

    [profiles.default.transcribe]
    provider = "google"
    model = "chirp_3"
    location = "us"

    [profiles.client-a]
    output_dir = "/tmp/client-a"

    [profiles.client-a.transcribe]
    provider = "none"
    """

    @Test func parsesSpecExample() throws {
        let c = try CappyConfig.parse(specExample, path: URL(fileURLWithPath: "/tmp/config.toml"))
        let p = try c.profile(named: nil)
        #expect(p.provider == "google")
        #expect(p.language == "ja-JP")
        #expect(p.outputDirectoryURL.path == FileSecurity.expandTilde("~/Recordings/cappy"))
        #expect(p.google.projectID == "my-project")
        #expect(p.google.bucket == "my-cappy-bucket")
        #expect(p.google.model == "chirp_3")
        #expect(p.google.deleteRemoteAfter)
        #expect(p.google.effectiveChunkSeconds == 19 * 60)
        let a = try c.profile(named: "client-a")
        #expect(a.provider == "none")
        #expect(a.outputDir == "/tmp/client-a")
    }

    @Test func unknownProfileIsUsageError() throws {
        let c = try CappyConfig.parse(specExample, path: URL(fileURLWithPath: "/tmp/config.toml"))
        do {
            _ = try c.profile(named: "nope")
            Issue.record("should throw")
        } catch let e as CappyError {
            #expect(e.status == .usage)
        }
    }

    @Test func missingFileGivesDefaults() throws {
        let c = try CappyConfig.load(from: URL(fileURLWithPath: "/nonexistent/cappy/config.toml"))
        #expect(!c.fileExists)
        let p = try c.profile(named: "default")
        #expect(p.provider == "google")
        #expect(p.transcriptionService == .gemini)
        #expect(p.google.location == "us")
    }

    @Test func invalidTypesAreRejected() {
        #expect(throws: CappyError.self) {
            try CappyConfig.parse("[profiles.default.transcribe]\nprovider = 1", path: URL(fileURLWithPath: "/x"))
        }
        #expect(throws: CappyError.self) {
            try CappyConfig.parse("[profiles.default.transcribe]\nprovider = \"whisper\"", path: URL(fileURLWithPath: "/x"))
        }
        #expect(throws: CappyError.self) {
            try CappyConfig.parse("[profiles.default.google]\ndelete_remote_after = \"yes\"", path: URL(fileURLWithPath: "/x"))
        }
    }

    @Test func chunkMinutesOverride() throws {
        let c = try CappyConfig.parse("""
        [profiles.default.transcribe]
        model = "chirp_3"
        word_timestamps = false
        """, path: URL(fileURLWithPath: "/x"))
        #expect(try c.profile(named: nil).google.effectiveChunkSeconds == 59 * 60)
        let d = try CappyConfig.parse("""
        [profiles.default.transcribe]
        model = "chirp_3"
        chunk_minutes = 10
        """, path: URL(fileURLWithPath: "/x"))
        #expect(try d.profile(named: nil).google.effectiveChunkSeconds == 600)
    }
}

@Suite struct DurationTests {
    @Test(arguments: [("90m", 5400.0), ("1h30m", 5400.0), ("45s", 45.0), ("1h", 3600.0), ("3600", 3600.0), ("1.5h", 5400.0), ("2m30s", 150.0)])
    func parses(_ input: String, _ expected: Double) throws {
        #expect(try DurationParser.parse(input) == expected)
    }

    @Test(arguments: ["", "abc", "10x", "1h30", "-5", "0", "m"])
    func rejects(_ input: String) {
        #expect(throws: CappyError.self) { try DurationParser.parse(input) }
    }

    @Test func timeFormats() {
        #expect(TimeFormat.hms(ms: 3_723_456) == "01:02:03")
        #expect(TimeFormat.srt(ms: 3_723_456) == "01:02:03,456")
        #expect(TimeFormat.srt(ms: -5) == "00:00:00,000")
        #expect(TimeFormat.elapsed(65) == "01:05")
        #expect(TimeFormat.elapsed(3725) == "1:02:05")
    }
}
