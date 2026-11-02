using BriefBar.Core.AzureDevOps;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Tokens a test controls: a fixed value that never expires, for `Account`'s sign-in, or `Error`. For your sign-in's
/// directory, `home`, when it's given, and for the other directories it's signed in to, as `az login --tenant` leaves
/// it: a token for a directory says it after an `@`, so that `StubServer` can tell which directory it's from; one for a
/// directory it isn't signed in to fails, as the Azure CLI's does. It counts how often it was asked, and told a token was
/// rejected, and notes which directories it was asked for. As the Swift tests' `FakeTokens`.
internal sealed class FakeTokens(string value, AuthError? error = null, string? home = null) : IAccessTokenProvider
{
    readonly Lock gate = new();
    /// The other directories it's signed in to.
    readonly HashSet<string> others = [];
    readonly List<string?> asked = [];
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

    /// The directories it was asked for, in order: null for your sign-in's.
    public IReadOnlyList<string?> Asked
    {
        get
        {
            lock (gate)
            {
                return [.. asked];
            }
        }
    }

    public Task<AccessToken> TokenAsync(string? tenant, CancellationToken cancellationToken)
    {
        lock (gate)
        {
            fetches++;
            asked.Add(item: tenant);
            if (failure is { } failed)
            {
                return Task.FromException<AccessToken>(exception: new AuthException(error: failed));
            }
            if (tenant is not null && tenant != home && !others.Contains(item: tenant))
            {
                return Task.FromException<AccessToken>(exception: new AuthException(error: AuthError.SignedOut(message: "AADSTS50076: Sign in with multi-factor authentication.")));
            }
            var directory = tenant ?? home;
            return Task.FromResult(result: new AccessToken(
                Value: directory is null ? value : value + "@" + directory, ExpiresOn: DateTimeOffset.MaxValue, Account: account, Tenant: directory));
        }
    }

    public void Invalidate(string? tenant)
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

    /// Signs in to another directory too, as `az login --tenant` does.
    public void SignInTo(string tenant)
    {
        lock (gate)
        {
            others.Add(item: tenant);
        }
    }

    /// Signs out of another directory.
    public void SignOutOf(string tenant)
    {
        lock (gate)
        {
            others.Remove(item: tenant);
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
