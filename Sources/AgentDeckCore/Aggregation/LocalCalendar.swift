import AgentDeckParsing
import Foundation

/// A calendar date in some time zone, without a time.
public struct LocalDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// Converts stored UTC instants into local days and hours. All day logic goes through this type, so
/// the time zone is always explicit and testable. Weeks start on Sunday, as in the dashboard heatmap.
public struct LocalCalendar: Sendable {
    public let timeZone: TimeZone
    private let calendar: Calendar

    public init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 1
        self.timeZone = timeZone
        self.calendar = calendar
    }

    public func day(containing date: Date) -> LocalDay {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return LocalDay(year: c.year!, month: c.month!, day: c.day!)
    }

    /// Local hour of the day, 0–23.
    public func hour(of date: Date) -> Int {
        calendar.component(.hour, from: date)
    }

    /// The first instant of `day`. Usually local midnight; in zones where a DST change skips midnight,
    /// the first time that exists.
    public func start(of day: LocalDay) -> Date {
        let noon = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))!
        return calendar.startOfDay(for: noon)
    }

    /// `[start of day, start of next day)`: 23 or 25 hours long on DST change days.
    public func interval(of day: LocalDay) -> DateInterval {
        DateInterval(start: start(of: day), end: start(of: adding(days: 1, to: day)))
    }

    public func adding(days: Int, to day: LocalDay) -> LocalDay {
        let noon = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))!
        return self.day(containing: calendar.date(byAdding: .day, value: days, to: noon)!)
    }

    /// 1 = Sunday … 7 = Saturday.
    public func weekday(of day: LocalDay) -> Int {
        calendar.component(.weekday, from: start(of: day))
    }

    /// Whole local days from `from` to `to` (negative when `to` is earlier).
    public func days(from: LocalDay, to: LocalDay) -> Int {
        calendar.dateComponents([.day], from: start(of: from), to: start(of: to)).day!
    }
}

/// Totals for one local day.
public struct DailyUsage: Equatable, Sendable {
    public var day: LocalDay
    public var tokens = TokenCounts()
    public var responses = 0

    public init(day: LocalDay, tokens: TokenCounts = TokenCounts(), responses: Int = 0) {
        self.day = day
        self.tokens = tokens
        self.responses = responses
    }
}

public enum UsageAggregation {
    /// Sums rows into local days, oldest first. Days without usage are omitted.
    public static func daily(_ records: [UsageRecord], calendar: LocalCalendar) -> [DailyUsage] {
        var byDay: [LocalDay: DailyUsage] = [:]
        for record in records {
            let day = calendar.day(containing: record.timestamp)
            byDay[day, default: DailyUsage(day: day)].tokens += record.tokens
            byDay[day, default: DailyUsage(day: day)].responses += 1
        }
        return byDay.values.sorted { $0.day < $1.day }
    }
}
