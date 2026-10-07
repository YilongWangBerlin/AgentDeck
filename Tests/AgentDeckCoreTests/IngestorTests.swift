import AgentDeckCore
import AgentDeckParsing
import Foundation
import Testing

@Suite struct IngestorTests {
    private func total(_ store: UsageStore, _ source: UsageSource) throws -> Int {
        try store.usage(source: source).reduce(0) { $0 + $1.tokens.total }
    }

    @Test func theFirstScanMatchesTheParserTotals() throws {
        let logs = try TestLogs()
        defer { logs.cleanUp() }
        let store = try UsageStore.inMemory()

        let report = try Ingestor(store: store, locations: logs.locations).ingest()

        #expect(report.filesSeen == 8 && report.filesParsed == 8 && report.failures.isEmpty)
        #expect(report.malformedLines == 1)
        #expect(try total(store, .claudeCode) == 131_042)
        #expect(try total(store, .codex) == 96_342)
        #expect(try store.counts() == StoreCounts(usage: 13, prompts: 2, rateLimits: 15, logFiles: 8))
    }

    @Test func aSecondScanReadsNothing() throws {
        let logs = try TestLogs()
        defer { logs.cleanUp() }
        let store = try UsageStore.inMemory()
        let ingestor = Ingestor(store: store, locations: logs.locations)
        _ = try ingestor.ingest()
        let before = try store.counts()

        let report = try ingestor.ingest()
        #expect(report.filesParsed == 0)
        #expect(try store.counts() == before)
    }

    @Test func appendedLinesAreReadIncrementallyOnceComplete() throws {
        let logs = try TestLogs()
        defer { logs.cleanUp() }
        let store = try UsageStore.inMemory()
        let ingestor = Ingestor(store: store, locations: logs.locations)
        _ = try ingestor.ingest()

        let line = #"{"isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_F","role":"assistant","stop_reason":"end_turn","usage":{"input_tokens":4,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":6}},"requestId":"req_F","type":"assistant","uuid":"f1","timestamp":"2026-10-05T14:00:00.000Z","sessionId":"22222222-2222-4222-8222-222222222222"}"#
        let half = line.index(line.startIndex, offsetBy: line.count / 2)

        try logs.append(String(line[..<half]), to: logs.claudeResumed)
        var report = try ingestor.ingest()
        #expect(report.filesParsed == 1 && report.usageRowsParsed == 0)

        try logs.append(String(line[half...]) + "\n", to: logs.claudeResumed)
        report = try ingestor.ingest()
        #expect(report.filesParsed == 1 && report.usageRowsParsed == 1 && report.filesRestarted == 0)
        #expect(try total(store, .claudeCode) == 131_052)
    }

    @Test func deletedLogFilesKeepTheirHistory() throws {
        let logs = try TestLogs()
        defer { logs.cleanUp() }
        let store = try UsageStore.inMemory()
        let ingestor = Ingestor(store: store, locations: logs.locations)
        _ = try ingestor.ingest()

        try FileManager.default.removeItem(at: logs.claudeSubagent)
        #expect(try ingestor.ingest().filesNewlyMissing == 1)
        #expect(try ingestor.ingest().filesNewlyMissing == 0)
        #expect(try total(store, .claudeCode) == 131_042)
    }

    @Test func aTruncatedFileIsReparsedWithoutDoubleCounting() throws {
        let logs = try TestLogs()
        defer { logs.cleanUp() }
        let store = try UsageStore.inMemory()
        let ingestor = Ingestor(store: store, locations: logs.locations)
        _ = try ingestor.ingest()

        let lines = try String(contentsOf: logs.claudeSession, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        try (lines.prefix(5).joined(separator: "\n") + "\n").write(to: logs.claudeSession, atomically: false, encoding: .utf8)

        let report = try ingestor.ingest()
        #expect(report.filesRestarted == 1)
        #expect(try total(store, .claudeCode) == 131_042)
    }

    @Test func fallbackRowsAreRetractedOnceTokenUsageRecordsAppear() throws {
        let logs = try TestLogs()
        defer { logs.cleanUp() }
        let full = try Data(contentsOf: logs.codexTransition)
        let thirdNewline = full.indices.filter { full[$0] == 0x0A }[2]
        try full.prefix(thirdNewline + 1).write(to: logs.codexTransition)

        let store = try UsageStore.inMemory()
        let ingestor = Ingestor(store: store, locations: logs.locations)
        _ = try ingestor.ingest()
        let thread5 = TestLogs.codexThread(5)
        #expect(try store.usage(source: .codex).filter { $0.sessionID == thread5 }.map(\.kind) == [.codexTokenCountFallback])

        try logs.append(String(decoding: full.dropFirst(thirdNewline + 1), as: UTF8.self), to: logs.codexTransition)
        let report = try ingestor.ingest()
        #expect(report.filesRestarted == 0)
        #expect(try store.usage(source: .codex).filter { $0.sessionID == thread5 }.map(\.messageID) == ["resp_006"])
        #expect(try total(store, .codex) == 96_342)
    }

    @Test func threadsListedAsImportsLaterArePurged() throws {
        let logs = try TestLogs()
        defer { logs.cleanUp() }
        let store = try UsageStore.inMemory()
        let ingestor = Ingestor(store: store, locations: logs.locations)
        _ = try ingestor.ingest()

        let imports = #"{"records":[{"imported_thread_id":"\#(TestLogs.codexThread(4))"},{"imported_thread_id":"\#(TestLogs.codexThread(3))"}]}"#
        try imports.write(to: logs.importsFile, atomically: true, encoding: .utf8)

        let report = try ingestor.ingest()
        #expect(report.importedRowsPurged == 2)
        #expect(try total(store, .codex) == 96_342 - 3_150)
        #expect(try ingestor.ingest().importedRowsPurged == 0)
    }

    @Test func anUnreadableFileDoesNotStopTheScan() throws {
        let logs = try TestLogs()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: logs.claudeSubagent.path)
            logs.cleanUp()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: logs.claudeSubagent.path)
        let store = try UsageStore.inMemory()

        let report = try Ingestor(store: store, locations: logs.locations).ingest()
        #expect(report.failures.count == 1)
        #expect(report.filesParsed == 7)
        #expect(try total(store, .claudeCode) == 131_042 - 1_260)
    }
}

@Suite struct LogWatcherTests {
    @Test func reportsChangesBelowAWatchedDirectory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("2026/10/08")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let changes = Counter()
        let watcher = LogWatcher(directories: [directory], latency: 0.1) { changes.increment() }
        #expect(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(500))

        try Data("{}\n".utf8).write(to: nested.appendingPathComponent("rollout.jsonl"))
        for _ in 0..<100 where changes.value == 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(changes.value > 0)
    }

    @Test func missingDirectoriesAreNotWatched() {
        let watcher = LogWatcher(directories: [URL(fileURLWithPath: "/nonexistent/agentdeck")]) {}
        #expect(!watcher.start())
    }
}
