namespace BriefBar.Core.GitHub;

/// What went wrong reading GitHub.
public enum GitHubErrorKind
{
    /// No token: `GitHubError.Auth` says why.
    Auth,

    /// GitHub rejected the token, even a fresh one.
    Unauthorized,

    /// Signed in, but GitHub refused the request.
    Forbidden,

    /// GitHub asked BriefBar to slow down, for `GitHubError.RetryAfter`.
    Throttled,

    Offline,

    /// Another HTTP status, `GitHubError.Status`.
    Http,

    /// The network failed some other way.
    Network,

    /// GitHub answered with something BriefBar can't read.
    Decoding,

    /// GitHub answered with errors and nothing it could read.
    GraphQL,
}
