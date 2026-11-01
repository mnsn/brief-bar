using System.Globalization;

namespace BriefBar.Core;

/// Names in a sentence, as Windows writes a list: "A", "A and B", "A, B, and C"; past `limit` names, the first of them
/// and how many more, "A, B, C, and 2 more", as the Mac's `PullRequestStory.names` says them.
public static class ListWords
{
    public static string Join(IReadOnlyList<string> names, int limit = int.MaxValue)
    {
        ArgumentNullException.ThrowIfNull(argument: names);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(value: limit);
        if (names.Count > limit)
        {
            return Join(names: [.. names.Take(count: limit), (names.Count - limit).ToString(provider: CultureInfo.InvariantCulture) + " more"]);
        }
        return names.Count switch
        {
            0 => string.Empty,
            1 => names[0],
            2 => names[0] + " and " + names[1],
            _ => string.Join(separator: ", ", values: names.Take(count: names.Count - 1)) + ", and " + names[^1],
        };
    }
}
