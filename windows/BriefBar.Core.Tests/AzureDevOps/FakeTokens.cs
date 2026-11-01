using BriefBar.Core.AzureDevOps;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Tokens a test controls: a fixed value that never expires, for `Account`'s sign-in, or `Error`. It counts how often it
/// was asked, and told a token was rejected. As the Swift tests' `FakeTokens`.
internal sealed class FakeTokens(string value, AuthError? error = null) : IAccessTokenProvider
{
    readonly Lock gate = new();
    AuthError? failure = error;
    string? account;
    int fetches;
    int invalidations;

    public int Fetches
    {
        get
        {
            lock (gate)
            {
                return fetches;
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

    public Task<AccessToken> TokenAsync(CancellationToken cancellationToken)
    {
        lock (gate)
        {
            fetches++;
            return failure is { } failed
                ? Task.FromException<AccessToken>(exception: new AuthException(error: failed))
                : Task.FromResult(result: new AccessToken(Value: value, ExpiresOn: DateTimeOffset.MaxValue, Account: account));
        }
    }

    public void Invalidate()
    {
        lock (gate)
        {
            invalidations++;
        }
    }

    /// Its tokens are `signedIn`'s from now on.
    public void SignIn(string? signedIn)
    {
        lock (gate)
        {
            account = signedIn;
        }
    }

    /// It fails with `error` from now on, or stops failing for null.
    public void Fail(AuthError? error)
    {
        lock (gate)
        {
            failure = error;
        }
    }
}
