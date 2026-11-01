namespace BriefBar.Core.AzureDevOps;

/// Decides which pull requests' details, two requests each, a refresh reads. The lists have no "last updated", and
/// comments don't change anything in them, so details are swept on a schedule, besides whenever the list shows a change.
/// The Mac's `RefreshPlanner`.
public static class RefreshPlanner
{
    /// The pull requests without details, always; then, up to `limit`, or all of them for null, changed ones and the ones
    /// whose details are oldest past their interval.
    public static IReadOnlyList<PRKey> Plan(
        IEnumerable<RefreshPlannerCandidate> candidates,
        IReadOnlyDictionary<PRKey, RefreshPlannerEntry> cache,
        DateTimeOffset now,
        RefreshPlannerOptions options,
        int? limit)
    {
        ArgumentNullException.ThrowIfNull(argument: candidates);
        ArgumentNullException.ThrowIfNull(argument: cache);
        ArgumentNullException.ThrowIfNull(argument: options);
        var ranked = new List<(int Priority, DateTimeOffset FetchedAt, PRKey Key)>();
        foreach (var candidate in candidates)
        {
            if (!cache.TryGetValue(key: candidate.Key, value: out var entry))
            {
                ranked.Add(item: (0, DateTimeOffset.MinValue, candidate.Key));
                continue;
            }
            if (entry.Fingerprint != candidate.Fingerprint)
            {
                ranked.Add(item: (1, entry.FetchedAt, candidate.Key));
                continue;
            }
            var age = now - entry.FetchedAt;
            if (entry.IsBusy && age >= options.BusyInterval)
            {
                ranked.Add(item: (2, entry.FetchedAt, candidate.Key));
            }
            else if (entry.IsQuiet ? age >= options.QuietInterval : age >= options.ActiveInterval)
            {
                ranked.Add(item: (3, entry.FetchedAt, candidate.Key));
            }
        }
        var sorted = ranked.OrderBy(keySelector: item => item.Priority).ThenBy(keySelector: item => item.FetchedAt).ThenBy(keySelector: item => item.Key).ToList();
        var missing = sorted.Where(predicate: item => item.Priority == 0).Select(selector: item => item.Key);
        var due = sorted.Where(predicate: item => item.Priority > 0).Select(selector: item => item.Key);
        return [.. missing, .. limit is { } most ? due.Take(count: most) : due];
    }
}
