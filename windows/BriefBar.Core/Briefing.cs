namespace BriefBar.Core;

public static class Briefing
{
    static readonly ItemState[] pressingFirst = [ItemState.NeedsYou, ItemState.Failing, ItemState.Done];

    /// The few lines worth reading first, at most `limit`, so that the brief covers every source with something to say:
    /// each source's most pressing line, then the newest of each state not in it yet, then the most pressing of the
    /// rest. Most pressing is what needs you, then what's wrong, then what's done or ready, the newest first; that's
    /// the order they show in too. What's running isn't in it. A line is the same thing as another with its section and
    /// ID, where the Mac's IDs start with their source.
    public static IReadOnlyList<BriefLine> Pick(IReadOnlyList<BriefLine> lines, int limit = 5)
    {
        ArgumentNullException.ThrowIfNull(argument: lines);
        var ranked = Rank(lines: lines);
        var picked = new List<BriefLine>();
        var sources = new List<SourceId?>();
        foreach (var line in ranked)
        {
            if (sources.Contains(item: line.Source))
            {
                continue;
            }
            sources.Add(item: line.Source);
            Take(picked: picked, line: line, limit: limit);
        }
        foreach (var state in pressingFirst)
        {
            if (!picked.Exists(match: line => line.State == state))
            {
                Take(picked: picked, line: ranked.Find(match: line => line.State == state), limit: limit);
            }
        }
        foreach (var line in ranked)
        {
            Take(picked: picked, line: line, limit: limit);
        }
        // What was picked, in the order the lines show.
        return picked.OrderBy(keySelector: line => ranked.IndexOf(item: line)).ToList();
    }

    /// The lines that can be in a brief, the most pressing first: by state, then the newest first, then as given.
    static List<BriefLine> Rank(IReadOnlyList<BriefLine> lines) => lines
        .Select(selector: (line, index) => (line, index))
        .Where(predicate: pair => Array.IndexOf(array: pressingFirst, value: pair.line.State) >= 0)
        .OrderBy(keySelector: pair => Array.IndexOf(array: pressingFirst, value: pair.line.State))
        .ThenBy(keySelector: pair => pair.line.Date is null ? 1 : 0)
        .ThenByDescending(keySelector: pair => pair.line.Date)
        .ThenBy(keySelector: pair => pair.index)
        .Select(selector: pair => pair.line)
        .ToList();

    static void Take(List<BriefLine> picked, BriefLine? line, int limit)
    {
        if (line is null || picked.Count >= limit || picked.Exists(match: chosen => IsSameThing(first: chosen, second: line)))
        {
            return;
        }
        picked.Add(item: line);
    }

    static bool IsSameThing(BriefLine first, BriefLine second) => first.Section == second.Section && first.Id == second.Id;
}
