import Foundation

public enum Elapsed {
    /// Compact relative time: `now`, `3m`, `1h 5m`, `2d`.
    public static func short(since date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }
        return "\(hours / 24)d"
    }

    /// The same, as VoiceOver says it, which would read `2m` as meters: `less than a minute`, `3 minutes`, `1 hour 5
    /// minutes`, `2 days`.
    public static func spoken(since date: Date?, now: Date) -> String {
        guard let date else { return "" }
        func count(_ value: Int, _ unit: String) -> String { "\(value) \(unit)\(value == 1 ? "" : "s")" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "less than a minute" }
        let minutes = seconds / 60
        if minutes < 60 { return count(minutes, "minute") }
        let hours = minutes / 60
        if hours < 24 {
            let remainder = minutes % 60
            return remainder == 0 ? count(hours, "hour") : count(hours, "hour") + " " + count(remainder, "minute")
        }
        return count(hours / 24, "day")
    }
}
