namespace BriefBar.Core.AzureDevOps;

/// What started a pipeline run.
public enum PipelineTrigger
{
    Manual,
    Push,
    PullRequest,
    Schedule,
    Pipeline,
    Other,
}
