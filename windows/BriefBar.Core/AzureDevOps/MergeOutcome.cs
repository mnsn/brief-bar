namespace BriefBar.Core.AzureDevOps;

/// How the pipelines after a merge stand together.
public enum MergeOutcome
{
    /// Some are queued or running, and none failed or waits.
    Running,

    /// One waits for an approval or a check before a stage, and none failed.
    Waiting,

    /// One's latest run failed.
    Failed,

    /// They all finished, and none failed.
    Passed,
}
