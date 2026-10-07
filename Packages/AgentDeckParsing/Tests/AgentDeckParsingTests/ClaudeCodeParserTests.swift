import Foundation
import Testing
@testable import AgentDeckParsing

@Suite struct ClaudeCodeParserTests {
    let parser = ClaudeCodeParser()

    @Test func contentBlockLinesBecomeOneResponseWithTheFinalOutput() throws {
        let result = try parser.parse(fileAt: Fixtures.claudeSession)

        #expect(result.usage.map(\.messageID) == ["msg_A:req_A", "msg_B:req_B", "msg_E:req_E"])
        let a = try #require(result.usage.first)
        // Three lines share this key. The first two carry a mid-stream output_tokens of 5.
        #expect(a.tokens == TokenCounts(input: 2, output: 367, cacheRead: 33_788, cacheWrite: 4_611, reasoning: 63))
        #expect(a.model == "claude-opus-5-5")
        #expect(a.sessionID == Fixtures.claudeSessionA)
        #expect(a.timestamp == Fixtures.date("2026-10-05T09:33:00.100Z"))
    }

    @Test func syntheticLinesAddNoUsageButTheirQuotaLimitsAreRead() throws {
        let result = try parser.parse(fileAt: Fixtures.claudeSession)

        #expect(!result.usage.contains { $0.model == "<synthetic>" })
        #expect(result.rateLimits == [
            RateLimitObservation(
                source: .claudeCode,
                observedAt: Fixtures.date("2026-10-05T11:07:09.596Z"),
                windowMinutes: 300,
                usedPercent: nil,
                resetsAt: Fixtures.date("2026-10-05T14:30:00Z"),
                limitType: "five_hour",
                isRejection: true
            ),
        ])
    }

    @Test func onlyTypedPromptsCountAsPrompts() throws {
        // Excluded: a tool result, an isMeta line, a task notification, and a subagent's input.
        let session = try parser.parse(fileAt: Fixtures.claudeSession)
        #expect(session.prompts.map(\.id) == ["aaaaaaaa-0000-4000-8000-000000000001"])
        #expect(try parser.parse(fileAt: Fixtures.claudeSubagent).prompts.isEmpty)

        // Block-form content without a tool_result is a typed prompt too.
        let resumed = try parser.parse(fileAt: Fixtures.claudeResumed)
        #expect(resumed.prompts.map(\.sessionID) == [Fixtures.claudeSessionB])
    }

    @Test func malformedLinesAreCountedAndSkipped() throws {
        let result = try parser.parse(fileAt: Fixtures.claudeSession)
        let size = try Data(contentsOf: Fixtures.claudeSession).count

        #expect(result.malformedLineCount == 1)
        #expect(result.endOffset == UInt64(size))
    }

    @Test func aFieldOfTheWrongTypeDoesNotDropTheLine() throws {
        // msg_E has "isSidechain": "false" (a string).
        let result = try parser.parse(fileAt: Fixtures.claudeSession)
        let e = try #require(result.usage.first { $0.messageID == "msg_E:req_E" })
        #expect(e.tokens == TokenCounts(input: 1, output: 9))
    }

    @Test func subagentUsageBelongsToTheParentSession() throws {
        let result = try parser.parse(fileAt: Fixtures.claudeSubagent)
        #expect(result.usage.map(\.messageID) == ["msg_C:req_C"])
        #expect(result.usage.first?.sessionID == Fixtures.claudeSessionA)
    }

    @Test func linesCopiedIntoAResumedSessionAreCountedOnce() throws {
        var accumulator = UsageAccumulator()
        for url in Fixtures.claudeFiles {
            accumulator.apply(try parser.parse(fileAt: url), fileKey: url.path)
        }

        #expect(accumulator.records.count == 5)
        let totals = accumulator.totals()
        #expect(totals == TokenCounts(input: 17, output: 626, cacheRead: 124_788, cacheWrite: 5_611, reasoning: 83))
        #expect(totals.total == 131_042)
        #expect(Set(accumulator.records.values.map(\.sessionID)) == [Fixtures.claudeSessionA, Fixtures.claudeSessionB])
    }

    @Test func parsingInTwoPassesMatchesASinglePass() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for url in Fixtures.claudeFiles {
            let single = try parser.parse(fileAt: url)
            var expected = UsageAccumulator()
            expected.apply(single, fileKey: url.path)

            let size = try Data(contentsOf: url).count
            for cut in stride(from: 0, through: size, by: 7) {
                let first = try parser.parse(fileAt: Fixtures.prefixCopy(of: url, byteCount: cut, in: directory))
                let second = try parser.parse(fileAt: url, from: first.endOffset)
                var actual = UsageAccumulator()
                actual.apply(first, fileKey: url.path)
                actual.apply(second, fileKey: url.path)

                #expect(actual.records == expected.records, "cut at byte \(cut) of \(url.lastPathComponent)")
                #expect(first.prompts + second.prompts == single.prompts)
                #expect(first.rateLimits + second.rateLimits == single.rateLimits)
                #expect(second.endOffset == single.endOffset)
            }
        }
    }
}
