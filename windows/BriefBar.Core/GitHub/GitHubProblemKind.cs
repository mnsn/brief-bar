namespace BriefBar.Core.GitHub;

/// Why the list may be missing or out of date.
public enum GitHubProblemKind
{
    CliNotFound,
    SignedOut,
    AuthFailed,
    Offline,
    Throttled,

    /// Nothing could be read: the list shown is the last one that could.
    Unreachable,
}
