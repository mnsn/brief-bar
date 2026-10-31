using System.Globalization;

namespace BriefBar.Core;

public static class Elapsed
{
    /// Compact relative time: `now`, `3m`, `1h 5m`, `2d`. Empty for no date. The Mac's `Elapsed.short`.
    public static string Compact(DateTimeOffset? since, DateTimeOffset now)
    {
        if (since is not { } date)
        {
            return string.Empty;
        }
        var seconds = Math.Max(val1: 0, val2: (long)(now - date).TotalSeconds);
        if (seconds < 60)
        {
            return "now";
        }
        var minutes = seconds / 60;
        if (minutes < 60)
        {
            return string.Create(provider: CultureInfo.InvariantCulture, handler: $"{minutes}m");
        }
        var hours = minutes / 60;
        if (hours < 24)
        {
            var remainder = minutes % 60;
            return remainder == 0
                ? string.Create(provider: CultureInfo.InvariantCulture, handler: $"{hours}h")
                : string.Create(provider: CultureInfo.InvariantCulture, handler: $"{hours}h {remainder}m");
        }
        return string.Create(provider: CultureInfo.InvariantCulture, handler: $"{hours / 24}d");
    }

    /// Relative time for Narrator, in words: "just now", "3 minutes ago", "1 hour 5 minutes ago", "2 days ago". Empty
    /// for no date. `Compact`'s "3m" reads as "3 meters".
    public static string Spoken(DateTimeOffset? since, DateTimeOffset now)
    {
        if (since is not { } date)
        {
            return string.Empty;
        }
        var seconds = Math.Max(val1: 0, val2: (long)(now - date).TotalSeconds);
        if (seconds < 60)
        {
            return "just now";
        }
        var minutes = seconds / 60;
        if (minutes < 60)
        {
            return Counted(count: minutes, unit: "minute") + " ago";
        }
        var hours = minutes / 60;
        if (hours < 24)
        {
            var remainder = minutes % 60;
            return remainder == 0
                ? Counted(count: hours, unit: "hour") + " ago"
                : Counted(count: hours, unit: "hour") + " " + Counted(count: remainder, unit: "minute") + " ago";
        }
        return Counted(count: hours / 24, unit: "day") + " ago";
    }

    static string Counted(long count, string unit) =>
        string.Create(provider: CultureInfo.InvariantCulture, handler: $"{count} {unit}{(count == 1 ? string.Empty : "s")}");
}
