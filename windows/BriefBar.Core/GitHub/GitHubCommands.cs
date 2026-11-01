namespace BriefBar.Core.GitHub;

/// What the pull requests' panel can ask the GitHub section to do, by `PanelCommand.Key`.
public static class GitHubCommands
{
    /// A row: opens its pull request on GitHub.
    public const string Open = "open";

    /// The section: your pull requests on GitHub.
    public const string OpenGitHub = "openGitHub";

    /// The section, when more matched than BriefBar reads: the rest, on GitHub.
    public const string MoreOnGitHub = "moreOnGitHub";

    /// The section: reads again now.
    public const string Refresh = "refresh";

    /// The section: signs in to the GitHub CLI, in a console window.
    public const string SignIn = "signIn";

    /// The section: the GitHub CLI's page, which says how to install it.
    public const string InstallCli = "installCli";
}
