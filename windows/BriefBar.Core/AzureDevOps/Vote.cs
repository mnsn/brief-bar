namespace BriefBar.Core.AzureDevOps;

/// A reviewer's vote, with Azure DevOps' values.
public enum Vote
{
    Rejected = -10,
    WaitingForAuthor = -5,
    None = 0,
    ApprovedWithSuggestions = 5,
    Approved = 10,
}
