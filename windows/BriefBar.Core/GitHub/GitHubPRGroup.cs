namespace BriefBar.Core.GitHub;

/// Where a pull request goes in the list, in the list's order. The Mac's `GitHubPRGroup`.
public enum GitHubPRGroup
{
    /// Someone asked you, by name, to review it.
    ToReview,

    /// Yours, and a reviewer asked for changes.
    ChangesRequested,

    /// Yours, and its checks fail or it has merge conflicts.
    Failing,

    /// Yours, and approved.
    Ready,

    /// Yours, and waiting on others: for reviews, for checks to finish, or still a draft.
    Waiting,
}
