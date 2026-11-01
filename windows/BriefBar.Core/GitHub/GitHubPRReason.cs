namespace BriefBar.Core.GitHub;

/// Why a pull request is where it is in the list. The Mac's `GitHubPRReason`.
public enum GitHubPRReason
{
    ReviewRequested,
    ChangesRequested,
    ChecksFailed,
    Conflicts,
    Approved,
    ChecksRunning,
    Draft,
    WaitingForReview,
}
