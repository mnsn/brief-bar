import Foundation

/// How long an HTTP answer's `Retry-After` asks to wait (RFC 9110, section 10.2.3): a number of seconds, or the HTTP
/// date to wait until. Azure DevOps and GitHub send it when they ask BriefBar to slow down.
public enum RetryAfter {
    /// The wait `value` asks for, from `now`. Nil without a value BriefBar can read, and for a wait that's over, such as
    /// `0` or a date that's passed. Each client bounds it as it needs.
    public static func wait(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        guard let wait = TimeInterval(value) ?? date(value, now: now)?.timeIntervalSince(now), wait > 0 else { return nil }
        return wait
    }

    /// The time an HTTP date names (RFC 9110, section 5.6.7), in any of the three formats a recipient must accept:
    /// `Sun, 06 Nov 1994 08:49:37 GMT`, and the obsolete `Sunday, 06-Nov-94 08:49:37 GMT` and
    /// `Sun Nov  6 08:49:37 1994`. A two-digit year is in `now`'s century, or the one before when that would put it more
    /// than 50 years after `now`. Nil for anything else.
    public static func date(_ text: String, now: Date) -> Date? {
        let words = text.split(separator: " ")
        switch words.count {
        case 6 where words[0].last == "," && shortDays.contains(String(words[0].dropLast())) && words[5] == "GMT":
            guard words[1].count == 2, let day = number(words[1]), let month = monthNumber(words[2]),
                  words[3].count == 4, let year = number(words[3])
            else { return nil }
            return date(year: year, month: month, day: day, time: words[4])
        case 4 where words[0].last == "," && longDays.contains(String(words[0].dropLast())) && words[3] == "GMT":
            let parts = words[1].split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0].count == 2, let day = number(parts[0]), let month = monthNumber(parts[1]),
                  parts[2].count == 2, let year = number(parts[2])
            else { return nil }
            return date(year: fullYear(year, now: now), month: month, day: day, time: words[2])
        case 5 where shortDays.contains(String(words[0])):
            guard let month = monthNumber(words[1]), (1...2).contains(words[2].count), let day = number(words[2]),
                  words[4].count == 4, let year = number(words[4])
            else { return nil }
            return date(year: year, month: month, day: day, time: words[3])
        default:
            return nil
        }
    }

    private static let shortDays: Set<String> = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let longDays: Set<String> = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `year`-`month`-`day`, at `time`, `HH:MM:SS`, in UTC. Nil for a day past its month's end, or a time that isn't one.
    private static func date(year: Int, month: Int, day: Int, time: Substring) -> Date? {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ $0.count == 2 }),
              let hour = number(parts[0]), let minute = number(parts[1]), let second = number(parts[2]),
              hour < 24, minute < 60, second <= 60, (1...Timestamp.daysInMonth(year: year, month: month)).contains(day)
        else { return nil }
        let days = Timestamp.daysFromCivil(year: year, month: month, day: day)
        return Date(timeIntervalSince1970: TimeInterval(days * 86_400 + hour * 3_600 + minute * 60 + second))
    }

    /// January is 1.
    private static func monthNumber(_ name: Substring) -> Int? {
        months.firstIndex(of: String(name)).map { $0 + 1 }
    }

    /// `text` as a number, when it's only ASCII digits: not `+6`, which `Int` reads too.
    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(text)
    }

    /// The year a two-digit one names: in `now`'s century, or the one before when that's more than 50 years after `now`.
    private static func fullYear(_ twoDigits: Int, now: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let current = calendar.component(.year, from: now)
        let year = current - current % 100 + twoDigits
        return year > current + 50 ? year - 100 : year
    }
}
