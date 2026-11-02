namespace BriefBar.Core.GitHub;

/// How `GitHubSource` reads GitHub: one read of your pull requests, where the GitHub CLI is, to sign in with, and what ends
/// what reading has under way between reads, as GitHub is turned off. Live, they share one client, which this owns, and
/// which runs `gh` and connects only as it's first asked to read; the demo makes them up.
public sealed class GitHubReading : IDisposable
{
    readonly Func<CancellationToken, Task<GitHubLoad>> load;
    readonly Func<string?> locateCli;
    readonly IDisposable? owned;
    readonly Func<Task>? stop;

    /// - `stop`: ends what reading has under way apart from a read, such as a run of the GitHub CLI, and forgets the token;
    ///   nothing to end without it.
    public GitHubReading(Func<CancellationToken, Task<GitHubLoad>> load, Func<string?> locateCli, IDisposable? owned = null, Func<Task>? stop = null)
    {
        ArgumentNullException.ThrowIfNull(argument: load);
        ArgumentNullException.ThrowIfNull(argument: locateCli);
        this.load = load;
        this.locateCli = locateCli;
        this.owned = owned;
        this.stop = stop;
    }

    /// GitHub itself, with the GitHub CLI's sign-in that `tokens` gets: stopping ends a run of it under way.
    public static GitHubReading Live(GitHubCLITokenProvider tokens, GitHubCLILocator locator)
    {
        ArgumentNullException.ThrowIfNull(argument: tokens);
        ArgumentNullException.ThrowIfNull(argument: locator);
        var client = new GitHubClient(tokens: tokens);
        return new GitHubReading(
            load: cancellationToken => GitHubReader.LoadAsync(client: client, cancellationToken: cancellationToken),
            locateCli: () => tokens.Program ?? locator.Locate(),
            owned: client,
            stop: tokens.StopAsync);
    }

    /// Your pull requests, in one read; throws `GitHubException` when it can't read them.
    public Task<GitHubLoad> LoadAsync(CancellationToken cancellationToken) => load(arg: cancellationToken);

    /// The GitHub CLI's program, or null when it isn't installed.
    public string? LocateCli() => locateCli();

    /// Ends what reading has under way apart from a read, such as a run of the GitHub CLI, and forgets the token, as
    /// GitHub is turned off, without waiting for it; the task finishes once it has ended. Reading can start again after.
    public Task StopAsync() => stop?.Invoke() ?? Task.CompletedTask;

    public void Dispose() => owned?.Dispose();
}
