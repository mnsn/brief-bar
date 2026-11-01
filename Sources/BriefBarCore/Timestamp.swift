import Foundation

/// Allocation-free ISO-8601 parser for timestamps like `2026-10-18T17:00:07.304Z`, including the
/// seven-digit fractions Azure DevOps uses. Copilot's event logs parse one per line, so it avoids
/// (non-Sendable, slow) formatter objects.
public enum Timestamp {
    public static func parse(_ string: String) -> Date? {
        var copy = string
        return copy.withUTF8 { parse(UnsafeRawBufferPointer($0)) }
    }

    /// Accepts `YYYY-MM-DD(T| )HH:MM:SS[.fraction][Z|±HH[[:]MM]]`, with a day that's in its month and an offset under a day.
    public static func parse(_ bytes: UnsafeRawBufferPointer) -> Date? {
        let count = bytes.count
        guard count >= 19 else { return nil }

        func digit(_ index: Int) -> Int? {
            let byte = bytes[index]
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            return Int(byte &- 0x30)
        }
        func number(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for index in start..<(start + length) {
                guard let d = digit(index) else { return nil }
                value = value * 10 + d
            }
            return value
        }
        /// The seconds east of UTC that the rest of the timestamp, from its sign at `start`, says: `±HH`, `±HHMM` or
        /// `±HH:MM`, with hours under 24 and minutes under 60. Nil for anything else, such as `+01:60`, rather than
        /// `+02:00`, or a colon without minutes.
        func offset(from start: Int) -> Int? {
            let minutes: Int?
            switch count - start {
            case 3: minutes = 0
            case 5: minutes = number(start + 3, 2)
            case 6 where bytes[start + 3] == 0x3A: minutes = number(start + 4, 2)
            default: minutes = nil
            }
            guard let offsetMinutes = minutes, let offsetHours = number(start + 1, 2), offsetHours < 24, offsetMinutes < 60
            else { return nil }
            return (bytes[start] == 0x2D ? -1 : 1) * (offsetHours * 3_600 + offsetMinutes * 60)
        }

        guard let year = number(0, 4), bytes[4] == 0x2D,
              let month = number(5, 2), bytes[7] == 0x2D,
              let day = number(8, 2),
              bytes[10] == 0x54 || bytes[10] == 0x74 || bytes[10] == 0x20,
              let hour = number(11, 2), bytes[13] == 0x3A,
              let minute = number(14, 2), bytes[16] == 0x3A,
              let second = number(17, 2)
        else { return nil }
        guard (1...12).contains(month), (1...daysInMonth(year: year, month: month)).contains(day),
              hour < 24, minute < 60, second <= 60
        else { return nil }

        var index = 19
        var fraction = 0.0
        if index < count, bytes[index] == 0x2E || bytes[index] == 0x2C {
            index += 1
            var scale = 0.1
            var sawDigit = false
            while index < count, let d = digit(index) {
                fraction += Double(d) * scale
                scale /= 10
                index += 1
                sawDigit = true
            }
            guard sawDigit else { return nil }
        }

        var offsetSeconds = 0
        if index < count {
            switch bytes[index] {
            case 0x5A, 0x7A: // Z
                index += 1
            case 0x2B, 0x2D: // + or -
                guard let seconds = offset(from: index) else { return nil }
                offsetSeconds = seconds
                index = count
            default:
                return nil
            }
        }
        guard index == count else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let whole = days * 86_400 + hour * 3_600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(whole) + fraction)
    }

    /// Howard Hinnant's days-from-civil algorithm (proleptic Gregorian calendar).
    public static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// How many days `month` has in `year`, in the proleptic Gregorian calendar that `daysFromCivil` counts in: a day
    /// past its month's end, such as February 31, is no date, rather than one in March.
    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Every fourth year, but not every hundredth, unless it's every four hundredth.
    static func isLeapYear(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }
}
