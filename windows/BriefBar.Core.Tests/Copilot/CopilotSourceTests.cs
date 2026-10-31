using BriefBar.Core.Copilot;
using BriefBar.Core.Presentation;
using BriefBar.Core.Settings;

namespace BriefBar.Core.Tests.Copilot;

public sealed class CopilotSourceTests
{
    static readonly TimeSpan wait = TimeSpan.FromSeconds(value: 10);

    [Fact]
    public async Task StartsWithoutWaitingForItsFirstReadThenShowsIt()
    {
        var (source, engines, _, _) = Make();
        using (source)
        {
            var changed = Changes(source: source);
            await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
            Assert.Equal(expected: SectionCondition.Starting, actual: source.Snapshot(section: SectionId.CopilotSessions).Status.Condition);
            var engine = await Engine(engines: engines);

            engine.Publish(snapshot: Snapshot(Ended(id: "finished", at: DateTimeOffset.UtcNow.AddMinutes(minutes: -2))));
            await changed.WaitAsync(timeout: wait, cancellationToken: TestContext.Current.CancellationToken);
            var snapshot = source.Snapshot(section: SectionId.CopilotSessions);
            Assert.Equal(expected: SectionStatus.Live, actual: snapshot.Status);
            Assert.Equal(expected: ["finished"], actual: snapshot.Rows.Select(selector: row => row.Id));
            Assert.Equal(expected: 1, actual: snapshot.Counts.Done);
            Assert.Throws<ArgumentException>(testCode: () => source.Snapshot(section: SectionId.GitHubPullRequests));
        }
    }

    [Fact]
    public async Task DoesWhatItsPanelAsks()
    {
        var (source, engines, opened, activations) = Make();
        using (source)
        {
            await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
            var engine = await Engine(engines: engines);
            var changed = Changes(source: source);
            engine.Publish(snapshot: Snapshot(Ended(id: "finished", at: DateTimeOffset.UtcNow.AddMinutes(minutes: -2))));
            await changed.WaitAsync(timeout: wait, cancellationToken: TestContext.Current.CancellationToken);

            source.Perform(request: new CommandRequest(Section: SectionId.CopilotSessions, Command: CopilotCommands.Open, RowId: "finished"));
            Assert.Equal(expected: ["finished"], actual: opened);
            source.Perform(request: new CommandRequest(Section: SectionId.CopilotSessions, Command: CopilotCommands.Open, RowId: "gone"));
            source.Perform(request: new CommandRequest(Section: SectionId.CopilotSessions, Command: "unknown", RowId: "finished"));
            Assert.Equal(expected: ["finished"], actual: opened);
            source.Perform(request: new CommandRequest(Section: SectionId.CopilotSessions, Command: CopilotCommands.OpenApp));
            Assert.Single(collection: activations);

            source.Perform(request: new CommandRequest(Section: SectionId.CopilotSessions, Command: CopilotCommands.Clear, GroupKey: "done"));
            var snapshot = source.Snapshot(section: SectionId.CopilotSessions);
            Assert.Equal(expected: 0, actual: snapshot.Counts.Done);
            Assert.Equal(expected: "idle", actual: snapshot.Rows.Single().Group);
            // Only Done and Stopped can be cleared.
            source.Perform(request: new CommandRequest(Section: SectionId.CopilotSessions, Command: CopilotCommands.Clear, GroupKey: "needsYou"));
        }
    }

    [Fact]
    public async Task ShowsWhatItsSettingsSayAsTheyChange()
    {
        var settings = new CopilotSettings(settings: new MemorySettings(), now: DateTimeOffset.UtcNow);
        var (source, engines, _, _) = Make(settings: settings);
        using (source)
        {
            await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
            var engine = await Engine(engines: engines);
            var changed = Changes(source: source);
            var measured = new SessionRecord(
                Meta: new SessionMeta { Id = "working", Name = "Made-up session", IsRunning = true, UpdatedAt = DateTimeOffset.UtcNow, ContextUsage = new ContextUsage(Tokens: 50, Limit: 100) },
                Log: null);
            engine.Publish(snapshot: Snapshot(measured));
            await changed.WaitAsync(timeout: wait, cancellationToken: TestContext.Current.CancellationToken);
            Assert.Null(@object: source.Snapshot(section: SectionId.CopilotSessions).Rows.Single().Meter);

            changed = Changes(source: source);
            settings.ShowContextUsage = true;
            await changed.WaitAsync(timeout: wait, cancellationToken: TestContext.Current.CancellationToken);
            Assert.Equal(expected: "50%", actual: source.Snapshot(section: SectionId.CopilotSessions).Rows.Single().Meter?.Text);
        }
    }

