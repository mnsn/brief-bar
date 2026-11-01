namespace BriefBar.Core.GitHub;

/// What a reviewer's latest review that counts says. The Mac's `GitHubPullRequest.Review.State`.
public enum GitHubReviewState
{
    Approved,
    ChangesRequested,
}
