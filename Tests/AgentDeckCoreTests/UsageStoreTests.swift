import AgentDeckCore
import AgentDeckParsing
import Foundation
import Testing

@Suite struct UsageStoreTests {
    let snapshot = UsageStore.FileSnapshot(size: 100, modifiedAt: 1, inode: 7)

    private func record(
        _ id: String, at iso: String, output: Int = 0, kind: UsageRecordKind = .response, source: UsageSource = .claudeCode
    ) -> UsageRecord {
        UsageRecord(source: source, messageID: id, sessionID: "s", timestamp: date(iso), model: "m",
                    tokens: TokenCounts(input: 1, output: output), kind: kind)
    }

    private func result(_ usage: [UsageRecord] = [], retract: Bool = false, limits: [RateLimitObservation] = [],
                        prompts: [PromptEvent] = []) -> ParseResult {
        var result = ParseResult()
        result.usage = usage
        result.retractFallbackUsage = retract
        result.rateLimits = limits
        result.prompts = prompts
        result.endOffset = 100
        return result
    }

    private func apply(_ store: UsageStore, _ result: ParseResult, file: LogFileRecord, restart: Bool = false) throws {
        try store.apply(result, to: file, parserState: nil, threadID: nil, snapshot: snapshot, restartedFromBeginning: restart)
    }

    @Test(arguments: [false, true])
    func upsertKeepsTheLargestValuesAndTheEarliestTime(finalLineFirst: Bool) throws {
        let store = try UsageStore.inMemory()
        let file = try store.registerLogFile(path: "/a.jsonl", source: .claudeCode)
        let partial = record("msg:req", at: "2026-10-05T09:33:00.100Z", output: 5)
        let final = record("msg:req", at: "2026-10-05T09:33:02.500Z", output: 367)

        for row in finalLineFirst ? [final, partial] : [partial, final] {
            try apply(store, result([row]), file: file)
        }

        let stored = try #require(try store.usage().first)
        #expect(try store.usage().count == 1)
        #expect(stored.tokens.output == 367)
        #expect(stored.timestamp == date("2026-10-05T09:33:00.100Z"))
    }

    @Test func retractionRemovesOnlyThatFilesFallbackRows() throws {
        let store = try UsageStore.inMemory()
        let a = try store.registerLogFile(path: "/a.jsonl", source: .codex)
        let b = try store.registerLogFile(path: "/b.jsonl", source: .codex)
        try apply(store, result([record("a:tc", at: "2026-10-06T00:00:00Z", kind: .codexTokenCountFallback, source: .codex)]), file: a)
        try apply(store, result([record("b:tc", at: "2026-10-06T00:00:00Z", kind: .codexTokenCountFallback, source: .codex)]), file: b)

        try apply(store, result([record("resp_a", at: "2026-10-06T00:00:01Z", source: .codex)], retract: true), file: a)
        #expect(try store.usage().map(\.messageID).sorted() == ["b:tc", "resp_a"])

        try apply(store, result(), file: b, restart: true)
        #expect(try store.usage().map(\.messageID) == ["resp_a"])
    }

    @Test func applyingTheSameResultTwiceAddsNothing() throws {
        let store = try UsageStore.inMemory()
        let file = try store.registerLogFile(path: "/a.jsonl", source: .claudeCode)
        let limits = [
            RateLimitObservation(source: .claudeCode, observedAt: date("2026-10-05T11:07:09.596Z"), windowMinutes: 300,
                                 usedPercent: nil, resetsAt: date("2026-10-05T14:30:00Z"), limitType: "five_hour", isRejection: true),
            RateLimitObservation(source: .codex, observedAt: date("2026-10-05T11:00:00Z"), windowMinutes: nil,
                                 usedPercent: nil, resetsAt: date("2026-10-05T14:30:00Z"), isRejection: false),
        ]
        let prompts = [PromptEvent(source: .claudeCode, id: "p1", sessionID: "s", timestamp: date("2026-10-05T09:00:00Z"))]
        let once = result([record("m:r", at: "2026-10-05T09:00:01Z")], limits: limits, prompts: prompts)

        try apply(store, once, file: file)
        try apply(store, once, file: file)

        let counts = try store.counts()
        #expect(counts == StoreCounts(usage: 1, prompts: 1, rateLimits: 2, logFiles: 1))
    }

