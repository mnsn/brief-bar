namespace BriefBar.Core.GitHub;

/// Why the GitHub CLI gave no token, and what it said, when it said something. The Mac's `GitHubAuthError`.
public sealed record GitHubAuthError(GitHubAuthErrorKind Kind, string Message = "")
{
    public static GitHubAuthError CliNotFound { get; } = new(Kind: GitHubAuthErrorKind.CliNotFound);

    public string Description => Kind switch
    {
        GitHubAuthErrorKind.CliNotFound => "The GitHub CLI (gh) isn't installed.",
        GitHubAuthErrorKind.SignedOut => Message.Length == 0 ? "Not signed in to the GitHub CLI." : Message,
        _ => Message,
    };

    public static GitHubAuthError SignedOut(string message) => new(Kind: GitHubAuthErrorKind.SignedOut, Message: message);

    public static GitHubAuthError Failed(string message) => new(Kind: GitHubAuthErrorKind.Failed, Message: message);
}
