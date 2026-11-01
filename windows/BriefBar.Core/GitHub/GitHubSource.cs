using System.ComponentModel;
using BriefBar.Core.Logging;
using BriefBar.Core.Presentation;

namespace BriefBar.Core.GitHub;

/// Your GitHub pull requests, by what they need: the reviews requested from you by name, and which of yours need changes,
/// are failing, are approved or wait on others. It reads github.com with the GitHub CLI's sign-in, with one GraphQL query
/// that only reads, every few minutes. The Mac's `GitHubSource` and `GitHubStore`'s reads, for its pull requests' section.
///
/// It reads on the thread pool, one read at a time, and hands what it found to its store under its own lock, on whichever
/// thread that happens; then it says so with `Changed`. Every 15 seconds it reads again if it's due. Stopped, it forgets
/// everything: it saves nothing, as the list and the token are only ever in memory.
public sealed class GitHubSource : ISectionSource, IDisposable
{
    /// What it reads. Raise `Version` when it reads more, so that a source you turned on waits until you've seen what.
    public static SourceDescription Description { get; } = new(
        Version: 1,
        Summary: "Your GitHub pull requests: reviews requested from you, and which of yours need changes, are failing or are approved",
        Reads: "On github.com: the open pull requests that request your review by name, and your own open pull requests, with "
            + "their checks, reviews, branches and whether they can merge, and who the GitHub CLI is signed in as. BriefBar keeps "
            + "none of it: it reads them again each time.",
        Network: "GitHub only: api.github.com, with the GitHub CLI's sign-in. One read-only GraphQL query (sent as a POST) each "
            + "refresh, every 2 minutes by default. It never changes anything on GitHub.",
        Needs: "The GitHub CLI, signed in with gh auth login: BriefBar gets its token from it, so there's no personal access "
            + "token, and keeps it in memory only. It runs the GitHub CLI in the background, without a window, with fixed "
            + "arguments only.");

    /// What Sign in runs, in a console window: `gh auth login`, which signs in through your browser. BriefBar picks the
    /// sign-in up within a minute.
    public static IReadOnlyList<string> SignInArguments { get; } = ["auth", "login", "--hostname", GitHubCLITokenProvider.Host, "--web"];

    /// Sign in runs with your own environment, as you'd run it in a terminal.
    static readonly Dictionary<string, string?> yourEnvironment = [];

    static readonly TimeSpan tickInterval = TimeSpan.FromSeconds(value: 15);

    readonly Lock gate = new();
    readonly GitHubReading reading;
    readonly GitHubAccess access;
    readonly IProcessRunner processes;
    readonly TimeProvider time;
    readonly GitHubStore store;
    ITimer? ticker;
    /// Ends a read under way, as the source stops; null while it's stopped.
    CancellationTokenSource? stopping;
    Task? refreshing;
    /// Which start what a read found belongs to, so that a read that ends after the source stopped changes nothing.
    int generation;
    /// Reading failed in a way BriefBar doesn't expect: the section says so until it's turned off.
    bool failed;
    /// The kind of the last error a read ended with, logged as it changes; null after a read that worked.
    GitHubErrorKind? lastError;
    SectionSnapshot snapshot = SectionSnapshot.Starting(info: BriefBar.Core.Sections.GitHubPullRequests);
    (SectionCondition Condition, GitHubGroupCounts Counts, GitHubProblemKind? Problem, bool Notice, bool MoreThanShown)? logged;

