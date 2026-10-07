@testable import AgentDeckCore
import AgentDeckParsing
import Foundation
import Testing

@Suite struct DashboardDataTests {
    let berlin = LocalCalendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)

    private func row(
        _ id: String, _ iso: String, source: UsageSource = .claudeCode, session: String = "s1",
        model: String = "claude-opus-5-5", input: Int = 0, output: Int = 0, cache: Int = 0
    ) -> UsageRecord {
        UsageRecord(source: source, messageID: id, sessionID: session, timestamp: date(iso), model: model,
                    tokens: TokenCounts(input: input, output: output, cacheRead: cache))
    }

    @Test func statCardsFollowTheDocumentedDefinitions() {
        let rows = [
            row("a", "2026-10-07T21:10:00Z", input: 10),                                   // Berlin 23:10, Oct 7
            row("b", "2026-10-07T21:50:00Z", input: 10),                                   // Berlin 23:50
            row("c", "2026-10-07T22:30:00Z", session: "s2", model: "claude-sonnet-5", input: 500), // Berlin 00:30, Oct 8
            row("d", "2026-10-08T10:00:00Z", source: .codex, session: "s1", model: "gpt-6.1-sol", input: 100),
        ]
        let stats = DashboardData.stats(rows, calendar: berlin)

        #expect(stats.messages == 4)
        #expect(stats.sessions == 3) // "s1" in Claude Code and in Codex are different sessions
        #expect(stats.tokens.total == 620)
        #expect(stats.activeDays == 2)
        #expect(stats.peakHour == 23)
        #expect(stats.favoriteModel == "claude-sonnet-5")
        #expect(DashboardData.stats([], calendar: berlin) == DashboardStats())
    }

    @Test func rangesCoverWholeLocalDaysIncludingToday() throws {
        let now = date("2026-10-08T10:00:00Z")
        let week = try #require(DashboardRange.last7Days.interval(now: now, calendar: berlin))
        #expect(week.start == date("2026-10-01T22:00:00Z"))
        #expect(week.end == date("2026-10-08T22:00:00Z"))
        #expect(DashboardRange.all.interval(now: now, calendar: berlin) == nil)
    }

    @Test func modelsAreSortedByTokens() {
        let models = DashboardData.models([
            row("a", "2026-10-07T10:00:00Z", model: "x", input: 5),
            row("b", "2026-10-07T10:00:00Z", model: "y", input: 7),
            row("c", "2026-10-07T11:00:00Z", model: "x", output: 3),
        ])
        #expect(models.map(\.model) == ["x", "y"])
        #expect(models.map(\.responses) == [2, 1])
        #expect(models.first?.tokens == TokenCounts(input: 5, output: 3))
    }

    @Test func dailyBarsSplitInputOutputAndCache() {
        let bars = DashboardData.dailyByKind([row("a", "2026-10-07T10:00:00Z", input: 1, output: 2, cache: 3)], calendar: berlin)
        #expect(bars.map(\.kind) == [.input, .output, .cache])
        #expect(bars.map(\.tokens) == [1, 2, 3])
    }

    @Test func heatmapColumnsAreWeeksStartingSunday() throws {
        let today = LocalDay(year: 2026, month: 10, day: 8) // a Thursday
        let heatmap = DashboardData.heatmap([
            row("a", "2026-10-07T10:00:00Z", input: 100),
            row("b", "2026-10-07T11:00:00Z", source: .codex, input: 50),
            row("c", "2026-07-09T10:00:00Z", input: 1),
        ], calendar: berlin, today: today)

        #expect(heatmap.weeks.count == 26)
        let current = try #require(heatmap.weeks.last)
        #expect(current.map(\.day.description) == ["2026-10-04", "2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08"])
        let wednesday = current[3]
        #expect(wednesday.tokens.total == 150)
        #expect(wednesday.bySource == [.claudeCode: 100, .codex: 50])
        #expect(heatmap.weeks.first?.first?.day == LocalDay(year: 2026, month: 4, day: 12))
        #expect(heatmap.weeks.dropLast().allSatisfy { $0.count == 7 })
    }

    @Test func heatmapGrowsBeyond26WeeksForLongHistory() {
        let today = LocalDay(year: 2026, month: 10, day: 8)
        let heatmap = DashboardData.heatmap([row("a", "2025-10-01T10:00:00Z", input: 1)], calendar: berlin, today: today)
        #expect(heatmap.weeks.count == 54)
        #expect(heatmap.weeks.first?.first?.day == LocalDay(year: 2025, month: 9, day: 28))
    }

    @Test func intensityLevelsUseQuantilesOfActiveDays() {
        #expect(DashboardData.quantileThresholds([10, 20, 30, 40, 50, 60, 70, 80]) == [20, 40, 60])
        #expect(DashboardData.quantileThresholds([]).isEmpty)
        let thresholds = [20, 40, 60]
        #expect([0, 5, 20, 21, 40, 60, 61, 1_000].map { DashboardData.level($0, thresholds: thresholds) } == [0, 1, 1, 2, 2, 3, 4, 4])
        #expect(DashboardData.level(7, thresholds: DashboardData.quantileThresholds([7])) == 1)
    }

    @Test func modelNamesAndLabels() {
        #expect(DashboardData.displayName(forModel: "claude-opus-5-5") == "Opus 5.5")
        #expect(DashboardData.displayName(forModel: "claude-sonnet-5") == "Sonnet 5")
        #expect(DashboardData.displayName(forModel: "claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(DashboardData.displayName(forModel: "gpt-6.1-sol") == "gpt-6.1-sol")
        #expect(DashboardData.displayName(forModel: "<synthetic>") == "<synthetic>")
        #expect(DashboardData.hourLabel(23) == "11 PM" && DashboardData.hourLabel(0) == "12 AM" && DashboardData.hourLabel(12) == "12 PM")
    }

    @Test func funLineUsesTheHobbitConstant() {
        #expect(DashboardData.funLine(totalTokens: 100) == nil)
        #expect(DashboardData.funLine(totalTokens: 1_213_948_856) == "That's about 9,830× The Hobbit.")
    }
}
