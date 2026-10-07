import AgentDeckParsing
import Foundation

public enum DashboardRange: String, CaseIterable, Sendable {
    case all
    case last30Days = "30d"
    case last7Days = "7d"

    /// The rows to load: the last N local days including today, or everything.
    public func interval(now: Date, calendar: LocalCalendar) -> DateInterval? {
        let days: Int
        switch self {
        case .all: return nil
        case .last30Days: days = 30
        case .last7Days: days = 7
        }
        let today = calendar.day(containing: now)
        let first = calendar.adding(days: -(days - 1), to: today)
        return DateInterval(start: calendar.start(of: first), end: calendar.interval(of: today).end)
    }
}

/// The stat cards. Definitions are in DECISIONS.md ("Dashboard stat definitions").
public struct DashboardStats: Equatable, Sendable {
    /// Distinct sessions with usage. Codex subagents count toward their parent session.
    public var sessions = 0
    /// Deduplicated model responses.
    public var messages = 0
    public var tokens = TokenCounts()
    /// Local days with at least one response.
    public var activeDays = 0
    /// Local hour (0–23) with the most responses; ties go to the earlier hour.
    public var peakHour: Int?
    /// Model with the most tokens; ties go to the alphabetically first name.
    public var favoriteModel: String?

    public init() {}
}

public struct ModelUsage: Equatable, Sendable {
    public var model: String
    public var source: UsageSource
    public var tokens: TokenCounts
    public var responses: Int
}

/// Token kinds for the stacked daily bars. Cache combines reads and writes.
public enum TokenKind: String, CaseIterable, Sendable {
    case input, output, cache

    public func amount(in tokens: TokenCounts) -> Int {
        switch self {
        case .input: tokens.input
        case .output: tokens.output
        case .cache: tokens.cacheRead + tokens.cacheWrite
        }
    }
}

public struct HeatmapCell: Equatable, Sendable {
    public var day: LocalDay
    public var tokens: TokenCounts
    public var bySource: [UsageSource: Int]
    /// 0 for no usage, 1…4 by quantile of the days that have usage.
    public var level: Int
}

/// Columns are weeks (oldest first), rows are weekdays Sunday…Saturday. The last column is the
/// current week and stops at today.
public struct Heatmap: Equatable, Sendable {
    public var weeks: [[HeatmapCell]]
    /// Upper token bounds of levels 1, 2 and 3; anything above the last is level 4.
    public var thresholds: [Int]
}

public enum DashboardData {
    /// Approximate length of *The Hobbit* in tokens: about 95,000 words at about 1.3 tokens per English
    /// word, the usual rule of thumb for current tokenizers. Used only for the fun line.
    public static let hobbitTokens = 123_500

    public static func stats(_ records: [UsageRecord], calendar: LocalCalendar) -> DashboardStats {
        var stats = DashboardStats()
        var sessions = Set<String>()
        var days = Set<LocalDay>()
        var hours = [Int](repeating: 0, count: 24)
        var modelTokens: [String: Int] = [:]
        for record in records {
            stats.messages += 1
            stats.tokens += record.tokens
            sessions.insert("\(record.source.rawValue)|\(record.sessionID)")
            days.insert(calendar.day(containing: record.timestamp))
            hours[calendar.hour(of: record.timestamp)] += 1
            modelTokens[record.model, default: 0] += record.tokens.total
        }
        stats.sessions = sessions.count
        stats.activeDays = days.count
        if let busiest = hours.max(), busiest > 0 {
            stats.peakHour = hours.firstIndex(of: busiest)
        }
        stats.favoriteModel = modelTokens.max { a, b in
            a.value != b.value ? a.value < b.value : a.key > b.key
        }?.key
        return stats
    }

    /// Most tokens first.
    public static func models(_ records: [UsageRecord]) -> [ModelUsage] {
        var byModel: [String: ModelUsage] = [:]
        for record in records {
            byModel[record.model, default: ModelUsage(model: record.model, source: record.source, tokens: TokenCounts(), responses: 0)]
                .tokens += record.tokens
            byModel[record.model]!.responses += 1
        }
        return byModel.values.sorted { ($0.tokens.total, $1.model) > ($1.tokens.total, $0.model) }
    }

