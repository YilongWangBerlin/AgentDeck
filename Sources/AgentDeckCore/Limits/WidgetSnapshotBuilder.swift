import AgentDeckParsing
import AgentDeckWidgetData
import Foundation

/// Builds what the desktop widget shows from the same numbers as the menu.
public enum WidgetSnapshotBuilder {
    public static func make(
        limits: LimitsSnapshot, budgets: SoftBudgets, records: [UsageRecord],
        calendar: LocalCalendar, now: Date, dayCount: Int = 14
    ) -> WidgetSnapshot {
        let gauges = LimitGauge.gauges(for: limits, budgets: budgets)
        func fraction(_ kind: LimitGauge.Kind) -> Double? { gauges.first { $0.kind == kind }?.fraction }
        let runningWindow = limits.claude.window.flatMap { $0.end > now ? $0 : nil }

        func reported(_ window: ReportedWindow?) -> WidgetSnapshot.Window? {
            guard let window, let percent = window.usedPercent else { return nil }
            return WidgetSnapshot.Window(usedPercent: percent, resetsAt: window.resetsAt)
        }
        let codex = limits.codex
        let reportedAt = [codex.fiveHour?.observedAt, codex.weekly?.observedAt].compactMap { $0 }.max()

        let today = calendar.day(containing: now)
        var totals: [LocalDay: (claude: Int, codex: Int)] = [:]
        for record in records {
            let day = calendar.day(containing: record.timestamp)
            switch record.source {
            case .claudeCode: totals[day, default: (0, 0)].claude += record.tokens.total
            case .codex: totals[day, default: (0, 0)].codex += record.tokens.total
            }
        }
        let days = (0..<dayCount).reversed().map { offset in
            let day = calendar.adding(days: -offset, to: today)
            let total = totals[day] ?? (0, 0)
            return WidgetSnapshot.Day(start: calendar.start(of: day), claude: total.claude, codex: total.codex)
        }

        return WidgetSnapshot(
            generatedAt: now,
            claude: .init(
                tokensInWindow: runningWindow == nil ? 0 : limits.claude.tokensInWindow,
                windowEnd: runningWindow?.end,
                windowFraction: runningWindow == nil ? nil : fraction(.claudeFiveHour),
                tokensLast7Days: limits.claude.tokensLast7Days,
                sevenDayFraction: fraction(.claudeSevenDay)
            ),
            codex: .init(fiveHour: reported(codex.fiveHour), weekly: reported(codex.weekly), reportedAt: reportedAt),
            days: days
        )
    }

    /// The interval `make` needs records for.
    public static func recordInterval(calendar: LocalCalendar, now: Date, dayCount: Int = 14) -> DateInterval {
        let first = calendar.adding(days: -(dayCount - 1), to: calendar.day(containing: now))
        return DateInterval(start: calendar.start(of: first), end: now)
    }
}
