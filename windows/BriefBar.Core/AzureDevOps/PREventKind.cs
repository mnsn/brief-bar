namespace BriefBar.Core.AzureDevOps;

/// What happened that you haven't seen yet, or that you have and still waits on you.
public enum PREventKind
{
    Mention,
    SentInChat,
    Reply,
    Comment,
    ReviewRequest,
    NewCommits,
    ChangesRequested,
    Rejected,

    /// News, but it doesn't need you.
    Approved,
}