    @Test func intervalQueriesIncludeTheStartAndExcludeTheEnd() throws {
        let store = try UsageStore.inMemory()
        let file = try store.registerLogFile(path: "/a.jsonl", source: .claudeCode)
        try apply(store, result([record("a", at: "2026-10-05T00:00:00Z"), record("b", at: "2026-10-06T00:00:00Z")]), file: file)

        let day = DateInterval(start: date("2026-10-05T00:00:00Z"), end: date("2026-10-06T00:00:00Z"))
        #expect(try store.usage(in: day).map(\.messageID) == ["a"])
        #expect(try store.usage(source: .codex).isEmpty)
    }

    @Test func latestRateLimitsKeepsTheNewestValuePerWindow() throws {
        let store = try UsageStore.inMemory()
        let file = try store.registerLogFile(path: "/a.jsonl", source: .codex)
        func codex(_ minutes: Int, _ percent: Double, _ iso: String) -> RateLimitObservation {
            RateLimitObservation(source: .codex, observedAt: date(iso), windowMinutes: minutes, usedPercent: percent,
                                 resetsAt: date("2026-10-09T00:00:00Z"), limitID: "codex", planType: "plus", isRejection: false)
        }
        try apply(store, result(limits: [
            codex(300, 10, "2026-10-07T01:00:00Z"),
            codex(300, 20, "2026-10-07T01:10:00Z"),
            codex(10_080, 60, "2026-10-07T01:00:00Z"),
        ]), file: file)

        let latest = try store.latestRateLimits()
        #expect(latest.map(\.windowMinutes) == [300, 10_080])
        #expect(latest.map(\.usedPercent) == [20, 60])
        #expect(try store.rateLimits(since: date("2026-10-07T01:05:00Z")).count == 1)
    }

    @Test func fileStateAndMissingFlagArePersisted() throws {
        let store = try UsageStore.inMemory()
        let file = try store.registerLogFile(path: "/a.jsonl", source: .codex)
        try store.apply(result(), to: file, parserState: Data("{}".utf8), threadID: "t1", snapshot: snapshot)

        var stored = try #require(try store.logFiles()["/a.jsonl"])
        #expect(stored.byteOffset == 100 && stored.fileSize == 100 && stored.inode == 7 && stored.modifiedAt == 1)
        #expect(stored.parserState == Data("{}".utf8) && stored.threadID == "t1" && !stored.isMissing)

        #expect(try store.markMissing(paths: ["/a.jsonl"]) == 1)
        #expect(try store.markMissing(paths: ["/a.jsonl"]) == 0)
        stored = try #require(try store.logFiles()["/a.jsonl"])
        #expect(stored.isMissing)
    }

    @Test func purgingAThreadRemovesItsRows() throws {
        let store = try UsageStore.inMemory()
        let file = try store.registerLogFile(path: "/a.jsonl", source: .codex)
        try store.apply(result([record("r1", at: "2026-10-06T00:00:00Z", source: .codex)]), to: file,
                        parserState: nil, threadID: "t1", snapshot: snapshot)

        #expect(try store.purgeCodexThreads(["other"]) == 0)
        #expect(try store.purgeCodexThreads(["t1"]) == 1)
        #expect(try store.usage().isEmpty)
    }

    @Test func aDatabaseFileSurvivesReopening() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/agentdeck.sqlite")

        do {
            let store = try UsageStore(url: url)
            let file = try store.registerLogFile(path: "/a.jsonl", source: .claudeCode)
            try apply(store, result([record("m:r", at: "2026-10-05T09:00:00Z", output: 3)]), file: file)
        }
        let reopened = try UsageStore(url: url)
        #expect(try reopened.usage().map(\.tokens.output) == [3])
    }
}
