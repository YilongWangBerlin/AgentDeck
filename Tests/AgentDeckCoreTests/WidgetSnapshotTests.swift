@testable import AgentDeckCore
import AgentDeckParsing
import AgentDeckWidgetData
import Foundation
import Testing

@Suite struct WidgetSnapshotTests {
    let berlin = LocalCalendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)

    private func record(_ source: UsageSource, _ iso: String, _ tokens: Int) -> UsageRecord {
        UsageRecord(source: source, messageID: UUID().uuidString, sessionID: "s", timestamp: date(iso), model: "m",
                    tokens: TokenCounts(input: tokens))
    }

    private func limits(now: Date, windowEnd: Date?) -> LimitsSnapshot {
        LimitsSnapshot(
            computedAt: now,
            claude: .init(window: windowEnd.map { EstimatedWindow(start: $0.addingTimeInterval(-5 * 3600), end: $0, isConfirmedByRefusal: false) },
                          tokensInWindow: 600, tokensLast7Days: 9_000, lastActivity: nil, lastRefusal: nil),
            codex: .init(
                fiveHour: ReportedWindow(windowMinutes: 300, usedPercent: 40, resetsAt: now.addingTimeInterval(3600),
                                         observedAt: now.addingTimeInterval(-60), isRejection: false),
                weekly: nil, planType: "plus")
        )
    }

    @Test func daysAreLocalAndEndToday() {
        let now = date("2026-10-08T10:00:00Z")
        let snapshot = WidgetSnapshotBuilder.make(
            limits: limits(now: now, windowEnd: now.addingTimeInterval(3600)),
            budgets: SoftBudgets(claudeFiveHourTokens: 1_000),
            records: [
                record(.claudeCode, "2026-10-08T08:00:00Z", 100),
                // 23:30 UTC on Oct 7 is already Oct 8 in Berlin.
                record(.codex, "2026-10-07T23:30:00Z", 50),
                record(.claudeCode, "2026-10-07T12:00:00Z", 7),
            ],
            calendar: berlin, now: now, dayCount: 3
        )
        #expect(snapshot.days.count == 3)
        #expect(snapshot.days.last == .init(start: date("2026-10-07T22:00:00Z"), claude: 100, codex: 50))
        #expect(snapshot.days[1].claude == 7)
        #expect(snapshot.claude.windowFraction == 0.6)
        #expect(snapshot.codex.fiveHour?.percent(at: now) == 40)
        #expect(snapshot.codex.fiveHour?.percent(at: now.addingTimeInterval(7200)) == nil)
    }

    @Test func anEndedClaudeWindowShowsNothingRunning() {
        let now = date("2026-10-08T10:00:00Z")
        let snapshot = WidgetSnapshotBuilder.make(
            limits: limits(now: now, windowEnd: now.addingTimeInterval(-60)), budgets: SoftBudgets(claudeFiveHourTokens: 1_000),
            records: [], calendar: berlin, now: now)
        #expect(snapshot.claude.windowEnd == nil && snapshot.claude.tokensInWindow == 0 && snapshot.claude.windowFraction == nil)
    }

    @Test func roundTripsThroughTheFile() throws {
        let url = try temporaryDirectory().appendingPathComponent("widget/snapshot.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let now = date("2026-10-08T10:00:00Z")
        let snapshot = WidgetSnapshotBuilder.make(limits: limits(now: now, windowEnd: nil), budgets: SoftBudgets(),
                                                  records: [], calendar: berlin, now: now, dayCount: 2)
        try snapshot.write(to: url)
        #expect(WidgetSnapshot.load(from: url) == snapshot)
    }
}
