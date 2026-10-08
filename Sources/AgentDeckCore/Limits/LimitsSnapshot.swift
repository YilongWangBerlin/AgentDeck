import AgentDeckParsing
import Foundation

/// A rate-limit window as Codex reported it.
public struct ReportedWindow: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// The reported percentage still applies.
        case current(usedPercent: Double)
        /// The window has reset since the last report, so its percentage no longer applies and no
        /// newer value is known.
        case resetSinceLastUpdate
    }

    public var windowMinutes: Int
    public var usedPercent: Double?
    public var resetsAt: Date
    /// When Codex last logged this value. Shown in the UI so stale data is obvious.
    public var observedAt: Date
    public var isRejection: Bool

    public init(windowMinutes: Int, usedPercent: Double?, resetsAt: Date, observedAt: Date, isRejection: Bool) {
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.isRejection = isRejection
    }

    public func status(at now: Date) -> Status {
        guard now < resetsAt, let usedPercent else { return .resetSinceLastUpdate }
        return .current(usedPercent: usedPercent)
    }

    init(_ window: ClaudeReportedLimits.Window, minutes: Int, observedAt: Date) {
        self.init(windowMinutes: minutes, usedPercent: window.usedPercent, resetsAt: window.resetsAt,
                  observedAt: observedAt, isRejection: false)
    }

    init(_ observation: RateLimitObservation) {
        self.init(
            windowMinutes: observation.windowMinutes ?? 0,
            usedPercent: observation.usedPercent,
            resetsAt: observation.resetsAt,
            observedAt: observation.observedAt,
            isRejection: observation.isRejection
        )
    }
}

/// Everything the menu bar shows, computed from the store at one moment.
public struct LimitsSnapshot: Equatable, Sendable {
    public struct Claude: Equatable, Sendable {
        /// The estimated window containing `computedAt`, or nil when none is running.
        public var window: EstimatedWindow?
        /// Tokens since the estimated window started.
        public var tokensInWindow: Int
        /// Tokens in the 7 days before `computedAt`. Claude Code logs nothing about the weekly limit,
        /// so this is a rolling sum, not a window.
        public var tokensLast7Days: Int
        public var lastActivity: Date?
        /// The most recent refusal, if any (Claude Code only logs limits when it refuses a request).
        public var lastRefusal: RateLimitObservation?
        /// Claude's own percentages, when AgentDeck is Claude Code's status line.
        public var reportedFiveHour: ReportedWindow? = nil
        public var reportedWeekly: ReportedWindow? = nil
    }

    public struct Codex: Equatable, Sendable {
        public var fiveHour: ReportedWindow?
        public var weekly: ReportedWindow?
        public var planType: String?
    }

    public var computedAt: Date
    public var claude: Claude
    public var codex: Codex
}

public enum LimitsCalculator {
    /// Activity this far back is enough to line up the window chain: any 5-hour gap restarts it.
    static let activityLookback: TimeInterval = 14 * 24 * 3600

    /// - Parameter claudeReported: Limits Claude Code passed to AgentDeck's status line, if any.
    public static func snapshot(store: UsageStore, now: Date = Date(), claudeReported: ClaudeReportedLimits? = nil) throws -> LimitsSnapshot {
        let lookback = now.addingTimeInterval(-activityLookback)
        let activity = try store.activityTimes(source: .claudeCode, since: lookback)
        let refusals = try store.rateLimits(since: lookback).filter { $0.source == .claudeCode }
        // Claude's own reset time, when its status line reported one, beats the estimate: tokens are
        // then counted over the same window as the percentage.
        let reportedWindow = claudeReported?.fiveHour.flatMap { reported in
            reported.resetsAt > now
                ? EstimatedWindow(start: reported.resetsAt.addingTimeInterval(-5 * 3600), end: reported.resetsAt, isConfirmedByRefusal: true)
                : nil
        }
        let window = reportedWindow ?? ClaudeWindowEstimator.current(
            at: now, activity: activity, refusalResets: refusals.map(\.resetsAt)
        )

        let tokensInWindow = try window.map {
            try store.tokenTotals(in: DateInterval(start: $0.start, end: max($0.start, now)), source: .claudeCode).total
        } ?? 0
        let week = DateInterval(start: now.addingTimeInterval(-7 * 24 * 3600), end: now)
        let tokensLast7Days = try store.tokenTotals(in: week, source: .claudeCode).total

        let codexLimits = try store.latestRateLimits().filter { $0.source == .codex && $0.limitID == "codex" }
        let fiveHour = codexLimits.first { $0.windowMinutes == 300 }
        let weekly = codexLimits.first { $0.windowMinutes == 10_080 }

        return LimitsSnapshot(
            computedAt: now,
            claude: .init(
                window: window,
                tokensInWindow: tokensInWindow,
                tokensLast7Days: tokensLast7Days,
                lastActivity: activity.last,
                lastRefusal: refusals.last,
                reportedFiveHour: claudeReported?.fiveHour.map { ReportedWindow($0, minutes: 300, observedAt: claudeReported!.observedAt) },
                reportedWeekly: claudeReported?.sevenDay.map { ReportedWindow($0, minutes: 10_080, observedAt: claudeReported!.observedAt) }
            ),
            codex: .init(
                fiveHour: fiveHour.map(ReportedWindow.init),
                weekly: weekly.map(ReportedWindow.init),
                planType: (fiveHour ?? weekly)?.planType
            )
        )
    }
}
