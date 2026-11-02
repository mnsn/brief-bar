using BriefBar.Core.Demo;
using BriefBar.Core.Presentation;
using BriefBar.Core.Settings;
using BriefBar.Core.Teams;
using BriefBar.Core.Tests.Copilot;

namespace BriefBar.Core.Tests.Teams;

/// Teams as a source: off until it's started, showing what its engine reads, doing what its panels ask, and deleting what
/// it saved when it's turned off.
public sealed class TeamsSourceTests
{
    static readonly DateTimeOffset now = Times.At(seconds: 0);

    [Fact]
    public async Task StartsWithoutWaitingForItsFirstReadThenShowsIt()
    {
        using var folder = new TemporaryFolder();
        var made = Make(folder: folder);
        using var source = made.Source;
        Assert.Equal(expected: [SectionId.TeamsChats, SectionId.TeamsGroupChats], actual: source.Sections.Select(selector: section => section.Id));

        await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: SectionCondition.Starting, actual: source.Snapshot(section: SectionId.TeamsChats).Status.Condition);
        var engine = await Started(made: made);
        var changed = Waiting.NextChange(source: source);
        engine.Publish(snapshot: TeamsDemoData.Snapshot(now: now));
        await changed.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);

        var chats = source.Snapshot(section: SectionId.TeamsChats);
        Assert.Equal(expected: SectionStatus.Live, actual: chats.Status);
        Assert.Equal(expected: [TeamsDemoData.Avery, TeamsDemoData.Sam, TeamsDemoData.Noah], actual: chats.Rows.Select(selector: row => row.Id));
        Assert.Equal(expected: DemoData.TeamsChats(now: now).BriefLines.Select(selector: line => line.Sentence), actual: chats.BriefLines.Select(selector: line => line.Sentence));
        var groups = source.Snapshot(section: SectionId.TeamsGroupChats);
        Assert.Equal(expected: [TeamsDemoData.LaunchCrew, TeamsDemoData.WeeklySync, TeamsDemoData.DesignReviews], actual: groups.Rows.Select(selector: row => row.Id));
        Assert.Equal(expected: new StateCounts(NeedsYou: 2), actual: groups.Counts);
        Assert.Throws<ArgumentException>(testCode: () => source.Snapshot(section: SectionId.CopilotSessions));
    }

    [Fact]
    public async Task DoesWhatItsPanelsAsk()
    {
        using var folder = new TemporaryFolder();
        var made = Make(folder: folder);
        using var source = made.Source;
        await Show(made: made, snapshot: TeamsDemoData.Snapshot(now: now));

        source.Perform(request: new CommandRequest(Section: SectionId.TeamsChats, Command: TeamsCommands.Open, RowId: TeamsDemoData.Avery));
        // At the chat's oldest unread message, read in BriefBar from then on.
        var averyFirst = TeamsDemoData.Snapshot(now: now).Messages[TeamsDemoData.Avery][0].Id;
        Assert.Equal(expected: [DeepLink.Message(conversationId: TeamsDemoData.Avery, messageId: averyFirst)!], actual: made.Opened);
        Assert.Equal(expected: 1, actual: source.Snapshot(section: SectionId.TeamsChats).Counts.NeedsYou);
        Assert.True(condition: File.Exists(path: made.MarksPath));

        source.Perform(request: new CommandRequest(Section: SectionId.TeamsChats, Command: TeamsCommands.MarkRead, RowId: TeamsDemoData.Sam));
        Assert.Equal(expected: 0, actual: source.Snapshot(section: SectionId.TeamsChats).Counts.NeedsYou);
        Assert.Single(collection: made.Opened);

        source.Perform(request: new CommandRequest(Section: SectionId.TeamsGroupChats, Command: TeamsCommands.MarkAllRead, GroupKey: TeamsRows.UnreadGroup));
        Assert.Equal(expected: 0, actual: source.Snapshot(section: SectionId.TeamsGroupChats).Counts.NeedsYou);

        source.Perform(request: new CommandRequest(Section: SectionId.TeamsChats, Command: TeamsCommands.OpenApp));
        Assert.Single(collection: made.AppOpens);

        // A row that's gone, a command it doesn't offer, and another source's section change nothing.
        var before = source.Snapshot(section: SectionId.TeamsChats);
        source.Perform(request: new CommandRequest(Section: SectionId.TeamsChats, Command: TeamsCommands.Open, RowId: "19:gone@thread.v2"));
        source.Perform(request: new CommandRequest(Section: SectionId.TeamsChats, Command: "unknown", RowId: TeamsDemoData.Noah));
        source.Perform(request: new CommandRequest(Section: SectionId.CopilotSessions, Command: TeamsCommands.OpenApp));
        Assert.Same(expected: before, actual: source.Snapshot(section: SectionId.TeamsChats));
        Assert.Single(collection: made.Opened);
        Assert.Single(collection: made.AppOpens);
    }

    [Fact]
    public async Task ShowsWhatItsSettingsSayAsTheyChange()
    {
        using var folder = new TemporaryFolder();
        var settings = new TeamsSettings(settings: new MemorySettings());
        var made = Make(folder: folder, settings: settings);
        using var source = made.Source;
        await Show(made: made, snapshot: TeamsDemoData.Snapshot(now: now));
        Assert.Equal(expected: "I moved the deck to the shared folder.", actual: source.Snapshot(section: SectionId.TeamsChats).Rows[0].Status);

        var changed = Waiting.NextChange(source: source);
        settings.ShowMessagePreviews = false;
        await changed.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);

        Assert.Equal(expected: "2 new messages", actual: source.Snapshot(section: SectionId.TeamsChats).Rows[0].Status);
    }

    /// What you marked read stays read after BriefBar restarts, until Teams' own marker gets there, which forgets it.
    [Fact]
    public async Task KeepsWhatYouMarkedReadUntilTeamsReadsThatFar()
    {
        using var folder = new TemporaryFolder();
        var demo = TeamsDemoData.Snapshot(now: now);
        var first = Make(folder: folder);
        using (first.Source)
        {
            await Show(made: first, snapshot: demo);
            first.Source.Perform(request: new CommandRequest(Section: SectionId.TeamsChats, Command: TeamsCommands.MarkRead, RowId: TeamsDemoData.Avery));
            await first.Source.StopAsync();
        }

        var again = Make(folder: folder);
        using var source = again.Source;
        var engine = await Show(made: again, snapshot: demo);
        Assert.Equal(expected: [TeamsDemoData.Sam], actual: Unread(source: source));

        // Read in Teams up to Avery's newest message: the mark has done its job.
        var newest = demo.Chats.Single(predicate: chat => chat.Id == TeamsDemoData.Avery).Newest!.Id;
        var readInTeams = demo with
        {
            Chats = [.. demo.Chats.Select(selector: chat => chat.Id == TeamsDemoData.Avery ? chat with { Marker = new ReadMarker(MessageId: newest) } : chat)],
        };
        var changed = Waiting.NextChange(source: source);
        engine.Publish(snapshot: readInTeams);
        await changed.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        Assert.False(condition: File.Exists(path: again.MarksPath));
        Assert.Equal(expected: [TeamsDemoData.Sam], actual: Unread(source: source));
    }

    /// Once it's stopped, what its engine still hands over changes nothing; turning it off deletes what it saved, and it
    /// saves nothing more, whatever a late click asks.
    [Fact]
    public async Task StopsAndDeletesWhatItSaved()
    {
        using var folder = new TemporaryFolder();
        var made = Make(folder: folder);
        using var source = made.Source;
        var engine = await Show(made: made, snapshot: TeamsDemoData.Snapshot(now: now));
        source.Perform(request: new CommandRequest(Section: SectionId.TeamsChats, Command: TeamsCommands.MarkRead, RowId: TeamsDemoData.Avery));
        Assert.True(condition: File.Exists(path: made.MarksPath));

        await source.StopAsync();
        Assert.Equal(expected: 1, actual: engine.Stops);
        var before = source.Snapshot(section: SectionId.TeamsChats);
        engine.Publish(snapshot: TeamsDemoData.Snapshot(now: now) with { Chats = [] });
        Assert.Same(expected: before, actual: source.Snapshot(section: SectionId.TeamsChats));

        source.DeleteSavedData();
        Assert.False(condition: Directory.Exists(path: Path.GetDirectoryName(path: made.MarksPath)));
        source.Perform(request: new CommandRequest(Section: SectionId.TeamsChats, Command: TeamsCommands.MarkRead, RowId: TeamsDemoData.Sam));
        source.PanelWillShow(section: SectionId.TeamsChats);
        Assert.False(condition: File.Exists(path: made.MarksPath));
        Assert.Equal(expected: 0, actual: engine.Refreshes);
    }

    /// Turned off without having started since BriefBar did, it still deletes what it saved, and reads nothing to do it.
    [Fact]
    public void DeletesWhatItSavedWithoutStarting()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("Teams", "read");
        new TeamsReadMarks(path: path, protector: new FakeProtector()).Mark(chat: TeamsDemoData.Avery, messageId: 1_792_317_600_000, at: now);
        var made = Make(folder: folder);
        using var source = made.Source;
        Assert.Equal(expected: path, actual: made.MarksPath);
        Assert.True(condition: File.Exists(path: path));
        Assert.Equal(expected: SectionCondition.Starting, actual: source.Snapshot(section: SectionId.TeamsGroupChats).Status.Condition);

        source.DeleteSavedData();

        Assert.False(condition: File.Exists(path: path));
        Assert.Empty(collection: made.Engines);
    }

    [Fact]
    public async Task ReadsAgainAsAPanelOpens()
    {
        using var folder = new TemporaryFolder();
        var made = Make(folder: folder);
        using var source = made.Source;
        source.PanelWillShow(section: SectionId.TeamsChats);
        var engine = await Show(made: made, snapshot: TeamsDemoData.Snapshot(now: now));
        Assert.Equal(expected: 0, actual: engine.Refreshes);

        source.PanelWillShow(section: SectionId.TeamsGroupChats);

        await Waiting.Until(condition: () => engine.Refreshes == 1);
    }

    /// Turned off while its engine's first read runs, it stops the engine only once that read has run, so the engine
    /// can't go on reading after the source is off.
    [Fact]
    public async Task StopsItsEngineOnlyOnceItHasStarted()
    {
        using var folder = new TemporaryFolder();
        using var holdStart = new ManualResetEventSlim(initialState: false);
        var made = Make(folder: folder, holdStart: holdStart);
        using var source = made.Source;
        await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        var engine = Assert.Single(collection: made.Engines);
        await Waiting.Until(condition: () => engine.EnteredStart);

        var stopping = source.StopAsync();
        // Time enough for a stop that doesn't wait to have run.
        await Task.Delay(millisecondsDelay: 200, cancellationToken: TestContext.Current.CancellationToken);
        Assert.False(condition: stopping.IsCompleted);
        Assert.Empty(collection: engine.Calls);

        holdStart.Set();
        await stopping.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: ["start", "stop"], actual: engine.Calls);
    }

    /// Turned off before its engine's first read began, as while it reads the chats you marked read, it never lets the
    /// engine read: it only stops it.
    [Fact]
    public async Task NeverStartsAnEngineItWasStoppedBefore()
    {
        using var folder = new TemporaryFolder();
        using var holdMarks = new ManualResetEventSlim(initialState: false);
        var made = Make(folder: folder, holdMarks: holdMarks);
        using var source = made.Source;
        await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        var engine = Assert.Single(collection: made.Engines);

        var stopping = source.StopAsync();
        holdMarks.Set();
        await stopping.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);

        Assert.Equal(expected: ["stop"], actual: engine.Calls);
        Assert.Equal(expected: SectionCondition.Starting, actual: source.Snapshot(section: SectionId.TeamsChats).Status.Condition);
    }

    [Fact]
    public async Task SaysWhenItCantStartReading()
    {
        using var folder = new TemporaryFolder();
        var made = Make(folder: folder, failsToStart: true);
        using var source = made.Source;
        var changed = Waiting.NextChange(source: source);

        await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        await changed.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);

        var status = source.Snapshot(section: SectionId.TeamsChats).Status;
        Assert.Equal(expected: (SectionCondition.Problem, "Can't read"), actual: (status.Condition, status.ShortProblem));
        Assert.Equal(expected: status, actual: source.Snapshot(section: SectionId.TeamsGroupChats).Status);
    }

    static List<string> Unread(TeamsSource source) => source.Snapshot(section: SectionId.TeamsChats).Rows
        .Where(predicate: row => row.State == ItemState.NeedsYou)
        .Select(selector: row => row.Id)
        .ToList();

    /// Starts `made`'s source, waits for its engine to start, and hands it `snapshot`.
    static async Task<FakeTeamsEngine> Show(Made made, TeamsSnapshot snapshot)
    {
        await made.Source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        var engine = await Started(made: made);
        var changed = Waiting.NextChange(source: made.Source);
        engine.Publish(snapshot: snapshot);
        await changed.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        return engine;
    }

    /// The source's latest engine, once it has started: what it hands over before then is for a store not yet made.
    static async Task<FakeTeamsEngine> Started(Made made)
    {
        FakeTeamsEngine? engine = null;
        await Waiting.Until(condition: () =>
        {
            lock (made.Engines)
            {
                engine = made.Engines.Count > 0 ? made.Engines[^1] : null;
            }
            return engine is { Starts: > 0 };
        });
        return engine!;
    }

    static Made Make(
        TemporaryFolder folder, TeamsSettings? settings = null, ManualResetEventSlim? holdStart = null, ManualResetEventSlim? holdMarks = null, bool failsToStart = false)
    {
        var engines = new List<FakeTeamsEngine>();
        var opened = new List<Uri>();
        var appOpens = new List<bool>();
        var marksPath = folder.Combine("Teams", "read");
        var source = new TeamsSource(
            settings: settings ?? new TeamsSettings(settings: new MemorySettings()),
            makeEngine: onChange =>
            {
                var engine = new FakeTeamsEngine(onChange: onChange, failsToStart: failsToStart, holdStart: holdStart);
                lock (engines)
                {
                    engines.Add(item: engine);
                }
                return engine;
            },
            access: new TeamsAccess(OpenLink: opened.Add, OpenApp: () => appOpens.Add(item: true)),
            makeMarks: () =>
            {
                holdMarks?.Wait(timeout: Waiting.Limit);
                return new TeamsReadMarks(path: marksPath, protector: new FakeProtector());
            },
            time: new TestClock(start: now));
        return new Made(Source: source, Engines: engines, Opened: opened, AppOpens: appOpens, MarksPath: marksPath);
    }

    /// A source made for a test, and what it asked of Windows: the links it opened, and each time it opened Teams.
    sealed record Made(TeamsSource Source, List<FakeTeamsEngine> Engines, List<Uri> Opened, List<bool> AppOpens, string MarksPath);
}
