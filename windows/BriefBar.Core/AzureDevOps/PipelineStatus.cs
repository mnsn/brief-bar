namespace BriefBar.Core.AzureDevOps;

/// A pipeline and its recent runs, the newest first, with the latest one's stages, once its timeline is read, and where
/// it failed, when it did. The Mac's `PipelineStatus`.
public sealed record PipelineStatus(PipelineRef Pipeline, ValueList<PipelineRun> Runs, ValueList<PipelineStage> Stages, PipelineFailure? Failure = null)
{
    public string Id => Pipeline.Id;

    public PipelineRun? Latest => Runs.Count > 0 ? Runs[0] : null;
}
