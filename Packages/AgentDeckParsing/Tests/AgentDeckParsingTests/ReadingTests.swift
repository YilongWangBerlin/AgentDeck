import Foundation
import Testing
@testable import AgentDeckParsing

@Suite struct TimestampTests {
    @Test(arguments: [
        "2026-10-07T21:39:43.351Z",
        "2026-10-07T21:39:43Z",
        "2026-12-31T23:59:59.999Z",
        "2028-02-29T00:00:00.000Z",
        "1970-01-01T00:00:00Z",
        "2026-03-29T01:00:00.500Z",
    ])
    func fastPathAgreesWithFoundation(_ iso: String) throws {
        let fast = try #require(Timestamp.parseUTC(iso))
        let reference = try #require(Timestamp.parseWithFormatter(iso))
        #expect(abs(fast.timeIntervalSince(reference)) < 0.000_5)
    }

    @Test func extraFractionDigitsAreKept() throws {
        let date = try #require(Timestamp.parse("2026-10-07T21:39:43.351234Z"))
        let millis = try #require(Timestamp.parse("2026-10-07T21:39:43.351Z"))
        #expect(abs(date.timeIntervalSince(millis) - 0.000_234) < 0.000_001)
    }

    @Test func offsetsFallBackToTheFormatter() throws {
        let offset = try #require(Timestamp.parse("2026-10-07T23:39:43.351+02:00"))
        let utc = try #require(Timestamp.parse("2026-10-07T21:39:43.351Z"))
        #expect(Timestamp.parseUTC("2026-10-07T23:39:43.351+02:00") == nil)
        #expect(abs(offset.timeIntervalSince(utc)) < 0.000_5)
    }

    @Test(arguments: ["", "not a date", "2026-13-01T00:00:00Z", "2026-02-30T00:00:00Z", "2026-10-07T24:00:00Z", "2026-10-07T21:39:43.Z"])
    func invalidTimestampsAreRejected(_ iso: String) {
        #expect(Timestamp.parse(iso) == nil)
    }
}

@Suite struct JSONLReaderTests {
    private func lines(_ chunk: JSONLReader.Chunk) -> [String] {
        chunk.lines.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func anUnfinishedLastLineIsLeftForTheNextPass() {
        let chunk = JSONLReader.splitCompleteLines(Data("{\"a\":1}\n{\"b\":2}\n{\"c\"".utf8), baseOffset: 100)
        #expect(lines(chunk) == [#"{"a":1}"#, #"{"b":2}"#])
        #expect(chunk.endOffset == 116)
    }

    @Test func blankLinesAreSkippedButConsumed() {
        let data = Data("{}\n\n  \r\n{}\n".utf8)
        let chunk = JSONLReader.splitCompleteLines(data, baseOffset: 0)
        #expect(lines(chunk) == ["{}", "{}"])
        #expect(chunk.endOffset == UInt64(data.count))
    }

    @Test func readingResumesFromTheStoredOffset() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("log.jsonl")
        try Data("{\"n\":1}\n{\"n\":2".utf8).write(to: url)

        let first = try JSONLReader.readCompleteLines(from: url, startingAt: 0)
        #expect(lines(first) == [#"{"n":1}"#])

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("}\n{\"n\":3}\n".utf8))
        try handle.close()

        let second = try JSONLReader.readCompleteLines(from: url, startingAt: first.endOffset)
        #expect(lines(second) == [#"{"n":2}"#, #"{"n":3}"#])
    }

    @Test func anOffsetPastTheEndMeansTheFileWasReplaced() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("log.jsonl")
        try Data("{}\n".utf8).write(to: url)

        #expect(throws: JSONLReader.ReadError.offsetBeyondEndOfFile(fileSize: 3, offset: 10)) {
            try JSONLReader.readCompleteLines(from: url, startingAt: 10)
        }
    }
}

@Suite struct LogLocationsTests {
    let home = URL(fileURLWithPath: "/Users/test")

    @Test func defaultsWithoutEnvironment() {
        let locations = LogLocations.standard(environment: [:], homeDirectory: home)
        #expect(locations.claudeProjectDirectories.map(\.path) == ["/Users/test/.claude/projects", "/Users/test/.config/claude/projects"])
        #expect(locations.codexHome.path == "/Users/test/.codex")
        #expect(locations.codexImportsFile.path == "/Users/test/.codex/external_agent_session_imports.json")
        #expect(locations.claudePlanUsageFile?.path == "/Users/test/Library/Application Support/Claude/plan-usage-history.json")
    }

    @Test func environmentOverridesAreAddedOrUsed() {
        let locations = LogLocations.standard(
            environment: ["CLAUDE_CONFIG_DIR": "/data/claude", "CODEX_HOME": "/data/codex"],
            homeDirectory: home
        )
        #expect(locations.claudeProjectDirectories.map(\.path) == [
            "/data/claude/projects", "/Users/test/.claude/projects", "/Users/test/.config/claude/projects",
        ])
        #expect(locations.codexSessionDirectories.map(\.path) == ["/data/codex/sessions", "/data/codex/archived_sessions"])
    }

    @Test func blankOrDuplicateOverridesAreIgnored() {
        let locations = LogLocations.standard(
            environment: ["CLAUDE_CONFIG_DIR": "/Users/test/.claude", "CODEX_HOME": "  "],
            homeDirectory: home
        )
        #expect(locations.claudeProjectDirectories.count == 2)
        #expect(locations.codexHome.path == "/Users/test/.codex")
    }

    @Test func findsJSONLFilesRecursively() {
        let locations = LogLocations(claudeProjectDirectories: [Fixtures.claudeProjects], codexHome: Fixtures.codexHome)
        #expect(Set(locations.claudeLogFiles().map(\.lastPathComponent)) == Set(Fixtures.claudeFiles.map(\.lastPathComponent)))
        #expect(locations.codexLogFiles().count == Fixtures.codexFiles.count)
    }
}

@Suite struct ClaudePlanUsageTests {
    @Test func readsSamplesSkippingOddOnes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plan-usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"""
        {"version":2,"samples":[
          {"t":1791499740000,"org":"o","u":{"fh":0,"sd":32,"xu":0}},
          {"t":1791460800000,"org":"o","u":{"fh":"x","sd":23}},
          {"org":"o","u":{"fh":1}},
          {"t":1791460000000,"org":"o"}
        ]}
        """#.utf8).write(to: url)

        let samples = try ClaudePlanUsage.samples(from: url)
        #expect(samples == [
            ClaudePlanUsageSample(time: Date(timeIntervalSince1970: 1_791_460_800), organization: "o", fiveHourPercent: nil, sevenDayPercent: 23),
            ClaudePlanUsageSample(time: Date(timeIntervalSince1970: 1_791_499_740), organization: "o", fiveHourPercent: 0, sevenDayPercent: 32),
        ])
        #expect(try ClaudePlanUsage.samples(from: url.appendingPathExtension("missing")).isEmpty)
    }
}
