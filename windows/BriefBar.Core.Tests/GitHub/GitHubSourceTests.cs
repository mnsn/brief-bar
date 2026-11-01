using System.ComponentModel;
using BriefBar.Core.Demo;
using BriefBar.Core.GitHub;
using BriefBar.Core.Presentation;
using BriefBar.Core.Settings;

namespace BriefBar.Core.Tests.GitHub;

/// GitHub's source: off until it starts, it reads on the thread pool, one read at a time, does what its panel asks, and,
/// once told to stop, forgets everything; and it saves nothing of yours. With made-up reads and pull requests: the Swift
/// tests' `SourceTests` and the store's reads from `StoreTests`.
public sealed class GitHubSourceTests
{
    const string Cli = @"C:\Program Files\GitHub CLI\gh.exe";

    static readonly DateTimeOffset now = TestTimes.Reference;

    [Fact]
    public async Task StartsWithoutWaitingForItsFirstReadThenShowsIt()
    {
        var made = Make();
        using var source = made.Source;
        Assert.Equal(expected: 0, actual: made.Reads);
        await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: SectionCondition.Starting, actual: source.Snapshot(section: SectionId.GitHubPullRequests).Status.Condition);
        Assert.Equal(expected: "Loading your pull requests…", actual: source.Snapshot(section: SectionId.GitHubPullRequests).EmptyText);

