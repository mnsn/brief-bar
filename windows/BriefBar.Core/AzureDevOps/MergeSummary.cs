namespace BriefBar.Core.AzureDevOps;

/// How the pipelines after a merge stand together, for its pull request's row and the brief: the outcome, how many ran
/// and how many are queued or running, the pipeline that failed or waits, with the stage it waits for or where it failed,
/// that run and its page, and when it came to this. The Mac's `MergeSummary`.
public sealed record MergeSummary(
    MergeOutcome Outcome,
    int Total,
    int Running = 0,
    string? Pipeline = null,
    string? Stage = null,
    PipelineFailure? Failure = null,
    int? RunId = null,
    Uri? RunUrl = null,
    DateTimeOffset? Since = null)
{
    /// How `pipelines` stand together: something failed comes first, then something waiting, then something running.
    /// Null without any run.
    public static MergeSummary? Of(IReadOnlyList<PipelineStatus> pipelines)
    {
        ArgumentNullException.ThrowIfNull(argument: pipelines);
        var latest = pipelines.Where(predicate: status => status.Latest is not null).Select(selector: status => (Status: status, Run: status.Latest!)).ToList();
        if (latest.Count == 0)
        {
            return null;
        }
        var running = latest.Count(predicate: pair => !pair.Run.IsFinished);
        if (latest.FirstOrDefault(predicate: pair => pair.Run.Status == PipelineRunStatus.Failed) is { Run: not null } failed)
        {
            return new MergeSummary(
                Outcome: MergeOutcome.Failed,
                Total: latest.Count,
                Running: running,
                Pipeline: failed.Status.Pipeline.Name,
                Stage: failed.Status.Failure?.Stage,
                Failure: failed.Status.Failure,
                RunId: failed.Run.Id,
                RunUrl: failed.Run.WebUrl,
                Since: failed.Run.ChangedAt);
        }
        if (latest.FirstOrDefault(predicate: pair => !pair.Run.IsFinished && pair.Status.Stages.Any(predicate: stage => stage.State == PipelineStageState.Waiting)) is { Run: not null } waiting)
        {
            return new MergeSummary(
                Outcome: MergeOutcome.Waiting,
                Total: latest.Count,
                Running: running,
                Pipeline: waiting.Status.Pipeline.Name,
                Stage: waiting.Status.Stages.First(predicate: stage => stage.State == PipelineStageState.Waiting).Name,
                RunId: waiting.Run.Id,
                RunUrl: waiting.Run.WebUrl,
                Since: waiting.Run.StartedAt ?? waiting.Run.QueuedAt);
        }
        if (running > 0)
        {
            return new MergeSummary(Outcome: MergeOutcome.Running, Total: latest.Count, Running: running, Since: latest.Max(selector: pair => pair.Run.QueuedAt));
        }
        return new MergeSummary(Outcome: MergeOutcome.Passed, Total: latest.Count, Since: latest.Max(selector: pair => pair.Run.FinishedAt));
    }
}
