namespace BriefBar.Core.AzureDevOps;

/// Finds a merge's runs among a branch's and a project's. The Mac's `MergeChain`.
public static class MergeChain
{
    /// How long after a merge runs may still start on it, such as a batched CI's.
    public static TimeSpan StartWindow { get; } = TimeSpan.FromMinutes(value: 30);

    /// How long after the last run finished a run it started may still show up.
    public static TimeSpan TriggerWindow { get; } = TimeSpan.FromMinutes(value: 15);

    /// Runs queued this long before the merge's time still count: its time and the runs' come from different clocks.
    public static TimeSpan ClockSlack { get; } = TimeSpan.FromMinutes(value: 5);

    /// The runs on the merge commit, except scheduled ones, which only happened to pick it up; then the runs they started,
    /// and the runs those started, and so on.
    public static IReadOnlyList<ADOBuild> Runs(IReadOnlyList<ADOBuild> onBranch, IReadOnlyList<ADOBuild> triggered, string mergeCommit)
    {
        ArgumentNullException.ThrowIfNull(argument: onBranch);
        ArgumentNullException.ThrowIfNull(argument: triggered);
        ArgumentNullException.ThrowIfNull(argument: mergeCommit);
        var chain = onBranch
            .Where(predicate: build => string.Equals(a: build.SourceVersion, b: mergeCommit, comparisonType: StringComparison.OrdinalIgnoreCase) && build.Reason != "schedule")
            .ToList();
        var ids = chain.Select(selector: build => build.Id).ToHashSet();
        var added = true;
        while (added)
        {
            added = false;
            foreach (var build in triggered)
            {
                if (ids.Contains(item: build.Id) || build.TriggeredByBuildId is not { } parent || !ids.Contains(item: parent))
                {
                    continue;
                }
                chain.Add(item: build);
                ids.Add(item: build.Id);
                added = true;
            }
        }
        return chain;
    }

    /// Whether to keep looking for a merge's runs at `date`: right after it merged, while a run hasn't finished, and a
    /// little while after the last one finished.
    public static bool IsFollowing(DateTimeOffset mergedAt, IEnumerable<PipelineRun> runs, DateTimeOffset date)
    {
        ArgumentNullException.ThrowIfNull(argument: runs);
        if (date - mergedAt < StartWindow)
        {
            return true;
        }
        var all = runs.ToList();
        if (all.Exists(match: run => !run.IsFinished))
        {
            return true;
        }
        return all.Select(selector: run => run.FinishedAt).Max() is { } last && date - last < TriggerWindow;
    }
}