        var changed = Waiting.NextChange(source: source);
        await made.Answer(load: GitHubDemoData.Load(now: now));
        await changed.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        var snapshot = source.Snapshot(section: SectionId.GitHubPullRequests);
        Assert.Equal(expected: new StateCounts(NeedsYou: 3, Failing: 2, Done: 1), actual: snapshot.Counts);
        Assert.Equal(expected: SectionStatus.Updated(time: now), actual: snapshot.Status);
        Assert.Equal(expected: 1, actual: made.Reads);
        Assert.Throws<ArgumentException>(testCode: () => source.Snapshot(section: SectionId.CopilotSessions));
    }

    /// Off until it starts: nothing reads, opens or signs in.
    [Fact]
    public async Task DoesNothingUntilItStarts()
    {
        var made = Make();
        using var source = made.Source;
        source.PanelWillShow(section: SectionId.GitHubPullRequests);
        source.Perform(request: Request(command: GitHubCommands.Refresh));
        source.Perform(request: Request(command: GitHubCommands.SignIn));
        source.Perform(request: Request(command: GitHubCommands.OpenGitHub));
        await Task.Delay(millisecondsDelay: 100, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: 0, actual: made.Reads);
        Assert.Empty(collection: made.Opened);
        Assert.Empty(collection: made.Processes.Consoles);
        Assert.Equal(expected: SectionCondition.Starting, actual: source.Snapshot(section: SectionId.GitHubPullRequests).Status.Condition);
    }

    [Fact]
    public async Task ListsWhatTheBarCountsByStateAndSaysItInTheBrief()
    {
        var made = Make();
        using var source = made.Source;
        await Loaded(made: made);
        var snapshot = source.Snapshot(section: SectionId.GitHubPullRequests);
        Assert.Equal(expected: snapshot.Rows.Count, actual: snapshot.Rows.Select(selector: row => row.Id).Distinct().Count());
        Assert.Equal(expected: 8, actual: snapshot.Rows.Count);
        // Waiting ones are listed, not counted.
        Assert.Equal(expected: 2, actual: snapshot.Rows.Count(predicate: row => row.State is null));

        var briefed = new StateCounts();
        foreach (var line in snapshot.BriefLines)
        {
            briefed = briefed.Adding(state: line.State, count: 1);
        }
        Assert.Equal(expected: snapshot.Counts, actual: briefed);
        Assert.All(collection: snapshot.BriefLines, action: line =>
        {
            Assert.Equal(expected: SectionId.GitHubPullRequests, actual: line.Section);
            Assert.Contains(collection: snapshot.Rows, filter: row => row.Id == line.Id);
            Assert.NotEmpty(collection: line.Sentence);
        });
        Assert.Equal(expected: new SectionAccount(Name: GitHubDemoData.Login, Help: "Signed in to the GitHub CLI as robin"), actual: snapshot.Account);
    }

    [Fact]
    public async Task DoesWhatItsPanelAsks()
    {
        var made = Make();
        using var source = made.Source;
        await Loaded(made: made);
        var pullRequest = GitHubDemoData.Load(now: now).Items[0].PullRequest;

        source.Perform(request: Request(command: GitHubCommands.Open, rowId: pullRequest.Id));
        Assert.Equal(expected: pullRequest.Url, actual: Assert.Single(collection: made.Opened));
        source.Perform(request: Request(command: GitHubCommands.OpenGitHub));
        source.Perform(request: Request(command: GitHubCommands.MoreOnGitHub));
        source.Perform(request: Request(command: GitHubCommands.InstallCli));
        Assert.Equal(
            expected: [pullRequest.Url, new Uri(uriString: "https://github.com/pulls"), new Uri(uriString: "https://github.com/pulls"), new Uri(uriString: "https://cli.github.com")],
            actual: made.Opened);

        // Rows that aren't there, or commands it doesn't offer, do nothing.
        source.Perform(request: Request(command: GitHubCommands.Open, rowId: "PR_gone"));
        source.Perform(request: Request(command: "unknown"));
        source.Perform(request: Request(command: GitHubCommands.OpenGitHub, rowId: pullRequest.Id));
        source.Perform(request: new CommandRequest(Section: SectionId.AzureDevOpsPullRequests, Command: GitHubCommands.OpenGitHub));
        Assert.Equal(expected: 4, actual: made.Opened.Count);

        // Refresh reads again.
        source.Perform(request: Request(command: GitHubCommands.Refresh));
        await Waiting.Until(condition: () => made.Reads == 2);
    }

    /// Only a web address opens, as on the Mac: never another kind of link a pull request might claim.
    [Fact]
    public async Task OpensOnlyWebAddresses()
    {
        var made = Make();
        using var source = made.Source;
        var load = GitHubDemoData.Load(now: now);
        var odd = load.Items[0] with { PullRequest = load.Items[0].PullRequest with { Url = new Uri(uriString: "file:///C:/Windows/notepad.exe") } };
        await Loaded(made: made, load: load with { Items = [odd] });
        source.Perform(request: Request(command: GitHubCommands.Open, rowId: odd.Id));
        Assert.Empty(collection: made.Opened);
    }

    /// Sign in runs `gh auth login` with fixed arguments in a console window that stays open, through `cmd.exe`, which
    /// takes only fixed words, or in a window of its own at a path `cmd.exe` can't take; without the GitHub CLI, or if it
    /// can't start, it opens the page that says how to install it.
    [Fact]
    public async Task SignsInWithTheGitHubCli()
    {
        var made = Make();
        using var source = made.Source;
        await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        source.Perform(request: Request(command: GitHubCommands.SignIn));
        var console = Assert.Single(collection: made.Processes.Consoles);
        Assert.Equal(expected: Cli, actual: console.Program);
        Assert.Equal(expected: ["auth", "login", "--hostname", "github.com", "--web"], actual: console.Arguments);
        Assert.True(condition: console.KeepOpen);
        Assert.Null(@object: console.WorkingDirectory);
        Assert.Empty(collection: console.Environment);
        Assert.Empty(collection: made.Opened);

        var withoutCli = Make(cli: null);
        using var other = withoutCli.Source;
        await other.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        other.Perform(request: Request(command: GitHubCommands.SignIn));
        Assert.Empty(collection: withoutCli.Processes.Consoles);
        Assert.Equal(expected: GitHubRows.InstallCliPage, actual: Assert.Single(collection: withoutCli.Opened));

        var gone = Make();
        gone.Processes.FailToStart(failure: new Win32Exception(error: 2));
        using var third = gone.Source;
        await third.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        third.Perform(request: Request(command: GitHubCommands.SignIn));
        Assert.Equal(expected: GitHubRows.InstallCliPage, actual: Assert.Single(collection: gone.Opened));

        // `cmd.exe` can't take a path with a percent sign: `gh` there gets a window of its own, which closes once it's done.
        var percent = Make(cli: @"C:\Tools\100%\gh.exe");
        using var fourth = percent.Source;
        await fourth.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        fourth.Perform(request: Request(command: GitHubCommands.SignIn));
        Assert.False(condition: Assert.Single(collection: percent.Processes.Consoles).KeepOpen);
        Assert.Empty(collection: percent.Opened);

        // A batch file there can't run at all: what to install comes up, rather than the error.
        var batch = Make(cli: @"C:\Tools\100%\gh.cmd");
        batch.Processes.FailToStart(failure: new ArgumentException(message: "A path that cmd.exe runs can't hold quotes, percent signs or line breaks."));
        using var fifth = batch.Source;
        await fifth.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        fifth.Perform(request: Request(command: GitHubCommands.SignIn));
        Assert.Equal(expected: GitHubRows.InstallCliPage, actual: Assert.Single(collection: batch.Opened));
    }

    /// A panel opening reads again, unless it read in the last 10 seconds, as the Mac's popover does.
    [Fact]
    public async Task ReadsAgainAsItsPanelOpensUnlessItJustDid()
    {
        var made = Make();
        using var source = made.Source;
        await Loaded(made: made);
        source.PanelWillShow(section: SectionId.GitHubPullRequests);
        source.PanelWillShow(section: SectionId.CopilotSessions);
        await Task.Delay(millisecondsDelay: 100, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: 1, actual: made.Reads);

        made.Clock.Set(time: now.AddSeconds(seconds: 10));
        source.PanelWillShow(section: SectionId.GitHubPullRequests);
        await Waiting.Until(condition: () => made.Reads == 2);
    }

    /// Signed out, the list goes, and the section says how to sign in, without counting anything.
    [Fact]
    public async Task AsksYouToSignInInsteadOfCounting()
    {
        var made = Make();
        using var source = made.Source;
        await Loaded(made: made);

        var changed = Waiting.NextChange(source: source);
        source.Perform(request: Request(command: GitHubCommands.Refresh));
        await made.Fail(error: GitHubError.FromAuth(error: GitHubAuthError.SignedOut(message: "no oauth token found for github.com")));
        await changed.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);

        var snapshot = source.Snapshot(section: SectionId.GitHubPullRequests);
        Assert.Equal(expected: SectionCondition.Problem, actual: snapshot.Status.Condition);
        Assert.Equal(expected: "Sign in", actual: snapshot.Status.ShortProblem);
        Assert.Equal(expected: "Sign in to the GitHub CLI to see your pull requests.", actual: snapshot.Status.Problem);
        Assert.Equal(expected: GitHubCommands.SignIn, actual: snapshot.ProblemCommand?.Key);
        Assert.Empty(collection: snapshot.Rows);
        Assert.Empty(collection: snapshot.BriefLines);
        Assert.Equal(expected: new StateCounts(), actual: snapshot.Counts);
        Assert.Null(@object: snapshot.Account);
        Assert.Null(@object: snapshot.Quiet);
    }

    /// Offline or slowed down, the last list stays, out of date, and its counts with it.
    [Fact]
    public async Task OtherProblemsKeepCounting()
    {
        var made = Make();
        using var source = made.Source;
        await Loaded(made: made);

        var changed = Waiting.NextChange(source: source);
        source.Perform(request: Request(command: GitHubCommands.Refresh));
        await made.Fail(error: GitHubError.Offline);
        await changed.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);

        var snapshot = source.Snapshot(section: SectionId.GitHubPullRequests);
        Assert.Equal(expected: SectionCondition.Stale, actual: snapshot.Status.Condition);
        Assert.Equal(expected: "Offline", actual: snapshot.Status.ShortProblem);
        Assert.Equal(expected: now, actual: snapshot.Status.UpdatedAt);
        Assert.Equal(expected: new StateCounts(NeedsYou: 3, Failing: 2, Done: 1), actual: snapshot.Counts);
        Assert.Equal(expected: GitHubCommands.Refresh, actual: snapshot.ProblemCommand?.Key);
    }

    /// Once it's stopped, a read that ends changes nothing, and it read nothing more.
    [Fact]
    public async Task AReadEndingAfterStopIsIgnored()
    {
        var made = Make();
        using var source = made.Source;
        await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        await Waiting.Until(condition: () => made.Reads == 1);
        var before = source.Snapshot(section: SectionId.GitHubPullRequests);

        await source.StopAsync().WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        Assert.True(condition: made.Cancelled);
        await made.Answer(load: GitHubDemoData.Load(now: now));
        await Task.Delay(millisecondsDelay: 100, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Same(expected: before, actual: source.Snapshot(section: SectionId.GitHubPullRequests));
        // A late click opens nothing.
        source.Perform(request: Request(command: GitHubCommands.OpenGitHub));
        Assert.Empty(collection: made.Opened);
        Assert.Equal(expected: 1, actual: made.Reads);
    }

    /// A callback on a read's cancellation that blocks, as one ending a program can, holds up neither turning GitHub off
    /// nor quitting: `StopAsync` returns at once, and finishes once the callback has. What the callback may use stays until
    /// then: disposed as it stops, the source lets go of its connection to GitHub only once that stop has finished.
    [Fact]
    public async Task StopsAtOnceEvenWhenACancellationCallbackBlocks()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        using var release = new ManualResetEventSlim();
        var loading = new TaskCompletionSource(creationOptions: TaskCreationOptions.RunContinuationsAsynchronously);
        var calledBack = new TaskCompletionSource(creationOptions: TaskCreationOptions.RunContinuationsAsynchronously);
        var blocking = default(CancellationTokenRegistration);
        var connection = new Connection();
        var reading = new GitHubReading(
            load: readCancellation =>
            {
                var ended = new TaskCompletionSource<GitHubLoad>(creationOptions: TaskCreationOptions.RunContinuationsAsynchronously);
                // The only way the read ends: once the callback is let go.
                blocking = readCancellation.Register(callback: () =>
                {
                    calledBack.TrySetResult();
                    release.Wait();
                    ended.TrySetCanceled(cancellationToken: readCancellation);
                });
                loading.TrySetResult();
                return ended.Task;
            },
            locateCli: () => Cli,
            owned: connection);
        using var source = new GitHubSource(
            settings: new GitHubSettings(settings: new MemorySettings()),
            reading: reading,
            access: new GitHubAccess(OpenLink: _ => { }),
            processes: new FakeProcessRunner(),
            time: new TestClock(start: now));
        await source.StartAsync(cancellationToken: cancellationToken);
        await loading.Task.WaitAsync(timeout: Waiting.Limit, cancellationToken: cancellationToken);

        Task stop;
        try
        {
            // On another thread: were the callback to run in `StopAsync`, it wouldn't return until the callback did.
            stop = await Task.Factory.StartNew(
                    function: source.StopAsync, cancellationToken: cancellationToken, creationOptions: TaskCreationOptions.None, scheduler: TaskScheduler.Default)
                .WaitAsync(timeout: Waiting.Limit, cancellationToken: cancellationToken);
            await calledBack.Task.WaitAsync(timeout: Waiting.Limit, cancellationToken: cancellationToken);
            source.Dispose();
            Assert.False(condition: stop.IsCompleted);
            Assert.Equal(expected: 0, actual: connection.Disposals);
        }
        finally
        {
            release.Set();
        }
        await stop.WaitAsync(timeout: Waiting.Limit, cancellationToken: cancellationToken);
        await Waiting.Until(condition: () => connection.Disposals == 1);
        await blocking.DisposeAsync();
    }

    /// Reading fails in a way it doesn't expect: it says so, rather than going on as if it read, and reads no more.
    [Fact]
    public async Task SaysSoWhenItCantGoOnReading()
    {
        var made = Make();
        using var source = made.Source;
        await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        await Waiting.Until(condition: () => made.Reads == 1);
        var changed = Waiting.NextChange(source: source);
        await made.Break(failure: new InvalidOperationException(message: "Made-up failure."));
        await changed.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        var status = source.Snapshot(section: SectionId.GitHubPullRequests).Status;
        Assert.Equal(expected: SectionCondition.Problem, actual: status.Condition);
        Assert.Equal(expected: "BriefBar couldn't read GitHub.", actual: status.Problem);

        source.Perform(request: Request(command: GitHubCommands.Refresh));
        await Task.Delay(millisecondsDelay: 100, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: 1, actual: made.Reads);
    }

    [Fact]
    public void SaysWhatItReadsAndWhereItConnects()
    {
        var description = GitHubSource.Description;
        Assert.Equal(expected: 1, actual: description.Version);
        Assert.Contains(expectedSubstring: "request your review by name", actualString: description.Reads, comparisonType: StringComparison.Ordinal);
        Assert.Contains(expectedSubstring: "api.github.com", actualString: description.Network, comparisonType: StringComparison.Ordinal);
        Assert.Contains(expectedSubstring: "never changes anything", actualString: description.Network, comparisonType: StringComparison.Ordinal);
        Assert.Contains(expectedSubstring: "no personal access token", actualString: description.Needs, comparisonType: StringComparison.Ordinal);
        // Windows has no Show Links yet: it doesn't say it reads them.
        Assert.DoesNotContain(expectedSubstring: "Show Links", actualString: description.Reads, comparisonType: StringComparison.Ordinal);
        var made = Make();
        using var source = made.Source;
        Assert.Equal(expected: SourceId.GitHub, actual: source.Source);
        Assert.Equal(expected: [Sections.GitHubPullRequests], actual: source.Sections);
        Assert.Equal(expected: [ItemState.NeedsYou, ItemState.Failing, ItemState.Done], actual: Sections.GitHubPullRequests.States);
    }

    /// Turning GitHub off keeps its settings: it saves nothing else.
    [Fact]
    public void TurningOffKeepsTheRefreshSetting()
    {
        var storage = new MemorySettings();
        var settings = new GitHubSettings(settings: storage) { RefreshMinutes = 15 };
        var made = Make(settings: settings);
        using var source = made.Source;
        source.DeleteSavedData();
        Assert.Equal(expected: 15, actual: settings.RefreshMinutes);
        Assert.Equal(expected: 15, actual: storage.Number(key: GitHubSettings.RefreshMinutesKey));
    }

    /// A source with made-up reads that wait to be answered (`Made.Answer`, `Made.Fail`, `Made.Break`), the GitHub CLI at
    /// `cli`, and what it opened and started.
    static Made Make(GitHubSettings? settings = null, string? cli = Cli)
    {
        var made = new Made(clock: new TestClock(start: now), processes: new FakeProcessRunner());
        var reading = new GitHubReading(load: made.LoadAsync, locateCli: () => cli);
        made.Source = new GitHubSource(
            settings: settings ?? new GitHubSettings(settings: new MemorySettings()),
            reading: reading,
            access: new GitHubAccess(OpenLink: made.Open),
            processes: made.Processes,
            time: made.Clock);
        return made;
    }

    /// Starts `made`'s source, and answers its first read with `load`, the demo's unless said.
    static async Task Loaded(Made made, GitHubLoad? load = null)
    {
        await made.Source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        var changed = Waiting.NextChange(source: made.Source);
        await made.Answer(load: load ?? GitHubDemoData.Load(now: now));
        await changed.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
    }

    static CommandRequest Request(string command, string? rowId = null) => new(Section: SectionId.GitHubPullRequests, Command: command, RowId: rowId);

    /// What a source's reading holds open, as its connection to GitHub: how often it was let go of.
    sealed class Connection : IDisposable
    {
        int disposals;

        public int Disposals => Volatile.Read(location: ref disposals);

        public void Dispose() => Interlocked.Increment(location: ref disposals);
    }

    /// A source, and the reads it made: each waits until it's answered, or cancelled.
    sealed class Made(TestClock clock, FakeProcessRunner processes)
    {
        readonly Lock gate = new();
        readonly List<Uri> opened = [];
        readonly Queue<TaskCompletionSource<GitHubLoad>> waiting = new();
        int reads;
        bool cancelled;

        public TestClock Clock { get; } = clock;

        public FakeProcessRunner Processes { get; } = processes;

        public GitHubSource Source { get; set; } = null!;

        public int Reads
        {
            get
            {
                lock (gate)
                {
                    return reads;
                }
            }
        }

        /// A read was cancelled, as the source stopped.
        public bool Cancelled
        {
            get
            {
                lock (gate)
                {
                    return cancelled;
                }
            }
        }

        public IReadOnlyList<Uri> Opened
        {
            get
            {
                lock (gate)
                {
                    return [.. opened];
                }
            }
        }

        public void Open(Uri link)
        {
            lock (gate)
            {
                opened.Add(item: link);
            }
        }

        public async Task<GitHubLoad> LoadAsync(CancellationToken cancellationToken)
        {
            var read = new TaskCompletionSource<GitHubLoad>(creationOptions: TaskCreationOptions.RunContinuationsAsynchronously);
            lock (gate)
            {
                reads++;
                waiting.Enqueue(item: read);
            }
            try
            {
                return await read.Task.WaitAsync(cancellationToken: cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                lock (gate)
                {
                    cancelled = true;
                }
                throw;
            }
        }

        /// The read that waits longest finds `load`.
        public async Task Answer(GitHubLoad load) => (await NextAsync()).TrySetResult(result: load);

        /// The read that waits longest fails with `error`.
        public async Task Fail(GitHubError error) => (await NextAsync()).TrySetException(exception: new GitHubException(error: error));

        /// The read that waits longest fails in a way BriefBar doesn't expect.
        public async Task Break(Exception failure) => (await NextAsync()).TrySetException(exception: failure);

        /// The read that waits longest, once there's one.
        async Task<TaskCompletionSource<GitHubLoad>> NextAsync()
        {
            TaskCompletionSource<GitHubLoad>? next = null;
            await Waiting.Until(condition: () =>
            {
                lock (gate)
                {
                    return waiting.TryDequeue(result: out next);
                }
            });
            return next!;
        }
    }
}
