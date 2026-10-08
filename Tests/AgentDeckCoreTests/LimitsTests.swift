import AgentDeckCore
import AgentDeckParsing
import Foundation
import Testing

@Suite struct ClaudeWindowEstimatorTests {
    private func window(_ start: String, _ end: String, confirmed: Bool = false) -> EstimatedWindow {
        EstimatedWindow(start: date(start), end: date(end), isConfirmedByRefusal: confirmed)
    }

    /// The three real resets on this machine (FORMATS.md 3.3).
    @Test(arguments: [
        ("2026-10-05T09:32:57Z", "2026-10-05T09:30:00Z", "2026-10-05T14:30:00Z"),
        ("2026-10-07T01:17:55Z", "2026-10-07T01:10:00Z", "2026-10-07T06:10:00Z"),
        ("2026-08-03T13:03:06Z", "2026-08-03T13:00:00Z", "2026-08-03T18:00:00Z"),
    ])
    func theFirstActivityIsFlooredToTenMinutes(activity: String, start: String, end: String) {
        let windows = ClaudeWindowEstimator.windows(activity: [date(activity)], refusalResets: [])
        #expect(windows == [window(start, end)])
    }

    @Test func activityAfterAWindowEndsStartsTheNextOne() {
        let activity = ["2026-10-05T09:32:00Z", "2026-10-05T12:00:00Z", "2026-10-05T14:30:00Z", "2026-10-05T23:59:00Z"]
        #expect(ClaudeWindowEstimator.windows(activity: activity.map(date), refusalResets: []) == [
            window("2026-10-05T09:30:00Z", "2026-10-05T14:30:00Z"),
            window("2026-10-05T14:30:00Z", "2026-10-05T19:30:00Z"),
            window("2026-10-05T23:50:00Z", "2026-10-06T04:50:00Z"),
        ])
    }

    @Test func aLoggedResetTimeOverridesTheEstimate() {
        // Tonight's miss: local activity began at 21:35, but the real window ran 21:10–02:10.
        let windows = ClaudeWindowEstimator.windows(
            activity: [date("2026-10-07T21:35:00Z")], refusalResets: [date("2026-10-08T02:10:00Z")]
        )
        #expect(windows == [window("2026-10-07T21:10:00Z", "2026-10-08T02:10:00Z", confirmed: true)])
    }

    @Test func aConfirmedWindowCutsShortAnOverlappingEstimate() {
        let windows = ClaudeWindowEstimator.windows(
            activity: ["2026-10-07T16:45:00Z", "2026-10-07T21:00:00Z"].map(date),
            refusalResets: [date("2026-10-08T01:50:00Z"), date("2026-10-08T01:50:00Z")]
        )
        #expect(windows == [
            window("2026-10-07T16:40:00Z", "2026-10-07T20:50:00Z"),
            window("2026-10-07T20:50:00Z", "2026-10-08T01:50:00Z", confirmed: true),
        ])
    }

    @Test func thereIsNoCurrentWindowAfterTheLastOneEnds() {
        let activity = [date("2026-10-05T09:32:00Z"), date("2026-10-05T18:00:00Z")]
        #expect(ClaudeWindowEstimator.current(at: date("2026-10-05T12:00:00Z"), activity: activity, refusalResets: [])
            == window("2026-10-05T09:30:00Z", "2026-10-05T14:30:00Z"))
        // Activity after `now` is ignored.
        #expect(ClaudeWindowEstimator.current(at: date("2026-10-05T15:00:00Z"), activity: activity, refusalResets: []) == nil)
    }
}

@Suite struct LimitsSnapshotTests {
    private func store(usage: [UsageRecord] = [], limits: [RateLimitObservation] = []) throws -> UsageStore {
        let store = try UsageStore.inMemory()
        let file = try store.registerLogFile(path: "/a.jsonl", source: .claudeCode)
        var result = ParseResult()
        result.usage = usage
        result.rateLimits = limits
        try store.apply(result, to: file, parserState: nil, threadID: nil,
                        snapshot: .init(size: 1, modifiedAt: 1, inode: 1))
        return store
    }

    private func claude(_ id: String, _ iso: String, _ tokens: Int) -> UsageRecord {
        UsageRecord(source: .claudeCode, messageID: id, sessionID: "s", timestamp: date(iso), model: "m",
                    tokens: TokenCounts(input: tokens))
    }

    private func codex(_ minutes: Int, _ percent: Double, resets: String, seen: String, limitID: String = "codex") -> RateLimitObservation {
        RateLimitObservation(source: .codex, observedAt: date(seen), windowMinutes: minutes, usedPercent: percent,
                             resetsAt: date(resets), limitID: limitID, planType: "plus", isRejection: false)
    }

