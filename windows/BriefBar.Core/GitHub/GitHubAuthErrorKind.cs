namespace BriefBar.Core.GitHub;

/// Why the GitHub CLI gave no token.
public enum GitHubAuthErrorKind
{
    /// The GitHub CLI isn't installed, or isn't where BriefBar looks.
    CliNotFound,

    /// Not signed in to github.com: `gh auth login` fixes it.
    SignedOut,

    Failed,
}