    /// Once it's stopped, what its engine still hands over changes nothing, and turning it off forgets what you cleared.
    [Fact]
    public async Task StopsAndForgetsWhatItSaved()
    {
        var settings = new CopilotSettings(settings: new MemorySettings(), now: DateTimeOffset.UtcNow);
        var (source, engines, _, _) = Make(settings: settings);
        using (source)
        {
            await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
            var engine = await Engine(engines: engines);
            var changed = Changes(source: source);
            engine.Publish(snapshot: Snapshot(Ended(id: "finished", at: DateTimeOffset.UtcNow.AddMinutes(minutes: -2))));
            await changed.WaitAsync(timeout: wait, cancellationToken: TestContext.Current.CancellationToken);
            source.Perform(request: new CommandRequest(Section: SectionId.CopilotSessions, Command: CopilotCommands.Clear, GroupKey: "done"));
            Assert.NotEmpty(collection: settings.Cleared);

            await source.StopAsync();
            Assert.Equal(expected: 1, actual: engine.Stops);
            var before = source.Snapshot(section: SectionId.CopilotSessions);
            engine.Publish(snapshot: Snapshot());
            Assert.Same(expected: before, actual: source.Snapshot(section: SectionId.CopilotSessions));

            source.DeleteSavedData();
            Assert.Empty(collection: settings.Cleared);
        }
    }

    /// Turned off while its engine's first read hasn't begun, it stops the engine only once that read has run, so the
    /// engine can't begin reading after the source is off.
    [Fact]
    public async Task StopsItsEngineOnlyOnceItHasStarted()
    {
        using var holdStart = new ManualResetEventSlim(initialState: false);
        var (source, engines, _, _) = Make(holdStart: holdStart);
        using (source)
        {
            await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
            var stopping = source.StopAsync();
            // Time enough for a stop that doesn't wait to have run.
            await Task.Delay(millisecondsDelay: 200, cancellationToken: TestContext.Current.CancellationToken);
            FakeSessionEngine engine;
            lock (engines)
            {
                engine = Assert.Single(collection: engines);
            }
            Assert.False(condition: stopping.IsCompleted);
            Assert.Empty(collection: engine.Calls);

            holdStart.Set();
            await stopping.WaitAsync(timeout: wait, cancellationToken: TestContext.Current.CancellationToken);
            Assert.Equal(expected: ["start", "stop"], actual: engine.Calls);
        }
    }

    /// Told to stop while its engine's first read still runs, it saves nothing more from then on, whatever its engine or
    /// a late click asks: what it saved can be deleted at once, as turning it off does, without waiting for that read.
    [Fact]
    public async Task SavesNothingMoreOnceToldToStop()
    {
        using var holdStart = new ManualResetEventSlim(initialState: false);
        var settings = new CopilotSettings(settings: new MemorySettings(), now: DateTimeOffset.UtcNow);
        var (source, engines, _, _) = Make(settings: settings, holdStart: holdStart);
        using (source)
        {
            await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
            FakeSessionEngine engine;
            lock (engines)
            {
                engine = Assert.Single(collection: engines);
            }
            var changed = Changes(source: source);
            engine.Publish(snapshot: Snapshot(Ended(id: "finished", at: DateTimeOffset.UtcNow.AddMinutes(minutes: -2))));
            await changed.WaitAsync(timeout: wait, cancellationToken: TestContext.Current.CancellationToken);

            var stopping = source.StopAsync();
            source.DeleteSavedData();
            engine.Publish(snapshot: Snapshot(Ended(id: "finished", at: DateTimeOffset.UtcNow.AddMinutes(minutes: -1))));
            source.Perform(request: new CommandRequest(Section: SectionId.CopilotSessions, Command: CopilotCommands.Clear, GroupKey: "done"));

            Assert.False(condition: stopping.IsCompleted);
            Assert.Empty(collection: settings.Cleared);
            holdStart.Set();
            await stopping.WaitAsync(timeout: wait, cancellationToken: TestContext.Current.CancellationToken);
            Assert.Empty(collection: settings.Cleared);
        }
    }

    /// Its engine failed to start: stopping it still gives back whatever it got to hold.
    [Fact]
    public async Task StopsAnEngineThatFailedToStart()
    {
        var engines = new List<FakeSessionEngine>();
        var source = new CopilotSource(
            settings: new CopilotSettings(settings: new MemorySettings(), now: DateTimeOffset.UtcNow),
            makeEngine: onChange =>
            {
                var engine = new FakeSessionEngine(onChange: onChange, failsToStart: true);
                lock (engines)
                {
                    engines.Add(item: engine);
                }
                return engine;
            },
            app: new CopilotAppAccess(OpenSession: _ => { }, Activate: () => { }, IsInstalled: () => true, IsFrontmost: () => false));
        using (source)
        {
            var changed = Changes(source: source);
            await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
            await changed.WaitAsync(timeout: wait, cancellationToken: TestContext.Current.CancellationToken);
            await source.StopAsync().WaitAsync(timeout: wait, cancellationToken: TestContext.Current.CancellationToken);
            lock (engines)
            {
                Assert.Equal(expected: ["start", "stop"], actual: Assert.Single(collection: engines).Calls);
            }
        }
    }

