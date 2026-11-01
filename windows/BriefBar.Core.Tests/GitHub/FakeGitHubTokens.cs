using BriefBar.Core.GitHub;

namespace BriefBar.Core.Tests.GitHub;

/// Tokens a test controls: `token-<n>`, n going up each time one is rejected, or `Error`. It counts how often it was asked,
/// and told a token was rejected. As the Swift tests' `FakeTokens`.
internal sealed class FakeGitHubTokens(GitHubAuthError? error = null) : IGitHubTokenProvider
{
    readonly Lock gate = new();
    int calls;
    int invalidations;

    public int Calls
    {
        get
        {
            lock (gate)
            {
                return calls;
            }
        }
    }

    public int Invalidations
    {
        get
        {
            lock (gate)
            {
                return invalidations;
            }
        }
    }

    public Task<GitHubToken> TokenAsync(CancellationToken cancellationToken)
    {
        lock (gate)
        {
            calls++;
            return error is { } failure
                ? Task.FromException<GitHubToken>(exception: new GitHubAuthException(error: failure))
                : Task.FromResult(result: new GitHubToken(Value: "token-" + invalidations, FetchedAt: TestTimes.Reference));
        }
    }

    public void Invalidate()
    {
        lock (gate)
        {
            invalidations++;
        }
    }
}
