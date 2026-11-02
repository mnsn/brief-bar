using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Demo;
using BriefBar.Core.Presentation;
using BriefBar.Core.Settings;
using BriefBar.Core.Tests.Copilot;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Azure DevOps' source: off until it starts, it reads with its engine, finds your organizations the first time, does
/// what its panel asks, and, once told to stop, saves nothing more. With a made-up engine, organizations and pull
/// requests.
public sealed class AzureDevOpsSourceTests
{
    static readonly DateTimeOffset now = TestTimes.T(seconds: 0);

    [Fact]
    public async Task StartsWithoutWaitingForItsFirstReadThenShowsIt()
    {
        var made = Make();
        using var source = made.Source;
        await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: SectionCondition.Starting, actual: source.Snapshot(section: SectionId.AzureDevOpsPullRequests).Status.Condition);
        var engine = made.Engine();
        // It reads what the settings say, and the pull requests you watch.
        Assert.Equal(expected: ["configure", "link", "start"], actual: engine.Calls);
        Assert.Equal(expected: [AzureDevOpsDemoData.Organization], actual: engine.Configuration?.Organizations);

        var changed = Waiting.NextChange(source: source);
        engine.Publish(snapshot: AzureDevOpsDemoData.Snapshot(now: now));
        await changed.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        var snapshot = source.Snapshot(section: SectionId.AzureDevOpsPullRequests);
        Assert.Equal(expected: new StateCounts(NeedsYou: 3, Failing: 2, Done: 2), actual: snapshot.Counts);
        Assert.Throws<ArgumentException>(testCode: () => source.Snapshot(section: SectionId.CopilotSessions));
    }

    [Fact]
    public async Task DoesWhatItsPanelAsks()
    {
        var made = Make();
        using var source = made.Source;
        await Loaded(made: made);
        var replied = "contoso/4102";

        source.Perform(request: Request(command: AzureDevOpsCommands.Open, rowId: "contoso/4097"));
        var mentioned = Assert.Single(collection: made.Opened);
        Assert.Equal(expected: "https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/4097?discussionId=21", actual: mentioned.AbsoluteUri);
        Assert.Equal(expected: now, actual: made.Settings.SeenCutoff(key: new PRKey(Organization: "contoso", Number: 4097)));
        Assert.False(condition: Row(source: source, id: "contoso/4097").IsNew);

        // The panel follows at once.
        source.Perform(request: Request(command: AzureDevOpsCommands.RemoveFromNeedsYou, rowId: replied));
        Assert.Equal(expected: "waiting", actual: Row(source: source, id: replied).Group);

        // Rows that aren't there, or commands they don't offer, do nothing.
        source.Perform(request: Request(command: AzureDevOpsCommands.Open, rowId: "contoso/1"));
        source.Perform(request: Request(command: AzureDevOpsCommands.RemoveFromNeedsYou, rowId: "contoso/4088"));
        source.Perform(request: Request(command: "unknown", rowId: replied));
        Assert.Single(collection: made.Opened);
        Assert.Equal(expected: "failing", actual: Row(source: source, id: "contoso/4088").Group);

        // Done's Clear sees what it shows: the merged pull request still waiting for approval stays, as on the Mac.
        var merged = Row(source: source, id: "contoso/4085");
        source.Perform(request: new CommandRequest(Section: SectionId.AzureDevOpsPullRequests, Command: AzureDevOpsCommands.Clear, GroupKey: "done"));
        Assert.Equal(expected: merged.Date, actual: made.Settings.SeenCutoff(key: new PRKey(Organization: "contoso", Number: 4085)));
        Assert.Equal(expected: "done", actual: Row(source: source, id: "contoso/4085").Group);

        source.Perform(request: new CommandRequest(Section: SectionId.AzureDevOpsPullRequests, Command: AzureDevOpsCommands.OpenAzureDevOps));
        Assert.Equal(expected: "https://dev.azure.com/contoso/_pulls", actual: made.Opened[^1].AbsoluteUri);
        source.Perform(request: new CommandRequest(Section: SectionId.AzureDevOpsPullRequests, Command: AzureDevOpsCommands.Refresh));
        Assert.Contains(collection: made.Engine().Calls, filter: call => call == "refresh");
    }

    /// Sign in runs `az login` with fixed arguments in a console window that stays open; without the Azure CLI, it opens
    /// the page that says how to install it.
    [Fact]
    public async Task SignsInWithTheAzureCli()
    {
        var made = Make(cli: @"C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd");
        using var source = made.Source;
        await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        source.Perform(request: new CommandRequest(Section: SectionId.AzureDevOpsPullRequests, Command: AzureDevOpsCommands.SignIn));
        var console = Assert.Single(collection: made.Processes.Consoles);
        Assert.Equal(expected: @"C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd", actual: console.Program);
        Assert.Equal(expected: ["login", "--allow-no-subscriptions", "--output", "none"], actual: console.Arguments);
        Assert.True(condition: console.KeepOpen);
        // Fixed words only, which a batch file can take.
        Assert.Equal(
            expected: "/d /v:off /s /k \"\"C:\\Program Files\\Microsoft SDKs\\Azure\\CLI2\\wbin\\az.cmd\" login --allow-no-subscriptions --output none\"",
            actual: ProcessRunner.CmdArguments(program: console.Program, arguments: console.Arguments, keepOpen: true));

        var withoutCli = Make(cli: null);
        using var other = withoutCli.Source;
        await other.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        other.Perform(request: new CommandRequest(Section: SectionId.AzureDevOpsPullRequests, Command: AzureDevOpsCommands.SignIn));
        Assert.Empty(collection: withoutCli.Processes.Consoles);
        Assert.Equal(expected: AzureDevOpsRows.InstallCliPage, actual: Assert.Single(collection: withoutCli.Opened));
    }

    /// Sign in can't start `az login` when `az.cmd` was removed since BriefBar found it, or is at a path with a percent
    /// sign, which `cmd.exe` would read as a variable (`ProcessRunner` refuses it): it opens the page that says how to
    /// install it, rather than ending BriefBar. With `ProcessRunner`, which starts nothing either way.
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SignInOpensTheInstallPageWhenAzLoginCantStart(bool atAPathWithAPercentSign)
    {
        using var folder = new TemporaryFolder();
        var made = Make(cli: atAPathWithAPercentSign ? @"C:\Made up 100%\az.cmd" : folder.Combine("az.cmd"), runner: new ProcessRunner());
        using var source = made.Source;
        await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        source.Perform(request: new CommandRequest(Section: SectionId.AzureDevOpsPullRequests, Command: AzureDevOpsCommands.SignIn));
        Assert.Equal(expected: AzureDevOpsRows.InstallCliPage, actual: Assert.Single(collection: made.Opened));
    }

    /// Without organizations, it finds yours as it starts: it watches the ones with pull requests of yours, keeps all of
    /// them to choose from, and the engine reads them.
    [Fact]
    public async Task FindsYourOrganizationsTheFirstTime()
    {
        var settings = new AzureDevOpsSettings(settings: new MemorySettings(), now: now);
        var made = Make(settings: settings, find: _ => Task.FromResult(result: new OrganizationsFound(All: ["contoso", "fabrikam"], WithPullRequests: ["contoso"])));
        using var source = made.Source;
        await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        await Waiting.Until(condition: () => settings.HasDiscovered);
        Assert.Equal(expected: ["contoso"], actual: settings.Organizations);
        Assert.Equal(expected: ["contoso", "fabrikam"], actual: settings.KnownOrganizations);
        await Waiting.Until(condition: () => made.Engine().Configuration?.Organizations.SequenceEqual(second: ["contoso"]) == true);
    }

    /// Finding them fails, as when you aren't signed in: the section says why, and it tries again later rather than
    /// settling on none.
    [Fact]
    public async Task SaysWhyItCouldntFindYourOrganizations()
    {
        var settings = new AzureDevOpsSettings(settings: new MemorySettings(), now: now);
        var made = Make(settings: settings, find: _ => Task.FromException<OrganizationsFound>(exception: new ADOException(error: ADOError.FromAuth(error: AuthError.SignedOut(message: "Please run az login.")))));
        using var source = made.Source;
        var changed = Waiting.NextChange(source: source);
        await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        await Waiting.Until(condition: () => source.Snapshot(section: SectionId.AzureDevOpsPullRequests).Status.Condition == SectionCondition.Problem);
        var snapshot = source.Snapshot(section: SectionId.AzureDevOpsPullRequests);
        Assert.Equal(expected: "Sign in", actual: snapshot.Status.ShortProblem);
        Assert.Equal(expected: AzureDevOpsCommands.SignIn, actual: snapshot.ProblemCommand?.Key);
        Assert.False(condition: settings.HasDiscovered);
        Assert.Empty(collection: settings.Organizations);
        await changed.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
    }

    /// Stopping doesn't run what a search for your organizations under way registered to stop with: that runs on the
    /// thread pool, so a slow one can't hold up whoever stops it, as BriefBar quitting. The stop ends once it has run.
    [Fact]
    public async Task StoppingDoesntRunTheSearchsCancellationItself()
    {
        using var release = new ManualResetEventSlim(initialState: false);
        var registered = new TaskCompletionSource(creationOptions: TaskCreationOptions.RunContinuationsAsynchronously);
        var heldUp = false;
        var made = Make(
            settings: new AzureDevOpsSettings(settings: new MemorySettings(), now: now),
            find: async cancellationToken =>
            {
                // Released only once StopAsync has returned: run by StopAsync itself, it would wait out its limit.
                cancellationToken.Register(callback: () => Volatile.Write(location: ref heldUp, value: !release.Wait(timeout: Waiting.Limit)));
                registered.TrySetResult();
                await Task.Delay(delay: Timeout.InfiniteTimeSpan, cancellationToken: cancellationToken);
                return new OrganizationsFound(All: [], WithPullRequests: []);
            });
        using var source = made.Source;
        await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        await registered.Task.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);

        var stopped = source.StopAsync();
        release.Set();
        await stopped.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        Assert.False(condition: Volatile.Read(location: ref heldUp));
    }

    /// Once it's stopped, what its engine still hands over changes nothing, and turning it off forgets what you've seen.
    [Fact]
    public async Task StopsAndForgetsWhatItSaved()
    {
        var made = Make();
        using var source = made.Source;
        await Loaded(made: made);
        var engine = made.Engine();
        source.Perform(request: new CommandRequest(Section: SectionId.AzureDevOpsPullRequests, Command: AzureDevOpsCommands.MarkAsSeen, GroupKey: "needsYou"));
        Assert.NotEmpty(collection: made.Settings.Seen.SeenAt);

        await source.StopAsync().WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: "stop", actual: engine.Calls[^1]);
        var before = source.Snapshot(section: SectionId.AzureDevOpsPullRequests);
        engine.Publish(snapshot: new PulseSnapshot());
        Assert.Same(expected: before, actual: source.Snapshot(section: SectionId.AzureDevOpsPullRequests));
        // A late click saves nothing.
        source.Perform(request: Request(command: AzureDevOpsCommands.Open, rowId: "contoso/4097"));
        Assert.Empty(collection: made.Opened);

        source.DeleteSavedData();
        Assert.Empty(collection: made.Settings.Seen.SeenAt);
        // Your organizations stay, with the other settings.
        Assert.Equal(expected: [AzureDevOpsDemoData.Organization], actual: made.Settings.Organizations);
    }

    /// What its panel shows in Answered is seen once the panel closes; a panel that opens reads again if what it shows is
    /// older than 30 seconds.
    [Fact]
    public async Task FollowsItsPanel()
    {
        var made = Make();
        using var source = made.Source;
        await Loaded(made: made);
        var engine = made.Engine();
        Assert.Contains(collection: source.Snapshot(section: SectionId.AzureDevOpsPullRequests).Rows, filter: row => row.Group == "answered");

        source.PanelWillShow(section: SectionId.AzureDevOpsPullRequests);
        Assert.DoesNotContain(collection: engine.Calls, filter: call => call == "refresh");
        made.Clock.Set(time: now.AddMinutes(minutes: 1));
        source.PanelWillShow(section: SectionId.AzureDevOpsPullRequests);
        Assert.Contains(collection: engine.Calls, filter: call => call == "refresh");

        source.PanelVisibilityChanged(section: SectionId.AzureDevOpsPullRequests, isShowing: true);
        var changed = Waiting.NextChange(source: source);
        source.PanelVisibilityChanged(section: SectionId.AzureDevOpsPullRequests, isShowing: false);
        await changed.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        Assert.DoesNotContain(collection: source.Snapshot(section: SectionId.AzureDevOpsPullRequests).Rows, filter: row => row.Group == "answered");
    }

    /// Its engine fails in a way it doesn't expect: it says so, rather than going on as if it read.
    [Fact]
    public async Task SaysSoWhenItCantGoOnReading()
    {
        var made = Make();
        using var source = made.Source;
        await Loaded(made: made);
        var changed = Waiting.NextChange(source: source);
        made.Engine().Fail();
        await changed.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        var status = source.Snapshot(section: SectionId.AzureDevOpsPullRequests).Status;
        Assert.Equal(expected: SectionCondition.Problem, actual: status.Condition);
        Assert.Equal(expected: "BriefBar couldn't read Azure DevOps.", actual: status.Problem);
        // A setting that changes doesn't hide it.
        made.Settings.ShowToReview = true;
        await Task.Delay(millisecondsDelay: 200, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: SectionCondition.Problem, actual: source.Snapshot(section: SectionId.AzureDevOpsPullRequests).Status.Condition);
    }

    /// Turned off, it deletes what it saved maybe before its stop, on the thread pool, has begun: from then on, nothing it
    /// does saves, whether its engine hands over a snapshot, a click or the panel closing arrives late, or a setting
    /// changes.
    [Fact]
    public async Task SavesNothingMoreOnceWhatItSavedIsDeleted()
    {
        var storage = new MemorySettings();
        var made = Make(settings: AzureDevOpsDemoData.Settings(storage: storage, now: now));
        using var source = made.Source;
        await Loaded(made: made);
        source.Perform(request: Request(command: AzureDevOpsCommands.Open, rowId: "contoso/4097"));
        Assert.NotNull(@object: storage.Read(key: AzureDevOpsSettings.SeenKey));

        source.DeleteSavedData();
        Assert.Null(@object: storage.Read(key: AzureDevOpsSettings.SeenKey));
        var before = source.Snapshot(section: SectionId.AzureDevOpsPullRequests);
        made.Engine().Publish(snapshot: AzureDevOpsDemoData.Snapshot(now: now));
        source.PanelVisibilityChanged(section: SectionId.AzureDevOpsPullRequests, isShowing: true);
        source.Perform(request: Request(command: AzureDevOpsCommands.Open, rowId: "contoso/4102"));
        source.Perform(request: Request(command: AzureDevOpsCommands.RemoveFromNeedsYou, rowId: "contoso/4102"));
        source.Perform(request: new CommandRequest(Section: SectionId.AzureDevOpsPullRequests, Command: AzureDevOpsCommands.MarkAsSeen, GroupKey: "needsYou"));
        source.PanelVisibilityChanged(section: SectionId.AzureDevOpsPullRequests, isShowing: false);
        made.Settings.ShowToReview = true;
        // Time for what a setting's change starts, on the thread pool, to have run.
        await Task.Delay(millisecondsDelay: 300, cancellationToken: TestContext.Current.CancellationToken);

        Assert.Null(@object: storage.Read(key: AzureDevOpsSettings.SeenKey));
        Assert.Null(@object: storage.Read(key: AzureDevOpsSettings.OtherSeenKey));
        Assert.Same(expected: before, actual: source.Snapshot(section: SectionId.AzureDevOpsPullRequests));
        Assert.Single(collection: made.Opened);
        await source.StopAsync().WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Contains(collection: made.Engine().Calls, filter: call => call == "stop");
    }

    [Fact]
    public void SaysWhatItReads()
    {
        var description = AzureDevOpsSource.Description;
        Assert.Equal(expected: 1, actual: description.Version);
        Assert.Contains(expectedSubstring: "Every request is a GET", actualString: description.Network, comparisonType: StringComparison.Ordinal);
        Assert.Contains(expectedSubstring: "no personal access token", actualString: description.Needs, comparisonType: StringComparison.Ordinal);
        Assert.DoesNotContain(expectedSubstring: "Sprint", actualString: description.Reads, comparisonType: StringComparison.Ordinal);
    }

    sealed record Made(
        AzureDevOpsSource Source, AzureDevOpsSettings Settings, List<FakePulseEngine> Engines, List<Uri> Opened, FakeProcessRunner Processes, TestClock Clock)
    {
        /// The one engine the source made.
        public FakePulseEngine Engine()
        {
            lock (Engines)
            {
                return Assert.Single(collection: Engines);
            }
        }
    }

    /// A source of the demo's settings, unless `settings` says otherwise, with a made-up engine, organizations from `find`,
    /// and the Azure CLI at `cli`, which `runner` starts, or a made-up runner that starts nothing (`Made.Processes`).
    static Made Make(
        AzureDevOpsSettings? settings = null,
        Func<CancellationToken, Task<OrganizationsFound>>? find = null,
        string? cli = @"C:\az\az.cmd",
        IProcessRunner? runner = null)
    {
        var engines = new List<FakePulseEngine>();
        var opened = new List<Uri>();
        var processes = new FakeProcessRunner();
        var clock = new TestClock(start: now);
        var chosen = settings ?? AzureDevOpsDemoData.Settings(storage: new MemorySettings(), now: now);
        var reading = new AzureDevOpsReading(
            makeEngine: onChange =>
            {
                var engine = new FakePulseEngine(onChange: onChange);
                lock (engines)
                {
                    engines.Add(item: engine);
                }
                return engine;
            },
            findOrganizations: find ?? (_ => Task.FromResult(result: new OrganizationsFound(All: [], WithPullRequests: []))),
            locateCli: () => cli);
        var source = new AzureDevOpsSource(
            settings: chosen,
            reading: reading,
            access: new AzureDevOpsAccess(OpenLink: link =>
            {
                lock (opened)
                {
                    opened.Add(item: link);
                }
            }),
            processes: runner ?? processes,
            time: clock);
        return new Made(Source: source, Settings: chosen, Engines: engines, Opened: opened, Processes: processes, Clock: clock);
    }

    /// Starts `made`'s source, and hands it the demo's pull requests.
    static async Task Loaded(Made made)
    {
        await made.Source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        var changed = Waiting.NextChange(source: made.Source);
        made.Engine().Publish(snapshot: AzureDevOpsDemoData.Snapshot(now: now));
        await changed.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
    }

    static CommandRequest Request(string command, string rowId) => new(Section: SectionId.AzureDevOpsPullRequests, Command: command, RowId: rowId);

    static ItemRow Row(AzureDevOpsSource source, string id) =>
        Assert.Single(collection: source.Snapshot(section: SectionId.AzureDevOpsPullRequests).Rows, predicate: row => row.Id == id);
}
