import Foundation
import Testing
@testable import AgentDeckParsing

@Suite struct CodexParserTests {
    let parser = CodexParser(importedThreadIDs: [Fixtures.codexThread(4)])

    private func parse(_ url: URL, with parser: CodexParser? = nil) throws -> ParseResult {
        var state = CodexFileState()
        return try (parser ?? self.parser).parse(fileAt: url, state: &state)
    }

    @Test func eachTokenUsageRecordIsOneRowWithCachedTokensMovedOutOfInput() throws {
        let result = try parse(Fixtures.codexMain)

        #expect(result.usage.map(\.messageID) == ["resp_001", "resp_002", "resp_003", "resp_004"])
        #expect(result.usage.allSatisfy { $0.kind == .response && $0.sessionID == Fixtures.codexThread(1) })
        #expect(result.usage[0].tokens == TokenCounts(input: 14_093, output: 365, cacheRead: 22_144))
        #expect(result.usage[1].tokens == TokenCounts(input: 4_000, output: 900, cacheRead: 36_000, reasoning: 300))
        #expect(result.usage[0].timestamp == Fixtures.date("2026-10-05T23:02:54.678Z"))
    }

    @Test func theModelComesFromTheTurnContext() throws {
        // resp_004 names a turn with no turn_context, so it takes the most recent model.
        let result = try parse(Fixtures.codexMain)
        #expect(result.usage.map(\.model) == ["gpt-6.1-sol", "gpt-6.1-sol", "gpt-6-astra", "gpt-6-astra"])
    }

