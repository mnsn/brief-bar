namespace BriefBar.Core.AzureDevOps;

/// Where a pull request is: open, merged, abandoned, or something BriefBar doesn't list.
public enum PullRequestStatus
{
    Active,
    Completed,
    Abandoned,
    Other,
}