    @Test func claudeTokensAreCountedFromTheEstimatedStart() throws {
        let store = try store(usage: [
            claude("old", "2026-10-07T12:00:00Z", 1_000),
            claude("a", "2026-10-07T21:35:00Z", 10),
            claude("b", "2026-10-07T23:00:00Z", 20),
        ])
        let snapshot = try LimitsCalculator.snapshot(store: store, now: date("2026-10-07T23:30:00Z"))

        #expect(snapshot.claude.window?.start == date("2026-10-07T21:30:00Z"))
        #expect(snapshot.claude.tokensInWindow == 30)
        #expect(snapshot.claude.tokensLast7Days == 1_030)
        #expect(snapshot.claude.lastActivity == date("2026-10-07T23:00:00Z"))
    }

    @Test func codexUsesTheNewestReportPerWindowAndNoticesResets() throws {
        let store = try store(limits: [
            codex(300, 87, resets: "2026-10-07T04:02:48Z", seen: "2026-10-07T01:14:08Z"),
            codex(300, 88, resets: "2026-10-07T04:02:48Z", seen: "2026-10-07T01:16:08Z"),
            codex(10_080, 65, resets: "2026-10-09T22:27:19Z", seen: "2026-10-07T01:16:08Z"),
            codex(300, 99, resets: "2026-10-07T04:02:48Z", seen: "2026-10-07T01:20:00Z", limitID: "premium"),
        ])

        let before = try LimitsCalculator.snapshot(store: store, now: date("2026-10-07T02:00:00Z"))
        #expect(before.codex.fiveHour?.status(at: before.computedAt) == .current(usedPercent: 88))
        #expect(before.codex.fiveHour?.observedAt == date("2026-10-07T01:16:08Z"))
        #expect(before.codex.weekly?.status(at: before.computedAt) == .current(usedPercent: 65))
        #expect(before.codex.planType == "plus")

        let after = try LimitsCalculator.snapshot(store: store, now: date("2026-10-07T05:00:00Z"))
        #expect(after.codex.fiveHour?.status(at: after.computedAt) == .resetSinceLastUpdate)
        #expect(after.codex.weekly?.status(at: after.computedAt) == .current(usedPercent: 65))
    }

    @Test func gaugesNeedARealDenominator() throws {
        let store = try store(
            usage: [claude("a", "2026-10-07T21:35:00Z", 40)],
            limits: [codex(300, 88, resets: "2026-10-07T23:00:00Z", seen: "2026-10-07T21:00:00Z")]
        )
        let snapshot = try LimitsCalculator.snapshot(store: store, now: date("2026-10-07T22:00:00Z"))

        // Without budgets, Claude has nothing to divide by.
        #expect(LimitGauge.gauges(for: snapshot, budgets: SoftBudgets()).map(\.kind) == [.codexFiveHour])

        let gauges = LimitGauge.gauges(for: snapshot, budgets: SoftBudgets(claudeFiveHourTokens: 100, claudeSevenDayTokens: 400))
        #expect(gauges.map(\.kind) == [.claudeFiveHour, .claudeSevenDay, .codexFiveHour])
        #expect(gauges.map(\.fraction) == [0.4, 0.1, 0.88])
        #expect(gauges[0].basis == .softBudget(tokens: 100) && gauges[2].basis == .reported)
    }


    @Test func codexTokensAreCountedBackFromItsReportedReset() throws {
        func codexRecord(_ id: String, _ iso: String, _ tokens: Int) -> UsageRecord {
            UsageRecord(source: .codex, messageID: id, sessionID: "t", timestamp: date(iso), model: "gpt",
                        tokens: TokenCounts(input: tokens))
        }
        let store = try store(
            usage: [
                codexRecord("old", "2026-10-07T17:00:00Z", 1_000),   // before the 5-hour window
                codexRecord("a", "2026-10-07T19:30:00Z", 10),
                codexRecord("b", "2026-10-07T23:00:00Z", 20),
                claude("c", "2026-10-07T23:00:00Z", 500),           // other tool, not counted
            ],
            limits: [codex(300, 40, resets: "2026-10-08T00:00:00Z", seen: "2026-10-07T23:00:00Z"),
                     codex(10_080, 20, resets: "2026-10-10T00:00:00Z", seen: "2026-10-07T23:00:00Z")]
        )
        let snapshot = try LimitsCalculator.snapshot(store: store, now: date("2026-10-07T23:30:00Z"))
        #expect(snapshot.codex.tokensInFiveHour == 30)
        #expect(snapshot.codex.tokensInWeek == 1_030)
        // After the reset nothing is counted until Codex reports a new window.
        let later = try LimitsCalculator.snapshot(store: store, now: date("2026-10-08T00:30:00Z"))
        #expect(later.codex.tokensInFiveHour == nil)
    }

