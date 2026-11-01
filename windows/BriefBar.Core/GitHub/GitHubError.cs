using System.Globalization;

namespace BriefBar.Core.GitHub;

/// What went wrong reading GitHub, with what goes with it: the GitHub CLI's error, how long to wait, the HTTP status, or a
/// message. The Mac's `GitHubError`.
public sealed record GitHubError(GitHubErrorKind Kind, GitHubAuthError? Auth = null, TimeSpan? RetryAfter = null, int? Status = null, string? Message = null)
{
    public static GitHubError Unauthorized { get; } = new(Kind: GitHubErrorKind.Unauthorized);

    public static GitHubError Forbidden { get; } = new(Kind: GitHubErrorKind.Forbidden);

    public static GitHubError Offline { get; } = new(Kind: GitHubErrorKind.Offline);

    /// In a sentence.
    public string Description => Kind switch
    {
        GitHubErrorKind.Auth => Auth?.Description ?? "Couldn't sign in.",
        GitHubErrorKind.Unauthorized => "GitHub didn't accept the GitHub CLI's sign-in.",
        GitHubErrorKind.Forbidden => "GitHub refused the request.",
        GitHubErrorKind.Throttled => "GitHub asked BriefBar to slow down.",
        GitHubErrorKind.Offline => "You're offline.",
        GitHubErrorKind.Http => string.Create(provider: CultureInfo.InvariantCulture, handler: $"GitHub answered with HTTP {Status}."),
        GitHubErrorKind.Network => Message ?? "Couldn't reach GitHub.",
        GitHubErrorKind.Decoding => "Unexpected response from GitHub (" + Message + ").",
        GitHubErrorKind.GraphQL => "GitHub couldn't answer: " + Message,
        _ => throw new InvalidOperationException(message: "An error of an unknown kind."),
    };

    public static GitHubError FromAuth(GitHubAuthError error) => new(Kind: GitHubErrorKind.Auth, Auth: error);

    public static GitHubError Throttled(TimeSpan retryAfter) => new(Kind: GitHubErrorKind.Throttled, RetryAfter: retryAfter);

    public static GitHubError Http(int status) => new(Kind: GitHubErrorKind.Http, Status: status);

    public static GitHubError Network(string message) => new(Kind: GitHubErrorKind.Network, Message: message);

    public static GitHubError Decoding(string message) => new(Kind: GitHubErrorKind.Decoding, Message: message);

    public static GitHubError GraphQL(string message) => new(Kind: GitHubErrorKind.GraphQL, Message: message);
}
