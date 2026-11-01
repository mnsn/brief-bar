namespace BriefBar.Core.AzureDevOps;

/// Decides which pull requests' details, two requests each, a refresh reads. The lists have no "last updated", and
/// comments don't change anything in them, so details are swept on a schedule, besides whenever the list shows a change.
/// The Mac's `RefreshPlanner`.
public static class RefreshPlanner
{
    /// The pull requests without details, always; then, up to `limit`, or all of them for null, changed ones by when
    /// they were read, and the ones due by when they became due, the earliest first. One becomes due when it was read
    /// plus its interval, so that pull requests whose builds run can't keep the others waiting.
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
        var missing = new List<PRKey>();
        var changed = new List<(DateTimeOffset FetchedAt, PRKey Key)>();
        var due = new List<(DateTimeOffset DueAt, PRKey Key)>();
        foreach (var candidate in candidates)
        {
            if (!cache.TryGetValue(key: candidate.Key, value: out var entry))
            {
                missing.Add(item: candidate.Key);
                continue;
            }
            if (entry.Fingerprint != candidate.Fingerprint)
            {
                changed.Add(item: (entry.FetchedAt, candidate.Key));
                continue;
            }
            var dueAt = entry.FetchedAt + Interval(entry: entry, options: options);
            if (dueAt <= now)
            {
                due.Add(item: (dueAt, candidate.Key));
            }
        }
        var refreshing = changed.OrderBy(keySelector: item => item.FetchedAt).ThenBy(keySelector: item => item.Key).Select(selector: item => item.Key)
            .Concat(second: due.OrderBy(keySelector: item => item.DueAt).ThenBy(keySelector: item => item.Key).Select(selector: item => item.Key));
        return [.. missing.Order(), .. limit is { } most ? refreshing.Take(count: most) : refreshing];
    }

    /// How long a pull request's details last: `BusyInterval` while a build or check runs on it, else `QuietInterval`
    /// for a quiet one, else `ActiveInterval`.
    static TimeSpan Interval(RefreshPlannerEntry entry, RefreshPlannerOptions options) =>
        entry.IsBusy ? options.BusyInterval : entry.IsQuiet ? options.QuietInterval : options.ActiveInterval;
}
