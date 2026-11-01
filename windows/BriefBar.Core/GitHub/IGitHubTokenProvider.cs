namespace BriefBar.Core.GitHub;

/// Where GitHub's tokens come from: the GitHub CLI in the app (`GitHubCLITokenProvider`), and stand-ins in tests. The
/// Mac's `GitHubTokenProviding`.
public interface IGitHubTokenProvider
{
    /// A token to use now; throws `GitHubAuthException` when there's none.
    Task<GitHubToken> TokenAsync(CancellationToken cancellationToken);

    /// Forgets a token GitHub rejected, so that the next one is fresh.
    void Invalidate();
}
