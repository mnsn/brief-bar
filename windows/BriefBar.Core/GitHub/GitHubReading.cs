namespace BriefBar.Core.GitHub;

/// How `GitHubSource` reads GitHub: one read of your pull requests, and where the GitHub CLI is, to sign in with. Live,
/// they share one client, which this owns, and which runs `gh` and connects only as it's first asked to read; the demo
/// makes them up.
public sealed class GitHubReading : IDisposable
{
    readonly Func<CancellationToken, Task<GitHubLoad>> load;
    readonly Func<string?> locateCli;
    readonly IDisposable? owned;

    public GitHubReading(Func<CancellationToken, Task<GitHubLoad>> load, Func<string?> locateCli, IDisposable? owned = null)
    {
        ArgumentNullException.ThrowIfNull(argument: load);
        ArgumentNullException.ThrowIfNull(argument: locateCli);
        this.load = load;
        this.locateCli = locateCli;
        this.owned = owned;
    }

    /// GitHub itself, with the GitHub CLI's sign-in that `tokens` gets.
    public static GitHubReading Live(GitHubCLITokenProvider tokens, GitHubCLILocator locator)
    {
        ArgumentNullException.ThrowIfNull(argument: tokens);
        ArgumentNullException.ThrowIfNull(argument: locator);
        var client = new GitHubClient(tokens: tokens);
        return new GitHubReading(
            load: cancellationToken => GitHubReader.LoadAsync(client: client, cancellationToken: cancellationToken),
            locateCli: () => tokens.Program ?? locator.Locate(),
            owned: client);
    }

    /// Your pull requests, in one read; throws `GitHubException` when it can't read them.
    public Task<GitHubLoad> LoadAsync(CancellationToken cancellationToken) => load(arg: cancellationToken);

    /// The GitHub CLI's program, or null when it isn't installed.
    public string? LocateCli() => locateCli();

    public void Dispose() => owned?.Dispose();
}