    @Test func claudesLimitIsLearnedFromRefusals() throws {
        func refusal(_ seen: String, resets: String) -> RateLimitObservation {
            RateLimitObservation(source: .claudeCode, observedAt: date(seen), windowMinutes: 300, usedPercent: nil,
                                 resetsAt: date(resets), limitID: nil, planType: nil, limitType: "five_hour", isRejection: true)
        }
        let store = try store(
            usage: [
                claude("a1", "2026-10-05T12:00:00Z", 100), claude("a2", "2026-10-05T13:00:00Z", 30),
                claude("after", "2026-10-05T13:30:00Z", 999),     // after the refusal: not counted
                claude("b1", "2026-10-06T08:00:00Z", 90),
                claude("c1", "2026-10-07T20:00:00Z", 200),
                claude("now", "2026-10-08T09:00:00Z", 65),
            ],
            limits: [
                refusal("2026-10-05T13:10:00Z", resets: "2026-10-05T16:30:00Z"),
                refusal("2026-10-05T13:20:00Z", resets: "2026-10-05T16:30:00Z"),  // same window, later
                refusal("2026-10-06T09:00:00Z", resets: "2026-10-06T12:00:00Z"),
                refusal("2026-10-07T21:00:00Z", resets: "2026-10-08T00:00:00Z"),
            ]
        )
        let snapshot = try LimitsCalculator.snapshot(store: store, now: date("2026-10-08T09:30:00Z"))
        // Windows held 130, 90 and 200 tokens when refused; the median is the limit.
        #expect(snapshot.claude.learnedFiveHour == LearnedLimit(tokens: 130, samples: 3))
        #expect(snapshot.claude.learnedWeekly == nil)
        let gauge = LimitGauge.gauges(for: snapshot, budgets: SoftBudgets(claudeFiveHourTokens: 1_000)).first { $0.kind == .claudeFiveHour }
        #expect(gauge?.basis == .learned(tokens: 130, samples: 3))
        #expect(gauge?.fraction == 65.0 / 130)
    }

    @Test func betweenWindowsThePreviousOneIsKept() throws {
        let store = try store(usage: [
            claude("a", "2026-10-08T07:41:00Z", 30),
            claude("b", "2026-10-08T10:46:00Z", 12),
        ])
        // The window that started at 07:40 ended at 12:40; nothing has run since.
        let idle = try LimitsCalculator.snapshot(store: store, now: date("2026-10-08T12:45:00Z"))
        #expect(idle.claude.window == nil)
        #expect(idle.claude.previousWindow?.start == date("2026-10-08T07:40:00Z"))
        #expect(idle.claude.previousWindow?.end == date("2026-10-08T12:40:00Z"))
        #expect(idle.claude.tokensInPreviousWindow == 42)
    }
}

@Suite struct AlertLedgerTests {
    private func gauge(_ fraction: Double, resets: String?) -> LimitGauge {
        LimitGauge(kind: .codexFiveHour, fraction: fraction, basis: .reported, resetsAt: resets.map(date))
    }

    @Test func eachWindowAlertsOnce() {
        var ledger = AlertLedger()
        #expect(ledger.due([gauge(0.7, resets: "2026-10-07T04:02:48Z")], threshold: 0.8).isEmpty)
        #expect(ledger.due([gauge(0.85, resets: "2026-10-07T04:02:48Z")], threshold: 0.8).count == 1)
        // Codex reset times jitter by seconds between events.
        #expect(ledger.due([gauge(0.9, resets: "2026-10-07T04:02:51Z")], threshold: 0.8).isEmpty)
        // The next window alerts again.
        #expect(ledger.due([gauge(0.9, resets: "2026-10-07T09:10:00Z")], threshold: 0.8).count == 1)
    }

    @Test func droppingBelowTheThresholdReArms() throws {
        var ledger = AlertLedger()
        let rolling = { (f: Double) in LimitGauge(kind: .claudeSevenDay, fraction: f, basis: .softBudget(tokens: 1), resetsAt: nil) }
        #expect(ledger.due([rolling(0.95)], threshold: 0.9).count == 1)
        #expect(ledger.due([rolling(0.97)], threshold: 0.9).isEmpty)
        #expect(ledger.due([rolling(0.5)], threshold: 0.9).isEmpty)
        #expect(ledger.due([rolling(0.92)], threshold: 0.9).count == 1)

        let restored = try JSONDecoder().decode(AlertLedger.self, from: JSONEncoder().encode(ledger))
        #expect(restored == ledger)
    }
}

@Suite struct FormattingTests {
    @Test(arguments: [
        (0, "0"), (950, "950"), (1_000, "1K"), (12_345, "12.3K"), (99_960, "100K"), (999_960, "1M"),
        (54_188_918, "54.2M"), (477_900_863, "478M"), (1_213_948_856, "1.2B"), (2_420_000_000, "2.4B"), (-1_500, "-1.5K"),
    ])
    func compactTokens(value: Int, expected: String) {
        #expect(Formatting.compactTokens(value) == expected)
    }

    @Test func durations() {
        #expect(Formatting.duration(-5) == "0m")
        #expect(Formatting.duration(30) == "<1m")
        #expect(Formatting.duration(2 * 3600 + 47 * 60 + 59) == "2h 47m")
        #expect(Formatting.duration(76 * 3600) == "3d 4h")
        #expect(Formatting.shortDuration(2 * 3600 + 7 * 60) == "2h07")
        #expect(Formatting.shortDuration(5 * 60) == "5m")
        #expect(Formatting.shortDuration(26 * 3600) == "1d")
    }
}

