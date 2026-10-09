import AgentDeckParsing
import Foundation

/// A Claude window's percentage, as Claude reported it.
public struct ClaudeAppReport: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Fetched online with Claude Code's login (`ClaudeUsageClient`).
        case online
        /// The Claude desktop app's record (FORMATS.md 3.4).
        case claudeApp
    }

    public var usedPercent: Double
    /// When Claude reported it. Shown in the UI so stale data is obvious.
    public var observedAt: Date
    /// When the window began, when known.
    public var windowStart: Date?
    /// When the window resets, when known.
    public var resetsAt: Date?
    public var source: Source

    public init(usedPercent: Double, observedAt: Date, windowStart: Date? = nil, resetsAt: Date? = nil, source: Source = .claudeApp) {
        self.usedPercent = usedPercent
        self.observedAt = observedAt
        self.windowStart = windowStart
        self.resetsAt = resetsAt
        self.source = source
    }
}

/// Turns the Claude app's usage samples into the reports that still apply at a given moment.
///
/// The samples carry percentages but no reset times, so those come from elsewhere: the 5-hour
/// window's from the local estimate, and the weekly window's from the moment its percentage last
/// fell back (a weekly window lasts 7 days).
public enum ClaudeAppReports {
    public static let weekLength: TimeInterval = 7 * 24 * 3600
    /// An online reading older than this no longer stands for the current value.
    public static let onlineFreshness: TimeInterval = 15 * 60

    /// The 5-hour and weekly reports from an online reading, or nil when there is no fresh one.
    /// A nil window inside the result means Claude has no window running, which the older sources
    /// must not override.
    public static func online(_ live: ClaudeLiveUsage?, now: Date) -> (fiveHour: ClaudeAppReport?, weekly: ClaudeAppReport?)? {
        guard let live, now.timeIntervalSince(live.fetchedAt) < onlineFreshness else { return nil }
        func report(_ window: ClaudeLiveUsage.Window?, length: TimeInterval) -> ClaudeAppReport? {
            guard let window else { return nil }
            // No reset time means no window is running.
            guard let resetsAt = window.resetsAt else { return nil }
            guard resetsAt > now else { return nil }
            return ClaudeAppReport(usedPercent: window.utilization, observedAt: live.fetchedAt,
                                   windowStart: resetsAt.addingTimeInterval(-length), resetsAt: resetsAt, source: .online)
        }
        return (report(live.fiveHour, length: ClaudeWindowEstimator.length), report(live.sevenDay, length: weekLength))
    }

    /// The samples up to `now` from the account that recorded the newest one.
    static func relevant(_ samples: [ClaudePlanUsageSample], now: Date) -> [ClaudePlanUsageSample] {
        let upToNow = samples.filter { $0.time <= now }.sorted { $0.time < $1.time }
        guard let newest = upToNow.last else { return [] }
        return upToNow.filter { $0.organization == newest.organization }
    }

    /// The weekly percentage, while its window has not reset since the sample.
    public static func weekly(_ samples: [ClaudePlanUsageSample], now: Date) -> ClaudeAppReport? {
        let samples = relevant(samples, now: now).filter { $0.sevenDayPercent != nil }
        guard let newest = samples.last, let percent = newest.sevenDayPercent else { return nil }
        // The weekly percentage only ever rises within a window, so a fall marks a reset. The reset
        // happened at or shortly before the first sample after it.
        var start: Date?
        for (previous, sample) in zip(samples, samples.dropFirst()) where sample.sevenDayPercent! < previous.sevenDayPercent! {
            start = sample.time
        }
        let resetsAt = start.map { $0.addingTimeInterval(weekLength) }
        guard now < (resetsAt ?? newest.time.addingTimeInterval(weekLength)) else { return nil }
        return ClaudeAppReport(usedPercent: percent, observedAt: newest.time, windowStart: start, resetsAt: resetsAt)
    }

    /// The 5-hour percentage, while the window it was recorded in is still running.
    ///
    /// - Parameter windows: The estimated windows up to `now` (`ClaudeWindowEstimator.windows`).
    public static func fiveHour(_ samples: [ClaudePlanUsageSample], windows: [EstimatedWindow], now: Date) -> ClaudeAppReport? {
        guard let newest = relevant(samples, now: now).last(where: { $0.fiveHourPercent != nil }),
              let percent = newest.fiveHourPercent else { return nil }
        if let window = windows.last(where: { $0.contains(newest.time) }) {
            // Recorded during an estimated window: it applies until that window ends.
            guard window.end > now else { return nil }
            return ClaudeAppReport(usedPercent: percent, observedAt: newest.time, windowStart: window.start, resetsAt: window.end)
        }
        // Recorded while no local activity had started a window. A nonzero value means a window
        // started outside Claude Code: it began before the sample, so it ends within 5 hours of it.
        // A later local window means the estimate knows something newer.
        guard percent > 0, now < newest.time.addingTimeInterval(ClaudeWindowEstimator.length),
              !windows.contains(where: { $0.start > newest.time }) else { return nil }
        return ClaudeAppReport(usedPercent: percent, observedAt: newest.time)
    }
}
