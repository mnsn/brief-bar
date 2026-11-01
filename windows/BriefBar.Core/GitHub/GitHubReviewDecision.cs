namespace BriefBar.Core.GitHub;

/// What a repository that requires reviews says of a pull request's reviews. The Mac's `GitHubPullRequest.ReviewDecision`.
public enum GitHubReviewDecision
{
    Approved,
    ChangesRequested,
    ReviewRequired,
}
