import Foundation

/// A 5-hour window inferred from local activity. See FORMATS.md section 3.3.
public struct EstimatedWindow: Equatable, Sendable {
    public var start: Date
    public var end: Date
    /// True when `end` comes from a logged `quotaLimits.resetsAt`, the server's own reset time.
    public var isConfirmedByRefusal: Bool

    public init(start: Date, end: Date, isConfirmedByRefusal: Bool) {
        self.start = start
        self.end = end
        self.isConfirmedByRefusal = isConfirmedByRefusal
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }
}

/// Estimates Claude Code's 5-hour windows. A window starts with the first activity after the previous
/// window ended, floored to 10 minutes, and lasts 5 hours. A reset time from a refusal is ground truth
/// for the window it closes.
///
/// Activity outside Claude Code's logs (claude.ai, the desktop app's chat) shares the same limit but
/// cannot be seen, so a real window can start earlier than estimated. The UI always labels these
/// windows as estimates.
public enum ClaudeWindowEstimator {
    public static let length: TimeInterval = 5 * 3600
    public static let granularity: TimeInterval = 600

    /// - Parameters:
    ///   - activity: Times of prompts and responses, in any order.
    ///   - refusalResets: `resetsAt` values from logged refusals.
    public static func windows(activity: [Date], refusalResets: [Date]) -> [EstimatedWindow] {
        let anchors = Set(refusalResets).map {
            EstimatedWindow(start: $0.addingTimeInterval(-length), end: $0, isConfirmedByRefusal: true)
        }
        var windows: [EstimatedWindow] = []
        for time in activity.sorted() {
            if let anchor = anchors.first(where: { $0.contains(time) }) {
                guard windows.last != anchor else { continue }
                // Ground truth wins: an estimated window that overlaps it ended when the real one began.
                if var last = windows.last, last.end > anchor.start {
                    last.end = max(last.start, anchor.start)
                    windows[windows.count - 1] = last
                }
                windows.append(anchor)
            } else if let last = windows.last, last.contains(time) {
                continue
            } else {
                let start = floor(time)
                let window = EstimatedWindow(start: start, end: start.addingTimeInterval(length), isConfirmedByRefusal: false)
                // Windows never overlap. If flooring lands before the previous window's end (possible
                // when a confirmed reset time is not on a 10-minute mark), start where it ended.
                if let last = windows.last, last.end > window.start {
                    windows.append(EstimatedWindow(start: last.end, end: last.end.addingTimeInterval(length), isConfirmedByRefusal: false))
                } else {
                    windows.append(window)
                }
            }
        }
        return windows.filter { $0.end > $0.start }
    }

    /// The window that contains `now`, or nil when no window is running (the next activity starts one).
    public static func current(at now: Date, activity: [Date], refusalResets: [Date]) -> EstimatedWindow? {
        windows(activity: activity.filter { $0 <= now }, refusalResets: refusalResets).last { $0.contains(now) }
    }

    static func floor(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: seconds - seconds.truncatingRemainder(dividingBy: granularity))
    }
}
