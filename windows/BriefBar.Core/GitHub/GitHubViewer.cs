namespace BriefBar.Core.GitHub;

/// Who the GitHub CLI is signed in as, as the query reads it. The Mac's `PullRequestQueryData.Viewer`.
public sealed record GitHubViewer(string Login);
