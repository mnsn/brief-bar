namespace BriefBar.Core.AzureDevOps;

/// How a pipeline run stands.
public enum PipelineRunStatus
{
    Queued,
    Running,
    Succeeded,
    PartiallySucceeded,
    Failed,
    Canceled,
}
