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
        /// The most recent window that has ended, and its tokens: shown while no window is running,
        /// so the row says what happened instead of going blank.
        public var previousWindow: EstimatedWindow? = nil
        public var tokensInPreviousWindow: Int = 0
        /// Claude's limits as learned from the times Claude Code refused a request (100%).
        public var learnedFiveHour: LearnedLimit? = nil
        public var learnedWeekly: LearnedLimit? = nil
    }

    public struct Codex: Equatable, Sendable {
        public var fiveHour: ReportedWindow?
        public var weekly: ReportedWindow?
        public var planType: String?
        /// Codex tokens in each reported window (from its reset time back), while it has not reset.
        public var tokensInFiveHour: Int? = nil
        public var tokensInWeek: Int? = nil
    }

    public var computedAt: Date
    public var claude: Claude
    public var codex: Codex
}

public enum LimitsCalculator {
    /// Activity this far back is enough to line up the window chain: any 5-hour gap restarts it.
    static let activityLookback: TimeInterval = 14 * 24 * 3600

    public static func snapshot(store: UsageStore, now: Date = Date()) throws -> LimitsSnapshot {
        let lookback = now.addingTimeInterval(-activityLookback)
        let activity = try store.activityTimes(source: .claudeCode, since: lookback)
        let refusals = try store.rateLimits(since: lookback).filter { $0.source == .claudeCode }
        let windows = ClaudeWindowEstimator.windows(activity: activity.filter { $0 <= now }, refusalResets: refusals.map(\.resetsAt))
        let window = windows.last { $0.contains(now) }
        let previous = windows.last { $0.end <= now }

        let tokensInWindow = try window.map {
            try store.tokenTotals(in: DateInterval(start: $0.start, end: max($0.start, now)), source: .claudeCode).total
        } ?? 0
        let week = DateInterval(start: now.addingTimeInterval(-7 * 24 * 3600), end: now)
        let tokensLast7Days = try store.tokenTotals(in: week, source: .claudeCode).total

        func codexTokens(in window: RateLimitObservation?, length: TimeInterval) throws -> Int? {
            guard let window, window.resetsAt > now else { return nil }
            let start = window.resetsAt.addingTimeInterval(-length)
            return try store.tokenTotals(in: DateInterval(start: start, end: max(start, now)), source: .codex).total
        }

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
                previousWindow: previous,
                tokensInPreviousWindow: try previous.map {
                    try store.tokenTotals(in: DateInterval(start: $0.start, end: $0.end), source: .claudeCode).total
                } ?? 0,
                learnedFiveHour: try ClaudeLimitLearner.learn(store: store, now: now, window: .fiveHour),
                learnedWeekly: try ClaudeLimitLearner.learn(store: store, now: now, window: .weekly)
            ),
            codex: .init(
                fiveHour: fiveHour.map(ReportedWindow.init),
                weekly: weekly.map(ReportedWindow.init),
                planType: (fiveHour ?? weekly)?.planType,
                tokensInFiveHour: try codexTokens(in: fiveHour, length: 5 * 3600),
                tokensInWeek: try codexTokens(in: weekly, length: 7 * 24 * 3600)
            )
        )
    }
}
