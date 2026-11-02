namespace BriefBar.Core.AzureDevOps;

/// What the engine reads, and how often: the organizations, a refresh every `Interval`, completed pull requests from as far
/// back as `KeepDoneFor`, drafts and pull requests idle for `InactiveAfter` refreshed less often, the details of
/// `Concurrency` pull requests at a time, and whether it follows the pipelines that run after you merge, while Done keeps
/// the pull request. The Mac's `PulseEngine.Configuration`.
public sealed record PulseEngineConfiguration
{
    public ValueList<string> Organizations { get; init; } = [];

    public TimeSpan Interval { get; init; } = TimeSpan.FromSeconds(value: 60);

    public TimeSpan KeepDoneFor { get; init; } = TimeSpan.FromDays(value: 1);

    public TimeSpan? InactiveAfter { get; init; } = TimeSpan.FromDays(value: 14);

    public RefreshPlannerOptions Planner { get; init; } = new();

    public int Concurrency { get; init; } = 4;

    public bool FollowMerges { get; init; } = true;
}
