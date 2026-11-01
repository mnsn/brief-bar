namespace BriefBar.Core.AzureDevOps;

/// How a stage of a run stands.
public enum PipelineStageState
{
    Pending,

    /// Waiting for an approval or a check before it starts.
    Waiting,
    Running,
    Succeeded,

    /// Succeeded with issues.
    Warning,
    Failed,
    Canceled,
    Skipped,
}