    @Test func rateLimitsAreReadFromTokenCountEvents() throws {
        // The "premium" limit has no windows, and one event has rate_limits: null.
        let result = try parse(Fixtures.codexMain)
        let observedAt = Fixtures.date("2026-10-05T23:02:55.678Z")
        #expect(result.rateLimits == [
            RateLimitObservation(
                source: .codex, observedAt: observedAt, windowMinutes: 300, usedPercent: 12,
                resetsAt: Date(timeIntervalSince1970: 1_791_345_766), limitID: "codex", planType: "plus",
                isRejection: false
            ),
            RateLimitObservation(
                source: .codex, observedAt: observedAt, windowMinutes: 10_080, usedPercent: 51,
                resetsAt: Date(timeIntervalSince1970: 1_791_584_839), limitID: "codex", planType: "plus",
                isRejection: false
            ),
        ])
    }

    @Test func aGuardianThreadCountsTowardItsParentSession() throws {
        // Its token_count reports the parent's 20M cumulative total, which must not leak in.
        let result = try parse(Fixtures.codexGuardian)
        let row = try #require(result.usage.first)
        #expect(result.usage.count == 1)
        #expect(row.sessionID == Fixtures.codexThread(1))
        #expect(row.model == "codex-auto-review")
        #expect(row.tokens == TokenCounts(input: 1_000, output: 50, cacheRead: 1_000))
    }

    @Test func aFileWithoutTokenUsageRecordsFallsBackToTokenCount() throws {
        // The second event repeats the first one's totals and is skipped.
        let result = try parse(Fixtures.codexLegacy)

        #expect(result.usage.count == 2)
        #expect(result.usage.allSatisfy { $0.kind == .codexTokenCountFallback })
        #expect(result.usage.allSatisfy { $0.sessionID == Fixtures.codexThread(3) && $0.model == "gpt-5.6-sol" })
        #expect(result.usage.map(\.tokens) == [
            TokenCounts(input: 800, output: 50, cacheRead: 200, reasoning: 10),
            TokenCounts(input: 1_000, output: 100, cacheRead: 1_000, reasoning: 20),
        ])
        #expect(result.rateLimits.count == 6)
        #expect(try parse(Fixtures.codexLegacy).usage.map(\.messageID) == result.usage.map(\.messageID))
    }

    @Test func importedSessionsAreSkipped() throws {
        let listed = try parse(Fixtures.codexImported)
        #expect(listed.usage.isEmpty && listed.rateLimits.isEmpty)
        let size = try Data(contentsOf: Fixtures.codexImported).count
        #expect(listed.endOffset == UInt64(size))

        // Without the imports list, the file still yields nothing: it has no turn_context and its
        // token_count has no rate_limits.
        let unlisted = try parse(Fixtures.codexImported, with: CodexParser())
        #expect(unlisted.usage.isEmpty)
    }

    @Test func theFirstTokenUsageRecordRetractsFallbackRows() throws {
        let result = try parse(Fixtures.codexTransition)

        #expect(result.retractFallbackUsage)
        #expect(result.usage.map(\.messageID) == ["resp_006"])
        #expect(result.rateLimits.map(\.isRejection) == [false, false, true, true])
    }

    @Test func retractionWorksAcrossIncrementalPasses() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = Fixtures.codexTransition
        let data = try Data(contentsOf: url)
        let thirdNewline = data.indices.filter { data[$0] == 0x0A }[2]

        var state = CodexFileState()
        let first = try parser.parse(
            fileAt: Fixtures.prefixCopy(of: url, byteCount: thirdNewline + 20, in: directory), state: &state
        )
        #expect(first.usage.map(\.kind) == [.codexTokenCountFallback])
        #expect(!first.retractFallbackUsage)

        let second = try parser.parse(fileAt: url, from: first.endOffset, state: &state)
        #expect(second.retractFallbackUsage)
        #expect(second.usage.map(\.messageID) == ["resp_006"])

        var accumulator = UsageAccumulator()
        accumulator.apply(first, fileKey: url.path)
        accumulator.apply(second, fileKey: url.path)
        #expect(accumulator.records.values.map(\.messageID) == ["resp_006"])
    }

    @Test func totalsAcrossAllFixtures() throws {
        var accumulator = UsageAccumulator()
        for url in Fixtures.codexFiles {
            accumulator.apply(try parse(url), fileKey: url.path)
        }
        let totals = accumulator.totals()

        #expect(totals == TokenCounts(input: 25_393, output: 1_605, cacheRead: 69_344, cacheWrite: 0, reasoning: 380))
        #expect(totals.total == 96_342)
        #expect(Set(accumulator.records.values.map(\.sessionID)) == Set([1, 3, 5].map(Fixtures.codexThread)))
    }

    @Test func parsingInTwoPassesMatchesASinglePass() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for url in Fixtures.codexFiles {
            let single = try parse(url)
            var expected = UsageAccumulator()
            expected.apply(single, fileKey: url.path)

            let size = try Data(contentsOf: url).count
            for cut in stride(from: 0, through: size, by: 5) {
                var state = CodexFileState()
                let first = try parser.parse(fileAt: Fixtures.prefixCopy(of: url, byteCount: cut, in: directory), state: &state)
                let second = try parser.parse(fileAt: url, from: first.endOffset, state: &state)
                var actual = UsageAccumulator()
                actual.apply(first, fileKey: url.path)
                actual.apply(second, fileKey: url.path)

                #expect(actual.records == expected.records, "cut at byte \(cut) of \(url.lastPathComponent)")
                #expect(first.rateLimits + second.rateLimits == single.rateLimits)
            }
        }
    }

    @Test func fileStateSurvivesAJSONRoundTrip() throws {
        var state = CodexFileState()
        _ = try parser.parse(fileAt: Fixtures.codexMain, state: &state)
        let restored = try JSONDecoder().decode(CodexFileState.self, from: JSONEncoder().encode(state))

        #expect(restored == state)
        #expect(restored.model(forTurn: "turn-a") == "gpt-6.1-sol")
    }

    @Test func importsFileListsImportedThreads() throws {
        #expect(try CodexImports.importedThreadIDs(from: Fixtures.importsFile) == [Fixtures.codexThread(4)])
        #expect(try CodexImports.importedThreadIDs(from: Fixtures.root.appendingPathComponent("missing.json")).isEmpty)
    }

    @Test func threadIDComesFromTheFileName() {
        #expect(CodexParser.threadID(fromFileName: "rollout-2026-09-07T15-03-06-0199aaaa-0000-7000-8000-00000000000a.jsonl")
            == "0199aaaa-0000-7000-8000-00000000000a")
        #expect(CodexParser.threadID(fromFileName: "rollout-short.jsonl") == nil)
        #expect(CodexParser.threadID(fromFileName: "notes.txt") == nil)
    }

    @Test func theSnifferSkipsOnlyBulkLineTypes() {
        func line(_ s: String) -> Data { Data(s.utf8) }
        #expect(CodexLineSniffer.canSkip(line(#"{"timestamp":"t","type":"response_item","payload":{"type":"message"}}"#)))
        #expect(CodexLineSniffer.canSkip(line(#"{"timestamp":"t","type":"event_msg","payload":{"type":"agent_message"}}"#)))
        #expect(!CodexLineSniffer.canSkip(line(#"{"timestamp":"t","type":"event_msg","payload":{"type":"token_count"}}"#)))
        #expect(!CodexLineSniffer.canSkip(line(#"{"timestamp":"t","type":"token_usage_record","payload":{}}"#)))
        #expect(!CodexLineSniffer.canSkip(line(#"{"timestamp":"t","type":"turn_context","payload":{}}"#)))
        // Unfamiliar layouts are decoded rather than guessed at.
        #expect(!CodexLineSniffer.canSkip(line(#"{"payload":{"x":1},"type" : "response_item"}"#)))
    }

    @Test func stableHashMatchesKnownFNVVectors() {
        #expect(StableHash.fnv1a64("") == "cbf29ce484222325")
        #expect(StableHash.fnv1a64("a") == "af63dc4c8601ec8c")
    }
}
