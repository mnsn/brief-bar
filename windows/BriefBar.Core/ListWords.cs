namespace BriefBar.Core;

/// Names in a sentence, as Windows writes a list: "A", "A and B", "A, B, and C".
public static class ListWords
{
    public static string Join(IReadOnlyList<string> names)
    {
        ArgumentNullException.ThrowIfNull(argument: names);
        return names.Count switch
        {
            0 => string.Empty,
            1 => names[0],
            2 => names[0] + " and " + names[1],
            _ => string.Join(separator: ", ", values: names.Take(count: names.Count - 1)) + ", and " + names[^1],
        };
    }
}
