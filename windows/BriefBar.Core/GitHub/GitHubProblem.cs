using System.Globalization;

namespace BriefBar.Core.GitHub;

/// Why the list may be missing or out of date, with what the GitHub CLI or GitHub said (`Detail`), or until when GitHub
/// asked BriefBar to wait (`Until`). The Mac's `GitHubProblem`.
public sealed record GitHubProblem(GitHubProblemKind Kind, string? Detail = null, DateTimeOffset? Until = null)
{
    public static GitHubProblem CliNotFound { get; } = new(Kind: GitHubProblemKind.CliNotFound);

    public static GitHubProblem Offline { get; } = new(Kind: GitHubProblemKind.Offline);

    /// What the section says, in a sentence.
    public string Message => Kind switch
    {
        GitHubProblemKind.CliNotFound => "BriefBar signs in with the GitHub CLI, which isn't installed.",
        GitHubProblemKind.SignedOut => "Sign in to the GitHub CLI to see your pull requests.",
        GitHubProblemKind.AuthFailed => "Couldn't get a token from the GitHub CLI: " + Detail,
        GitHubProblemKind.Offline => "You're offline. The list may be out of date.",
        GitHubProblemKind.Throttled => "GitHub asked BriefBar to slow down, until "
            + (Until ?? DateTimeOffset.Now).ToLocalTime().ToString(format: "t", formatProvider: CultureInfo.CurrentCulture) + ".",
        GitHubProblemKind.Unreachable => Detail + " The list may be out of date.",
        _ => throw new InvalidOperationException(message: "A problem of an unknown kind."),
    };

    /// Fixed by signing in, or by installing the GitHub CLI first.
    public bool NeedsSignIn => Kind is GitHubProblemKind.CliNotFound or GitHubProblemKind.SignedOut;

    public static GitHubProblem SignedOut(string detail) => new(Kind: GitHubProblemKind.SignedOut, Detail: detail);

    public static GitHubProblem AuthFailed(string detail) => new(Kind: GitHubProblemKind.AuthFailed, Detail: detail);

    public static GitHubProblem Throttled(DateTimeOffset until) => new(Kind: GitHubProblemKind.Throttled, Until: until);

    public static GitHubProblem Unreachable(string detail) => new(Kind: GitHubProblemKind.Unreachable, Detail: detail);

    /// The problem `error` makes, at `now`.
    public static GitHubProblem From(GitHubError error, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: error);
        return error.Kind switch
        {
            GitHubErrorKind.Auth when error.Auth?.Kind == GitHubAuthErrorKind.CliNotFound => CliNotFound,
            GitHubErrorKind.Auth when error.Auth?.Kind == GitHubAuthErrorKind.SignedOut => SignedOut(detail: error.Auth.Message),
            GitHubErrorKind.Auth => AuthFailed(detail: error.Auth?.Message ?? string.Empty),
            GitHubErrorKind.Unauthorized => SignedOut(detail: error.Description),
            GitHubErrorKind.Offline => Offline,
            GitHubErrorKind.Throttled => Throttled(until: now + (error.RetryAfter ?? TimeSpan.Zero)),
            _ => Unreachable(detail: error.Description),
        };
    }
}
