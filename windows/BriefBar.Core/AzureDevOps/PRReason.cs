namespace BriefBar.Core.AzureDevOps;

/// Why a pull request is in its group. A reason can be in more than one group: a vote that wants changes needs you until
/// you've seen it, and then it waits. The Mac's `PRReason`.
public enum PRReason
{
    Mentioned,
    SentInChat,
    Replied,
    Commented,
    ReviewRequested,
    NewCommits,
    ChangesRequested,
    Rejected,
    Answered,
    BuildFailed,
    CheckFailed,
    Conflicts,

    /// Azure DevOps couldn't merge it, for something other than conflicts: the merge failed, or a policy rejected it.
    MergeFailed,
    BuildExpired,

    /// A pipeline that ran after it merged failed.
    FailedAfterMerge,
    ReadyToComplete,
    AutoComplete,
    ReviewPending,
    WaitingForReviewers,
    ChecksRunning,
    RequirementsPending,
    WaitingForAuthor,
    Completed,
    Abandoned,

    /// It merged, and a pipeline that runs after it waits for an approval.
    WaitingForApproval,
    Draft,
    Inactive,
    YouApproved,
    Declined,
}
