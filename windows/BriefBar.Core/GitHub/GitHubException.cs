namespace BriefBar.Core.GitHub;

/// Reading GitHub failed: `Error` says how.
public sealed class GitHubException : Exception
{
    public GitHubException()
        : this(error: GitHubError.Network(message: "Couldn't read GitHub."))
    {
    }

    public GitHubException(string message)
        : this(error: GitHubError.Network(message: message))
    {
    }

    public GitHubException(string message, Exception innerException)
        : base(message: message, innerException: innerException)
    {
        Error = GitHubError.Network(message: message);
    }

    public GitHubException(GitHubError error, Exception? innerException = null)
        : base(message: error?.Description, innerException: innerException)
    {
        ArgumentNullException.ThrowIfNull(argument: error);
        Error = error;
    }

    public GitHubError Error { get; }
}
