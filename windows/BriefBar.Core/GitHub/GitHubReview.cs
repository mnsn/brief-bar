namespace BriefBar.Core.GitHub;

/// A reviewer's latest review that approves or requests changes: who wrote it, null for a deleted account, and what it
/// says. The Mac's `GitHubPullRequest.Review`.
public sealed record GitHubReview(string? Reviewer, GitHubReviewState State);
