namespace BriefBar.Core.AzureDevOps;

/// The pipelines that ran after you merged a pull request: its target branch's runs on its merge commit, the runs those
/// started, and so on, each pipeline with its latest run first, in the order their first runs were queued.
/// `IsFollowing` says runs may yet start, or some haven't finished. The Mac's `MergePipelines`.
public sealed record MergePipelines(
    PRKey PullRequest,
    string Title,
    string TargetBranch,
    DateTimeOffset MergedAt,
    Uri Url,
    ValueList<PipelineStatus> Pipelines,
    bool IsFollowing)
{
    /// How they stand together; null until a run has been found.
    public MergeSummary? Summary => MergeSummary.Of(pipelines: Pipelines);
}
