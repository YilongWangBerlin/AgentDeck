import AgentDeckCore
import AgentDeckParsing
import Foundation
import Testing

@Suite struct LocalCalendarTests {
    let berlin = LocalCalendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)
    let utc = LocalCalendar(timeZone: TimeZone(identifier: "UTC")!)

    @Test func springForwardDayIs23HoursLong() {
        let interval = berlin.interval(of: LocalDay(year: 2026, month: 3, day: 29))
        #expect(interval.start == date("2026-03-28T23:00:00Z"))
        #expect(interval.duration == 23 * 3600)
    }

    @Test func fallBackDayIs25HoursLong() {
        let interval = berlin.interval(of: LocalDay(year: 2026, month: 10, day: 25))
        #expect(interval.start == date("2026-10-24T22:00:00Z"))
        #expect(interval.duration == 25 * 3600)
    }

    @Test func instantsNearMidnightLandOnTheLocalDay() {
        // 00:30 CEST on Oct 8 is still Oct 7 in UTC.
        #expect(berlin.day(containing: date("2026-10-07T22:30:00Z")) == LocalDay(year: 2026, month: 10, day: 8))
        #expect(utc.day(containing: date("2026-10-07T22:30:00Z")) == LocalDay(year: 2026, month: 10, day: 7))
        // After the fall-back change, local midnight is 23:00 UTC.
        #expect(berlin.day(containing: date("2026-10-25T22:59:59Z")) == LocalDay(year: 2026, month: 10, day: 25))
        #expect(berlin.day(containing: date("2026-10-25T23:00:00Z")) == LocalDay(year: 2026, month: 10, day: 26))
    }

    @Test func hoursAreLocal() {
        #expect(berlin.hour(of: date("2026-10-07T21:30:00Z")) == 23)
        #expect(berlin.hour(of: date("2026-12-07T21:30:00Z")) == 22)
    }

    @Test func weeksStartOnSunday() {
        #expect(berlin.weekday(of: LocalDay(year: 2026, month: 10, day: 4)) == 1)
        #expect(berlin.weekday(of: LocalDay(year: 2026, month: 10, day: 8)) == 5)
    }

    @Test func dayArithmeticCrossesDSTChanges() {
        #expect(berlin.adding(days: 1, to: LocalDay(year: 2026, month: 10, day: 24)) == LocalDay(year: 2026, month: 10, day: 25))
        #expect(berlin.adding(days: -1, to: LocalDay(year: 2026, month: 3, day: 30)) == LocalDay(year: 2026, month: 3, day: 29))
        #expect(berlin.days(from: LocalDay(year: 2026, month: 3, day: 28), to: LocalDay(year: 2026, month: 3, day: 31)) == 3)
        #expect(berlin.days(from: LocalDay(year: 2026, month: 12, day: 30), to: LocalDay(year: 2027, month: 1, day: 2)) == 3)
    }

    @Test func otherZonesWork() {
        let kolkata = LocalCalendar(timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        #expect(kolkata.day(containing: date("2026-10-07T18:45:00Z")) == LocalDay(year: 2026, month: 10, day: 8))

        let losAngeles = LocalCalendar(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        let fallBack = losAngeles.interval(of: LocalDay(year: 2026, month: 11, day: 1))
        #expect(fallBack.start == date("2026-11-01T07:00:00Z"))
        #expect(fallBack.duration == 25 * 3600)
    }

    @Test func dailyTotalsFollowTheChosenTimeZone() {
        func row(_ id: String, _ iso: String, _ tokens: Int) -> UsageRecord {
            UsageRecord(source: .claudeCode, messageID: id, sessionID: "s", timestamp: date(iso), model: "m",
                        tokens: TokenCounts(input: tokens))
        }
        let rows = [
            row("a", "2026-10-24T22:30:00Z", 1),   // Berlin Oct 25 00:30
            row("b", "2026-10-25T22:30:00Z", 10),  // Berlin Oct 25 23:30
            row("c", "2026-10-25T23:30:00Z", 100), // Berlin Oct 26 00:30
        ]

        let local = UsageAggregation.daily(rows, calendar: berlin)
        #expect(local.map(\.day.description) == ["2026-10-25", "2026-10-26"])
        #expect(local.map(\.tokens.total) == [11, 100])
        #expect(local.map(\.responses) == [2, 1])

        let universal = UsageAggregation.daily(rows, calendar: utc)
        #expect(universal.map(\.day.description) == ["2026-10-24", "2026-10-25"])
        #expect(universal.map(\.tokens.total) == [1, 110])
    }
}
