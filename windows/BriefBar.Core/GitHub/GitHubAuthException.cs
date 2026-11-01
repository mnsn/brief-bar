namespace BriefBar.Core.GitHub;

/// The GitHub CLI gave no token: `Error` says why.
public sealed class GitHubAuthException : Exception
{
    public GitHubAuthException()
        : this(error: GitHubAuthError.Failed(message: "Couldn't get a token."))
    {
    }

    public GitHubAuthException(string message)
        : this(error: GitHubAuthError.Failed(message: message))
    {
    }

    public GitHubAuthException(string message, Exception innerException)
        : base(message: message, innerException: innerException)
    {
        Error = GitHubAuthError.Failed(message: message);
    }

    public GitHubAuthException(GitHubAuthError error, Exception? innerException = null)
        : base(message: error?.Description, innerException: innerException)
    {
        ArgumentNullException.ThrowIfNull(argument: error);
        Error = error;
    }

    public GitHubAuthError Error { get; }
}
