using System.Globalization;

namespace BriefBar.Core.Presentation;

/// How a section's status is said: in its item's tooltip, under its panel's title, and to Narrator.
public static class StatusWords
{
    public static string Of(SectionStatus status, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: status);
        return status.Condition switch
        {
            SectionCondition.Starting => "Starting…",
            SectionCondition.Ready when status.IsLive => "Live",
            SectionCondition.Ready when status.UpdatedAt is { } updated => Updated(updatedAt: updated, now: now),
            SectionCondition.Ready => string.Empty,
            SectionCondition.Stale => status.Problem ?? "Couldn't refresh.",
            SectionCondition.Problem => status.Problem ?? "Can't read.",
            SectionCondition.Paused => "Paused: it reads more now than when you turned it on.",
            _ => throw new ArgumentOutOfRangeException(
                paramName: nameof(status), actualValue: status.Condition, message: "Not a condition."),
        };
    }

    /// "Updated just now", "Updated 20 s ago", "Updated 3 min ago", "Updated 2 h ago", "Updated 4 d ago".
    public static string Updated(DateTimeOffset updatedAt, DateTimeOffset now)
    {
        var seconds = Math.Max(val1: 0, val2: (long)(now - updatedAt).TotalSeconds);
        return seconds switch
        {
            < 10 => "Updated just now",
            < 60 => string.Create(provider: CultureInfo.InvariantCulture, handler: $"Updated {seconds} s ago"),
            < 3_600 => string.Create(provider: CultureInfo.InvariantCulture, handler: $"Updated {seconds / 60} min ago"),
            < 86_400 => string.Create(provider: CultureInfo.InvariantCulture, handler: $"Updated {seconds / 3_600} h ago"),
            _ => string.Create(provider: CultureInfo.InvariantCulture, handler: $"Updated {seconds / 86_400} d ago"),
        };
    }
}
