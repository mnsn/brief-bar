namespace BriefBar.Core.GitHub;

/// What one read of GitHub found: who the GitHub CLI is signed in as, the pull requests in the list's order, what GitHub
/// couldn't read (`Notice`), such as an organization's pull requests that need single sign-on, and whether more matched
/// than BriefBar reads (`PullRequestQuery.Count` of each kind). The Mac's `GitHubLoad`.
public sealed record GitHubLoad(string Login, ValueList<GitHubPRSnapshot> Items, string? Notice = null, bool MoreThanShown = false)
{
    public GitHubGroupCounts Counts => new(snapshots: Items);
}
