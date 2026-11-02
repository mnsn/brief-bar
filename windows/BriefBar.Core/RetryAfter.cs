using System.Globalization;

namespace BriefBar.Core;

/// How long Azure DevOps or GitHub asks BriefBar to wait with `Retry-After`, which RFC 9110 lets a server give as a number
/// of seconds or as an HTTP date: at most an hour. `ADOClient` reads it on every answer, and `GitHubClient` on one that
/// refuses a request for its rate limits.
internal static class RetryAfter
{
    /// An HTTP date in each of the forms RFC 9110 has recipients accept: IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`),
    /// RFC 850's (`Sunday, 06-Nov-94 08:49:37 GMT`) and asctime's (`Sun Nov  6 08:49:37 1994`), all in UTC.
    static readonly string[] httpDates = ["r", "dddd, dd'-'MMM'-'yy HH':'mm':'ss 'GMT'", "ddd MMM d HH':'mm':'ss yyyy"];

    /// The longest BriefBar waits when Azure DevOps or GitHub asks it to, however they ask.
    public static TimeSpan Longest { get; } = TimeSpan.FromHours(value: 1);

    /// How long `value`, a `Retry-After` header's, asks to wait from `now`, at most `Longest`: a number of seconds, as the
    /// Mac reads one, or an HTTP date. Null without one, with one that asks for no wait, as a date that has passed does, or
    /// with one that's neither.
    public static TimeSpan? Wait(string? value, DateTimeOffset now)
    {
        var text = value?.Trim();
        if (Seconds(text: text) is { } seconds)
        {
            if (seconds <= 0)
            {
                return null;
            }
            return seconds >= Longest.TotalSeconds ? Longest : TimeSpan.FromSeconds(value: seconds);
        }
        if (text is null
            || !DateTimeOffset.TryParseExact(
                input: text, formats: httpDates, formatProvider: CultureInfo.InvariantCulture, styles: DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.AssumeUniversal, result: out var date)
            || date <= now)
        {
            return null;
        }
        return date - now >= Longest ? Longest : date - now;
    }

    /// A number of seconds, as servers write them in headers such as `Retry-After` and GitHub's `x-ratelimit-reset`, read
    /// as Swift's `TimeInterval(text)` reads one; null for anything else, or one that isn't finite.
    public static double? Seconds(string? text) =>
        text is not null && double.TryParse(s: text, style: NumberStyles.Float, provider: CultureInfo.InvariantCulture, result: out var seconds) && double.IsFinite(d: seconds)
            ? seconds
            : null;
}
