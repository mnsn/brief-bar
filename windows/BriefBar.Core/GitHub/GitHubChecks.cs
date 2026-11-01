namespace BriefBar.Core.GitHub;

/// A pull request's latest commit's checks, all together. The Mac's `GitHubPullRequest.Checks`.
public enum GitHubChecks
{
    Passing,
    Failing,
    Running,
}
