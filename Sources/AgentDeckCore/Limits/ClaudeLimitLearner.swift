import AgentDeckParsing
import Foundation

/// A Claude limit in tokens, learned from the times Claude Code refused a request.
public struct LearnedLimit: Equatable, Sendable {
    /// The median of the tokens used up to each refusal.
    public var tokens: Int
    public var samples: Int

    public init(tokens: Int, samples: Int) {
        self.tokens = tokens
        self.samples = samples
    }
}

/// Claude Code logs no limits, but it does log a refusal with the window's reset time when a limit
/// is hit (FORMATS.md 3.2). At that moment the window is at 100%, so the tokens used from the
/// window's start up to the refusal are one measurement of the limit. Nothing to type in, and every
/// limit hit makes the estimate better.
///
/// It stays an estimate: claude.ai use counts toward the same limit without appearing in the logs,
/// and the token mix (mostly cache reads) varies between windows.
public enum ClaudeLimitLearner {
    public enum Window: Sendable {
        case fiveHour, weekly

        var length: TimeInterval { self == .fiveHour ? 5 * 3600 : 7 * 24 * 3600 }

        func matches(_ refusal: RateLimitObservation) -> Bool {
            switch self {
            case .fiveHour: refusal.windowMinutes == 300 || refusal.limitType == "five_hour"
            case .weekly: refusal.windowMinutes == 10_080 || (refusal.limitType ?? "").hasPrefix("seven_day")
            }
        }
    }

    /// Refusals this far back count: older ones may predate a plan or limit change.
    static let lookback: TimeInterval = 30 * 24 * 3600
    /// The most recent measurements used.
    static let maxSamples = 5

    public static func learn(store: UsageStore, now: Date, window: Window) throws -> LearnedLimit? {
        let refusals = try store.rateLimits(since: now.addingTimeInterval(-lookback))
            .filter { $0.source == .claudeCode && $0.isRejection && window.matches($0) }
        // One measurement per window, at its first refusal; most recent windows first.
        var measurements: [Int] = []
        for (resetsAt, group) in Dictionary(grouping: refusals, by: \.resetsAt).sorted(by: { $0.key > $1.key }) {
            guard let hit = group.map(\.observedAt).min() else { continue }
            let start = resetsAt.addingTimeInterval(-window.length)
            let tokens = try store.tokenTotals(in: DateInterval(start: start, end: max(start, hit)), source: .claudeCode).total
            if tokens > 0 { measurements.append(tokens) }
            if measurements.count == maxSamples { break }
        }
        guard !measurements.isEmpty else { return nil }
        let sorted = measurements.sorted()
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        return LearnedLimit(tokens: median, samples: sorted.count)
    }
}
