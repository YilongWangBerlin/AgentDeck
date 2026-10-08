import Foundation

/// Optional soft budgets the user sets for Claude Code, which reports no limit of its own. Used only
/// for a progress bar and an alert, never shown as the provider's percentage.
public struct SoftBudgets: Codable, Equatable, Sendable {
    public var claudeFiveHourTokens: Int?
    public var claudeSevenDayTokens: Int?

    public init(claudeFiveHourTokens: Int? = nil, claudeSevenDayTokens: Int? = nil) {
        self.claudeFiveHourTokens = claudeFiveHourTokens
        self.claudeSevenDayTokens = claudeSevenDayTokens
    }
}

/// One bar in the menu: how full a window is, when that can be known.
public struct LimitGauge: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case claudeFiveHour = "claude.5h"
        case claudeSevenDay = "claude.7d"
        case codexFiveHour = "codex.5h"
        case codexWeekly = "codex.weekly"
    }

    public enum Basis: Equatable, Sendable {
        /// The percentage Codex reported.
        case reported
        /// Tokens against the user's soft budget.
        case softBudget(tokens: Int)
        /// Tokens against the limit learned from `samples` refusals.
        case learned(tokens: Int, samples: Int)
    }

    public var kind: Kind
    /// 0…1 (can exceed 1 for a budget). Nil when there is no real denominator.
    public var fraction: Double?
    public var basis: Basis
    /// When this window resets. Nil for the rolling 7-day sum.
    public var resetsAt: Date?

    public init(kind: Kind, fraction: Double?, basis: Basis, resetsAt: Date?) {
        self.kind = kind
        self.fraction = fraction
        self.basis = basis
        self.resetsAt = resetsAt
    }

    /// The gauges for a snapshot. Claude gauges use the limit learned from refusals, else the soft
    /// budget, and do not exist without either.
    public static func gauges(for snapshot: LimitsSnapshot, budgets: SoftBudgets) -> [LimitGauge] {
        var gauges: [LimitGauge] = []
        func reported(_ kind: Kind, _ window: ReportedWindow?) -> LimitGauge? {
            guard let window, case .current(let percent) = window.status(at: snapshot.computedAt) else { return nil }
            return LimitGauge(kind: kind, fraction: percent / 100, basis: .reported, resetsAt: window.resetsAt)
        }
        if let learned = snapshot.claude.learnedFiveHour, let window = snapshot.claude.window {
            gauges.append(LimitGauge(
                kind: .claudeFiveHour, fraction: Double(snapshot.claude.tokensInWindow) / Double(learned.tokens),
                basis: .learned(tokens: learned.tokens, samples: learned.samples), resetsAt: window.end
            ))
        } else if let budget = budgets.claudeFiveHourTokens, budget > 0, let window = snapshot.claude.window {
            gauges.append(LimitGauge(
                kind: .claudeFiveHour, fraction: Double(snapshot.claude.tokensInWindow) / Double(budget),
                basis: .softBudget(tokens: budget), resetsAt: window.end
            ))
        }
        if let learned = snapshot.claude.learnedWeekly {
            gauges.append(LimitGauge(
                kind: .claudeSevenDay, fraction: Double(snapshot.claude.tokensLast7Days) / Double(learned.tokens),
                basis: .learned(tokens: learned.tokens, samples: learned.samples), resetsAt: nil
            ))
        } else if let budget = budgets.claudeSevenDayTokens, budget > 0 {
            gauges.append(LimitGauge(
                kind: .claudeSevenDay, fraction: Double(snapshot.claude.tokensLast7Days) / Double(budget),
                basis: .softBudget(tokens: budget), resetsAt: nil
            ))
        }
        for (kind, window) in [(Kind.codexFiveHour, snapshot.codex.fiveHour), (.codexWeekly, snapshot.codex.weekly)] {
            if let gauge = reported(kind, window) { gauges.append(gauge) }
        }
        return gauges
    }
}

/// Remembers which windows already triggered an alert, so each window alerts at most once.
/// An alert re-arms when a new window starts or the value drops back below the threshold.
public struct AlertLedger: Codable, Equatable, Sendable {
    /// Codex's reset times jitter by a few seconds between events; closer than this is the same window.
    static let sameWindowTolerance: TimeInterval = 300

    private struct Entry: Codable, Equatable, Sendable {
        var resetsAt: Date?
    }

    private var sent: [String: Entry] = [:]

    public init() {}

    /// Returns the gauges that just crossed `threshold` (0…1) and records them as sent.
    public mutating func due(_ gauges: [LimitGauge], threshold: Double) -> [LimitGauge] {
        var due: [LimitGauge] = []
        for gauge in gauges {
            let key = gauge.kind.rawValue
            guard let fraction = gauge.fraction, fraction >= threshold else {
                sent[key] = nil
                continue
            }
            if let entry = sent[key], Self.sameWindow(entry.resetsAt, gauge.resetsAt) { continue }
            sent[key] = Entry(resetsAt: gauge.resetsAt)
            due.append(gauge)
        }
        return due
    }

    private static func sameWindow(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) < sameWindowTolerance
        default: return false
        }
    }
}
