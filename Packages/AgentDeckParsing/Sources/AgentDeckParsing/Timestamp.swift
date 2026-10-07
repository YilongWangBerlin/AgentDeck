import Foundation

/// Parses the ISO-8601 timestamps both tools write, such as `2026-10-07T21:39:43.351Z`.
enum Timestamp {
    /// `Z` timestamps are validated by the fast path only, because `ISO8601DateFormatter` rolls
    /// invalid values over (Feb 30 becomes Mar 2) instead of rejecting them. Other offsets, which the
    /// tools do not write today, go to the formatter.
    static func parse(_ string: String) -> Date? {
        if string.hasSuffix("Z") { return parseUTC(string) }
        return parseWithFormatter(string)
    }

    /// Fast path for `YYYY-MM-DDTHH:MM:SS[.fraction]Z`, the only form seen in the logs.
    static func parseUTC(_ string: String) -> Date? {
        var string = string
        return string.withUTF8 { b -> Date? in
            guard b.count >= 20,
                  b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"),
                  b[10] == UInt8(ascii: "T"), b[13] == UInt8(ascii: ":"), b[16] == UInt8(ascii: ":"),
                  let year = number(b, 0, 4), let month = number(b, 5, 2), let day = number(b, 8, 2),
                  let hour = number(b, 11, 2), let minute = number(b, 14, 2), let second = number(b, 17, 2),
                  (1...12).contains(month), day >= 1, day <= daysInMonth(year, month),
                  hour < 24, minute < 60, second < 60
            else { return nil }

            var i = 19
            var fraction = 0.0
            if b[i] == UInt8(ascii: ".") {
                i += 1
                var digits = 0
                var value = 0
                while i < b.count, let d = digit(b[i]) {
                    if digits < 9 {
                        value = value * 10 + d
                        digits += 1
                    }
                    i += 1
                }
                guard digits > 0 else { return nil }
                fraction = Double(value) / pow(10, Double(digits))
            }
            guard i == b.count - 1, b[i] == UInt8(ascii: "Z") else { return nil }

            let seconds = daysFromCivil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second
            return Date(timeIntervalSince1970: Double(seconds) + fraction)
        }
    }

    static func parseWithFormatter(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's algorithm).
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func digit(_ byte: UInt8) -> Int? {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") ? Int(byte - UInt8(ascii: "0")) : nil
    }

    private static func number(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ length: Int) -> Int? {
        var value = 0
        for i in start..<(start + length) {
            guard let d = digit(b[i]) else { return nil }
            value = value * 10 + d
        }
        return value
    }
}
