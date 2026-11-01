using System.Collections.Immutable;

namespace BriefBar.Core.AzureDevOps;

/// What's known of the pipelines after one of your merges: the runs found so far, by ID, and their timelines; when the
/// runs were last looked for, and how many lookups in a row failed. The Mac's `PulseEngine.MergeFollow`.
internal sealed record MergeFollow
{
    public ImmutableDictionary<int, MergeFollowRun> Runs { get; init; } = ImmutableDictionary<int, MergeFollowRun>.Empty;

    public ImmutableDictionary<int, MergeFollowTimeline> Timelines { get; init; } = ImmutableDictionary<int, MergeFollowTimeline>.Empty;

    public DateTimeOffset? LastLookup { get; init; }

    public int Failures { get; init; }

    /// Each pipeline's runs, the newest first, the pipelines in the order their first runs were queued.
    public IReadOnlyList<(PipelineRef Pipeline, IReadOnlyList<PipelineRun> Runs)> ByPipeline => Runs.Values
        .GroupBy(keySelector: found => found.Pipeline.Id, comparer: StringComparer.Ordinal)
        .Select(selector: group => (
            Pipeline: group.First().Pipeline,
            Runs: (IReadOnlyList<PipelineRun>)group.Select(selector: found => found.Run)
                .OrderByDescending(keySelector: run => run.QueuedAt ?? DateTimeOffset.MinValue)
                .ThenByDescending(keySelector: run => run.Id)
                .ToList()))
        .OrderBy(keySelector: pair => pair.Runs.Select(selector: run => run.QueuedAt).Min() ?? DateTimeOffset.MaxValue)
        .ThenBy(keySelector: pair => pair.Pipeline.DefinitionId)
        .ToList();

    /// Each pipeline's latest run.
    public IReadOnlyList<PipelineRun> LatestRuns => ByPipeline.Select(selector: pair => pair.Runs[0]).ToList();
}
