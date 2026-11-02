using System.Globalization;

namespace BriefBar.Core.Teams;

/// How far you've read a chat in Teams itself, as Teams keeps it: the ID of the newest message you've seen there, which is
/// when it arrived, in milliseconds since 1970, and when you read it, if Teams says. The Mac's `ReadMarker`.
public sealed record ReadMarker(long MessageId, DateTimeOffset? ReadAt = null)
{
    /// Teams' `consumptionhorizon`: `<message ID>;<when it was read, in ms>;<client message ID>`. Null for a chat never
    /// read (`0;0;0`), or without one (empty).
    public static ReadMarker? Parse(string? consumptionHorizon)
    {
        if (string.IsNullOrEmpty(value: consumptionHorizon))
        {
            return null;
        }
        var parts = consumptionHorizon.Split(separator: ';');
        if (!long.TryParse(s: parts[0], style: NumberStyles.None, provider: CultureInfo.InvariantCulture, result: out var id) || id <= 0)
        {
            return null;
        }
        DateTimeOffset? readAt = parts.Length > 1
            && long.TryParse(s: parts[1], style: NumberStyles.None, provider: CultureInfo.InvariantCulture, result: out var milliseconds)
            && milliseconds > 0
            && milliseconds < 253_402_300_799_000
                ? DateTimeOffset.FromUnixTimeMilliseconds(milliseconds: milliseconds)
                : null;
        return new ReadMarker(MessageId: id, ReadAt: readAt);
    }

    /// Whether `consumptionHorizon` is in the form Teams writes for every chat, read or not: a message ID, 0 for a chat
    /// never read, then the rest. A conversation without one in that form says nothing of whether it was read.
    public static bool IsHorizon(string? consumptionHorizon) =>
        !string.IsNullOrEmpty(value: consumptionHorizon)
        && long.TryParse(s: consumptionHorizon.Split(separator: ';')[0], style: NumberStyles.None, provider: CultureInfo.InvariantCulture, result: out _);

    /// Whether the message `messageId` is one of those read.
    public bool Covers(long messageId) => messageId <= MessageId;
}
