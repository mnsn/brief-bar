namespace BriefBar.Core.AzureDevOps;

/// What happened on a pull request, as Azure DevOps records it in a system thread.
public enum ActivityKind
{
    /// New commits were pushed.
    Push,
    Vote,
    ReviewersChanged,

    /// A push reset the reviewers' votes.
    VotesReset,
    DraftChanged,
    AutoComplete,
    Other,
}