    /// - `reading`: how it reads GitHub, or the demo's made-up pull requests.
    /// - `access`: what Windows does for it.
    /// - `processes`: what starts `gh auth login` for Sign in.
    public GitHubSource(GitHubSettings settings, GitHubReading reading, GitHubAccess access, IProcessRunner processes, TimeProvider? time = null)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        ArgumentNullException.ThrowIfNull(argument: reading);
        ArgumentNullException.ThrowIfNull(argument: access);
        ArgumentNullException.ThrowIfNull(argument: processes);
        this.reading = reading;
        this.access = access;
        this.processes = processes;
        this.time = time ?? TimeProvider.System;
        store = new GitHubStore(settings: settings);
    }

    public event EventHandler? Changed;

    public SourceId Source => SourceId.GitHub;

    public IReadOnlyList<SectionInfo> Sections { get; } = [BriefBar.Core.Sections.GitHubPullRequests];

    /// Starts reading: its first read starts at once, on the thread pool.
    public Task StartAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        lock (gate)
        {
            if (stopping is not null)
            {
                return Task.CompletedTask;
            }
            generation++;
            failed = false;
            lastError = null;
            logged = null;
            store.Start();
            stopping = new CancellationTokenSource();
            ticker = time.CreateTimer(callback: _ => Tick(), state: null, dueTime: tickInterval, period: tickInterval);
            // What `Rebuild` would show, without logging it: the log says it's starting, then what it read.
            Volatile.Write(location: ref snapshot, value: GitHubRows.Snapshot(store: store));
        }
        Log.Write(line: $"github: starting");
        Refresh();
        return Task.CompletedTask;
    }

    /// Stops reading, and forgets what it read; returns once a read under way has ended.
    public Task StopAsync()
    {
        ITimer? timer;
        CancellationTokenSource? cancel;
        Task? read;
        lock (gate)
        {
            generation++;
            timer = ticker;
            ticker = null;
            cancel = stopping;
            stopping = null;
            read = refreshing;
            refreshing = null;
            store.Stop();
        }
        timer?.Dispose();
        cancel?.Cancel();
        return FinishStoppingAsync(read: read, cancel: cancel);
    }

    /// The list and the token are only ever in memory, and the refresh choice is a setting: there's nothing to delete.
    public void DeleteSavedData()
    {
    }

    public SectionSnapshot Snapshot(SectionId section) =>
        section == SectionId.GitHubPullRequests
            ? Volatile.Read(location: ref snapshot)
            : throw new ArgumentException(message: "Not one of this source's sections.", paramName: nameof(section));

    public void Perform(CommandRequest request)
    {
        ArgumentNullException.ThrowIfNull(argument: request);
        if (request.Section != SectionId.GitHubPullRequests || !IsRunning)
        {
            return;
        }
        if (request.RowId is { } id)
        {
            if (request.Command == GitHubCommands.Open && PullRequestUrl(id: id) is { } url)
            {
                Open(page: url);
            }
            return;
        }
        switch (request.Command)
        {
            case GitHubCommands.OpenGitHub or GitHubCommands.MoreOnGitHub:
                Open(page: GitHubRows.PullRequestsPage);
                break;
            case GitHubCommands.InstallCli:
                Open(page: GitHubRows.InstallCliPage);
                break;
            case GitHubCommands.Refresh:
                Refresh();
                break;
            case GitHubCommands.SignIn:
                SignIn();
                break;
            default:
                // A command it doesn't offer.
                break;
        }
    }

    /// Reads again now if it last did more than 10 seconds ago, as the Mac does as a list opens.
    public void PanelWillShow(SectionId section)
    {
        if (section != SectionId.GitHubPullRequests)
        {
            return;
        }
        bool stale;
        lock (gate)
        {
            stale = stopping is not null && store.IsStale(date: time.GetUtcNow());
        }
        if (stale)
        {
            Refresh();
        }
    }

    /// Stops it as `StopAsync` does, without waiting, and lets go of its connection to GitHub once it has stopped.
    public void Dispose() => _ = StopAsync().ContinueWith(
        continuationAction: _ => reading.Dispose(),
        cancellationToken: CancellationToken.None,
        continuationOptions: TaskContinuationOptions.ExecuteSynchronously,
        scheduler: TaskScheduler.Default);

    /// Waits for `read`, which `cancel` asks to end, then lets go of `cancel`.
    static async Task FinishStoppingAsync(Task? read, CancellationTokenSource? cancel)
    {
        try
        {
            if (read is not null)
            {
                await read.ConfigureAwait(options: ConfigureAwaitOptions.SuppressThrowing);
            }
        }
        finally
        {
            cancel?.Dispose();
        }
    }

    bool IsRunning
    {
        get
        {
            lock (gate)
            {
                return stopping is not null;
            }
        }
    }

    /// The link of the pull request with node ID `id`, while it's listed.
    Uri? PullRequestUrl(string id)
    {
        lock (gate)
        {
            return store.Items.FirstOrDefault(predicate: item => item.Id == id)?.PullRequest.Url;
        }
    }

    /// Opens a GitHub page in your browser: only a web address, never another kind of link, as on the Mac.
    void Open(Uri page)
    {
        if (page.Scheme == Uri.UriSchemeHttps)
        {
            access.OpenLink(obj: page);
        }
    }

    /// Reads now, on the thread pool, unless a read is under way, it's stopped, or GitHub said to wait.
    void Refresh()
    {
        lock (gate)
        {
            if (stopping is null || failed || !store.BeginRefresh(now: time.GetUtcNow()))
            {
                return;
            }
            var current = generation;
            var cancellationToken = stopping.Token;
            var read = Task.Run(function: () => ReadAsync(fromGeneration: current, cancellationToken: cancellationToken), cancellationToken: CancellationToken.None);
            refreshing = read;
            _ = read.ContinueWith(
                continuationAction: failure => Failed(error: failure.Exception!, fromGeneration: current),
                cancellationToken: CancellationToken.None,
                continuationOptions: TaskContinuationOptions.OnlyOnFaulted,
                scheduler: TaskScheduler.Default);
        }
    }

    async Task ReadAsync(int fromGeneration, CancellationToken cancellationToken)
    {
        GitHubLoad? load = null;
        GitHubError? error = null;
        try
        {
            load = await reading.LoadAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        }
        catch (GitHubException failure)
        {
            error = failure.Error;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Stopped: it forgot everything already.
            return;
        }
        bool newError;
        lock (gate)
        {
            if (fromGeneration != generation)
            {
                return;
            }
            refreshing = null;
            var now = time.GetUtcNow();
            if (load is not null)
            {
                store.Receive(load: load, now: now);
            }
            else
            {
                store.Fail(error: error!, now: now);
            }
            newError = error is not null && error.Kind != lastError;
            lastError = error?.Kind;
            Rebuild();
        }
        if (newError)
        {
            Log.Write(line: $"github: couldn't read: {error!.Kind}, sign-in {error.Auth?.Kind}");
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }

    /// Reads again if it's due.
    void Tick()
    {
        bool due;
        lock (gate)
        {
            due = stopping is not null && store.IsDue(date: time.GetUtcNow());
        }
        if (due)
        {
            Refresh();
        }
    }

    /// Runs `gh auth login` in a console window, which stays open once it's done, so you can read what it said; or, without
    /// the GitHub CLI, opens the page that says how to install it.
    void SignIn()
    {
        if (reading.LocateCli() is not { } program)
        {
            Open(page: GitHubRows.InstallCliPage);
            return;
        }
        Log.Write(line: $"github: signing in with gh auth login");
        try
        {
            processes.StartInConsole(program: program, arguments: SignInArguments, workingDirectory: null, environment: yourEnvironment, keepOpen: true);
        }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException or IOException)
        {
            // It was uninstalled or moved since BriefBar found it: what to install comes up in its place.
            Log.Write(error: error, context: $"github: couldn't start gh auth login");
            Open(page: GitHubRows.InstallCliPage);
        }
    }

    /// What the section shows now, from the store; logged when how it stands changes, in counts.
    void Rebuild()
    {
        if (failed)
        {
            return;
        }
        var built = GitHubRows.Snapshot(store: store);
        Volatile.Write(location: ref snapshot, value: built);
        (SectionCondition Condition, GitHubGroupCounts Counts, GitHubProblemKind? Problem, bool Notice, bool MoreThanShown) state =
            (built.Status.Condition, store.Counts, store.Problem?.Kind, store.Notice is not null, store.MoreThanShown);
        if (logged is { } last && last.Condition == state.Condition && last.Counts.Equals(other: state.Counts) && last.Problem == state.Problem
            && last.Notice == state.Notice && last.MoreThanShown == state.MoreThanShown)
        {
            return;
        }
        logged = state;
        var counts = state.Counts;
        Log.Write(line: $"github: {state.Condition}, problem {state.Problem}, notice {state.Notice}, more than shown {state.MoreThanShown}: {counts[GitHubPRGroup.ToReview]} to review, {counts[GitHubPRGroup.ChangesRequested]} with changes requested, {counts[GitHubPRGroup.Failing]} failing, {counts[GitHubPRGroup.Ready]} ready, {counts[GitHubPRGroup.Waiting]} waiting");
    }

    /// Reading failed in a way BriefBar doesn't expect: the section says so, rather than going on as if it read.
    void Failed(AggregateException error, int fromGeneration)
    {
        Log.Write(error: error.GetBaseException(), context: $"github: stopped reading");
        lock (gate)
        {
            if (fromGeneration != generation)
            {
                return;
            }
            failed = true;
            refreshing = null;
            Volatile.Write(location: ref snapshot, value: SectionSnapshot.Starting(info: BriefBar.Core.Sections.GitHubPullRequests) with
            {
                Status = new SectionStatus(Condition: SectionCondition.Problem, Problem: "BriefBar couldn't read GitHub.", ShortProblem: "Can't read"),
            });
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }
}