    /// Reading fails in a way it doesn't expect: it says so, rather than starting forever.
    [Fact]
    public async Task SaysSoWhenItCantStartReading()
    {
        var settings = new CopilotSettings(settings: new MemorySettings(), now: DateTimeOffset.UtcNow);
        var engines = new List<FakeSessionEngine>();
        using var source = new CopilotSource(
            settings: settings,
            makeEngine: onChange =>
            {
                var engine = new FakeSessionEngine(onChange: onChange, failsToStart: true);
                lock (engines)
                {
                    engines.Add(item: engine);
                }
                return engine;
            },
            app: new CopilotAppAccess(OpenSession: _ => { }, Activate: () => { }, IsInstalled: () => true, IsFrontmost: () => false));
        var changed = Changes(source: source);
        await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        await changed.WaitAsync(timeout: wait, cancellationToken: TestContext.Current.CancellationToken);
        var status = source.Snapshot(section: SectionId.CopilotSessions).Status;
        Assert.Equal(expected: SectionCondition.Problem, actual: status.Condition);
        Assert.Equal(expected: "BriefBar couldn't read your Copilot sessions.", actual: status.Problem);
    }

    [Fact]
    public void SaysWhatItReads()
    {
        Assert.Equal(expected: 1, actual: CopilotSource.Description.Version);
        Assert.Contains(expectedSubstring: "read-only", actualString: CopilotSource.Description.Reads, comparisonType: StringComparison.Ordinal);
        Assert.StartsWith(expectedStartString: "None.", actualString: CopilotSource.Description.Network, comparisonType: StringComparison.Ordinal);
    }

    static (CopilotSource Source, List<FakeSessionEngine> Engines, List<string> Opened, List<int> Activations) Make(
        CopilotSettings? settings = null, ManualResetEventSlim? holdStart = null)
    {
        var engines = new List<FakeSessionEngine>();
        var opened = new List<string>();
        var activations = new List<int>();
        var source = new CopilotSource(
            settings: settings ?? new CopilotSettings(settings: new MemorySettings(), now: DateTimeOffset.UtcNow),
            makeEngine: onChange =>
            {
                var engine = new FakeSessionEngine(onChange: onChange, holdStart: holdStart);
                lock (engines)
                {
                    engines.Add(item: engine);
                }
                return engine;
            },
            app: new CopilotAppAccess(OpenSession: opened.Add, Activate: () => activations.Add(item: 1), IsInstalled: () => true, IsFrontmost: () => false));
        return (source, engines, opened, activations);
    }

    /// The engine the source made, once it's started it, on the thread pool.
    static async Task<FakeSessionEngine> Engine(List<FakeSessionEngine> engines)
    {
        var deadline = DateTime.UtcNow + wait;
        while (DateTime.UtcNow < deadline)
        {
            lock (engines)
            {
                if (engines.Count == 1 && engines[0].Starts == 1)
                {
                    return engines[0];
                }
            }
            await Task.Delay(millisecondsDelay: 10, cancellationToken: TestContext.Current.CancellationToken);
        }
        Assert.Fail(message: "The source never started its engine.");
        throw new InvalidOperationException();
    }

    /// Completes the next time the source says it changed.
    static Task Changes(CopilotSource source)
    {
        var next = new TaskCompletionSource(creationOptions: TaskCreationOptions.RunContinuationsAsynchronously);
        void Changed(object? sender, EventArgs e)
        {
            source.Changed -= Changed;
            next.TrySetResult();
        }
        source.Changed += Changed;
        return next.Task;
    }

    static EngineSnapshot Snapshot(params SessionRecord[] records) => new() { Records = [.. records] };

    static SessionRecord Ended(string id, DateTimeOffset at)
    {
        var log = new SessionLogState();
        log.Apply(logEvent: new LogEvent(Timestamp: at.AddSeconds(seconds: -30), Kind: LogEventKind.UserMessage));
        log.Apply(logEvent: new LogEvent(Timestamp: at, Kind: LogEventKind.AgentStop(isSubagent: false)));
        return new SessionRecord(Meta: new SessionMeta { Id = id, Name = "Made-up session", WorkspaceId = id }, Log: log);
    }
}