    /// Tokens per local day and kind, for the stacked bars. Days without usage are omitted.
    public static func dailyByKind(_ records: [UsageRecord], calendar: LocalCalendar) -> [(day: LocalDay, kind: TokenKind, tokens: Int)] {
        UsageAggregation.daily(records, calendar: calendar).flatMap { daily in
            TokenKind.allCases.map { (daily.day, $0, $0.amount(in: daily.tokens)) }
        }
    }

    /// - Parameter minimumWeeks: Columns shown even when there is less history (the reference
    ///   screenshot shows 26).
    public static func heatmap(
        _ records: [UsageRecord], calendar: LocalCalendar, today: LocalDay, minimumWeeks: Int = 26
    ) -> Heatmap {
        var byDay: [LocalDay: (tokens: TokenCounts, bySource: [UsageSource: Int])] = [:]
        for record in records {
            let day = calendar.day(containing: record.timestamp)
            byDay[day, default: (TokenCounts(), [:])].tokens += record.tokens
            byDay[day]!.bySource[record.source, default: 0] += record.tokens.total
        }

        let thresholds = quantileThresholds(byDay.values.map(\.tokens.total).filter { $0 > 0 })

        func weekStart(_ day: LocalDay) -> LocalDay { calendar.adding(days: -(calendar.weekday(of: day) - 1), to: day) }
        let currentWeekStart = weekStart(today)
        let earliestWeekStart = weekStart(byDay.keys.min() ?? today)
        let weeksOfHistory = calendar.days(from: earliestWeekStart, to: currentWeekStart) / 7 + 1
        let weekCount = max(minimumWeeks, weeksOfHistory)
        let firstWeekStart = calendar.adding(days: -7 * (weekCount - 1), to: currentWeekStart)

        var weeks: [[HeatmapCell]] = []
        for week in 0..<weekCount {
            var column: [HeatmapCell] = []
            for weekday in 0..<7 {
                let day = calendar.adding(days: week * 7 + weekday, to: firstWeekStart)
                if day > today { break }
                let entry = byDay[day]
                let total = entry?.tokens.total ?? 0
                column.append(HeatmapCell(
                    day: day,
                    tokens: entry?.tokens ?? TokenCounts(),
                    bySource: entry?.bySource ?? [:],
                    level: level(total, thresholds: thresholds)
                ))
            }
            weeks.append(column)
        }
        return Heatmap(weeks: weeks, thresholds: thresholds)
    }

    /// The 25th, 50th and 75th percentiles (nearest rank) of the days with usage.
    static func quantileThresholds(_ values: [Int]) -> [Int] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return [] }
        return [0.25, 0.5, 0.75].map { q in
            sorted[max(0, Int((q * Double(sorted.count)).rounded(.up)) - 1)]
        }
    }

    static func level(_ tokens: Int, thresholds: [Int]) -> Int {
        guard tokens > 0 else { return 0 }
        return (thresholds.firstIndex { tokens <= $0 } ?? thresholds.count) + 1
    }

    /// "That's about 9,826× The Hobbit." Nil below one book.
    public static func funLine(totalTokens: Int) -> String? {
        let books = Double(totalTokens) / Double(hobbitTokens)
        guard books >= 1 else { return nil }
        return "That's about \(Int(books.rounded()).formatted(.number.locale(Locale(identifier: "en_US"))))× The Hobbit."
    }

    /// `claude-opus-5-5` → `Opus 5.5`, `claude-haiku-4-5-20251001` → `Haiku 4.5`. Other names are kept.
    public static func displayName(forModel model: String) -> String {
        let parts = model.split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude" else { return model }
        let version = parts.dropFirst(2).prefix { $0.count <= 2 && Int($0) != nil }
        guard !version.isEmpty else { return model }
        return "\(parts[1].capitalized) \(version.joined(separator: "."))"
    }

    /// `11 PM`, the format of the reference screenshot.
    public static func hourLabel(_ hour: Int) -> String {
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve) \(hour < 12 ? "AM" : "PM")"
    }
}
