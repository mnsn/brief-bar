namespace BriefBar.Core.AzureDevOps;

/// A stage of a run, or a job for a pipeline without stages. The Mac's `PipelineStage`.
public sealed record PipelineStage(string Id, string Name, PipelineStageState State, DateTimeOffset? StartedAt = null, DateTimeOffset? FinishedAt = null)
{
    /// The run's stages in order, or its jobs when it has no stages of its own: a pipeline without stages has one hidden
    /// stage, `__default`.
    public static IReadOnlyList<PipelineStage> Stages(ADOTimeline timeline, bool runFinished)
    {
        ArgumentNullException.ThrowIfNull(argument: timeline);
        var records = timeline.Records;
        var stages = records.Where(predicate: record => record.Type == "Stage").ToList();
        var chosen = stages;
        if (stages.Count == 0 || (stages.Count == 1 && (stages[0].Identifier == "__default" || stages[0].Name == "__default")))
        {
            var parent = stages.FirstOrDefault()?.Id;
            chosen = records.Where(predicate: record => record.Type == "Phase" && (parent is null || record.ParentId == parent)).ToList();
            if (chosen.Count == 0)
            {
                chosen = records.Where(predicate: record => record.Type == "Job").ToList();
            }
        }
        var waiting = records
            .Where(predicate: record => record.Type == "Checkpoint" && record.State == "inProgress" && record.ParentId is not null)
            .Select(selector: record => record.ParentId!)
            .ToHashSet(comparer: StringComparer.Ordinal);
        return chosen
            .OrderBy(keySelector: record => record.Order ?? int.MaxValue)
            .ThenBy(keySelector: record => record.StartTime ?? DateTimeOffset.MaxValue)
            .Select(selector: record => new PipelineStage(
                Id: record.Id,
                Name: PlainText.SingleLine(text: record.Name ?? record.Identifier ?? "Stage"),
                State: StateOf(record: record, waiting: waiting.Contains(item: record.Id), runFinished: runFinished),
                StartedAt: record.StartTime,
                FinishedAt: record.FinishTime))
            .ToList();
    }

    static PipelineStageState StateOf(ADOTimelineRecord record, bool waiting, bool runFinished) => record.State switch
    {
        "completed" => record.Result switch
        {
            "succeeded" => PipelineStageState.Succeeded,
            "succeededWithIssues" => PipelineStageState.Warning,
            "failed" => PipelineStageState.Failed,
            "canceled" or "abandoned" => PipelineStageState.Canceled,
            _ => PipelineStageState.Skipped,
        },
        "inProgress" => waiting ? PipelineStageState.Waiting : PipelineStageState.Running,
        _ when runFinished => PipelineStageState.Skipped,
        _ => waiting ? PipelineStageState.Waiting : PipelineStageState.Pending,
    };
}
