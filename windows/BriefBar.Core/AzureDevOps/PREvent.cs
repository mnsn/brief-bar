namespace BriefBar.Core.AzureDevOps;

/// Something that happened that you haven't seen yet, or a comment you have seen that still waits on you. `Id` stays the
/// same across refreshes. `Text` is a comment's, `ThreadId` its thread's, `Count` how many new commits, and `App` where a
/// link was sent, such as "Teams". `IsNew`: it came after you last looked at the pull request. The Mac's `PREvent`.
public sealed record PREvent(
    string Id,
    PREventKind Kind,
    DateTimeOffset At,
    string? Actor = null,
    string? Text = null,
    int? ThreadId = null,
    int? Count = null,
    string? App = null,
    bool IsNew = true);
