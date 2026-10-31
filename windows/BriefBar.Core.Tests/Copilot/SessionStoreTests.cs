using BriefBar.Core.Copilot;
using BriefBar.Core.Settings;

namespace BriefBar.Core.Tests.Copilot;

public sealed class SessionStoreTests
{
    static readonly DateTimeOffset now = DateTimeOffset.UtcNow;

    [Fact]
    public void ViewingOrReadingInCopilotDoesNotClearCompletions()
    {
        var settings = new CopilotSettings(settings: new MemorySettings(), now: now);
        var store = Store(settings: settings);
        var at = now.AddSeconds(seconds: -120);
        SessionRecord[] records = [Ended(id: "finished", at: at), Ended(id: "stopped", at: at, failed: true)];
        foreach (var id in new[] { "finished", "stopped" })
        {
            store.Receive(
                snapshot: new EngineSnapshot { Records = [.. records], View = new AppViewState { UnreadWorkspaceIds = new HashSet<string>(), UnreadUpdatedAt = now, ViewedSessionId = id } },
                now: now);
            Assert.Equal(expected: ["finished"], actual: Ids(store: store, phase: DisplayPhase.Done));
            Assert.Equal(expected: ["stopped"], actual: Ids(store: store, phase: DisplayPhase.Stopped));
            Assert.Equal(expected: 1, actual: store.Counts.Done);
            Assert.Equal(expected: 1, actual: store.Counts.Stopped);
            Assert.Empty(collection: settings.Cleared);
        }
    }

    [Fact]
    public void ClearPersistsOnlyTheChosenGroupAndANewRunReappears()
    {
        var saved = new MemorySettings();
        var settings = new CopilotSettings(settings: saved, now: now);
        var store = Store(settings: settings);
        var at = now.AddSeconds(seconds: -120);
        SessionRecord[] records = [Ended(id: "first", at: at), Ended(id: "second", at: at), Ended(id: "stopped", at: at, failed: true)];
        store.Receive(snapshot: new EngineSnapshot { Records = [.. records] }, now: now);
        store.Clear(phase: DisplayPhase.Done, now: now);
        Assert.Equal(expected: 0, actual: store.Counts.Done);
        Assert.Equal(expected: 1, actual: store.Counts.Stopped);
        Assert.Equal(expected: ["first", "second"], actual: settings.Cleared.Keys.Order());

        var restored = new CopilotSettings(settings: saved, now: now);
        foreach (var id in new[] { "first", "second" })
        {
            Assert.True(condition: (restored.Cleared[id] - settings.Cleared[id]).Duration() < TimeSpan.FromMilliseconds(value: 1));
        }
        var relaunched = Store(settings: restored);
        relaunched.Receive(snapshot: new EngineSnapshot { Records = [.. records] }, now: now);
        Assert.Equal(expected: 0, actual: relaunched.Counts.Done);
        Assert.Equal(expected: 1, actual: relaunched.Counts.Stopped);

        var nextEnd = restored.Cleared["first"].AddSeconds(seconds: 1);
        relaunched.Receive(snapshot: new EngineSnapshot { Records = [Ended(id: "first", at: nextEnd)] }, now: now.AddSeconds(seconds: 2));
        Assert.Equal(expected: ["first"], actual: Ids(store: relaunched, phase: DisplayPhase.Done));
        Assert.Equal(expected: nextEnd, actual: relaunched.Sessions[0].Since);
    }

    [Fact]
    public void OldAutomaticAcknowledgmentsDoNotSuppressRecentCompletions()
    {
        var saved = new MemorySettings();
        saved.SetDates(key: CopilotSettings.ViewedKey, dates: new Dictionary<string, DateTimeOffset> { ["finished"] = now });
        var settings = new CopilotSettings(settings: saved, now: now);
        var store = Store(settings: settings);
        store.Receive(snapshot: new EngineSnapshot { Records = [Ended(id: "finished", at: now.AddSeconds(seconds: -120))] }, now: now);
        Assert.Equal(expected: 1, actual: store.Counts.Done);
        Assert.Empty(collection: settings.Cleared);
        Assert.True(condition: settings.Viewed.ContainsKey(key: "finished"));
        Assert.False(condition: settings.MoveViewedToIdle);
        settings.MoveViewedToIdle = true;
        store.Receive(snapshot: new EngineSnapshot { Records = [Ended(id: "finished", at: now.AddSeconds(seconds: -120))] }, now: now);
        Assert.Equal(expected: 0, actual: store.Counts.Done);
    }

    [Fact]
    public void OpeningOnlyDismissesWhileTheOptionIsOn()
    {
        var settings = new CopilotSettings(settings: new MemorySettings(), now: now);
        var opened = new List<string>();
        var store = Store(settings: settings, openSession: opened.Add);
        SessionRecord[] records = [Ended(id: "finished", at: now.AddSeconds(seconds: -120)), Ended(id: "stopped", at: now.AddSeconds(seconds: -120), failed: true)];
        store.Receive(snapshot: new EngineSnapshot { Records = [.. records] }, now: now);
        store.Open(session: store.SessionsIn(phase: DisplayPhase.Done).First(), now: now);
        Assert.Equal(expected: 1, actual: store.Counts.Done);
        Assert.Empty(collection: settings.Viewed);
        settings.MoveViewedToIdle = true;
        store.Open(session: store.SessionsIn(phase: DisplayPhase.Done).First(), now: now);
        store.Open(session: store.SessionsIn(phase: DisplayPhase.Stopped).First(), now: now);
        Assert.Equal(expected: 0, actual: store.Counts.Done);
        Assert.Equal(expected: 0, actual: store.Counts.Stopped);
        Assert.Equal(expected: ["finished", "stopped"], actual: settings.Viewed.Keys.Order());
        Assert.Empty(collection: settings.Cleared);
        Assert.Equal(expected: ["finished", "finished", "stopped"], actual: opened);

        settings.MoveViewedToIdle = false;
        store.Receive(snapshot: new EngineSnapshot { Records = [.. records] }, now: now);
        Assert.Equal(expected: 1, actual: store.Counts.Done);
        Assert.Equal(expected: 1, actual: store.Counts.Stopped);
        store.Clear(phase: DisplayPhase.Done, now: now);
        store.Receive(snapshot: new EngineSnapshot { Records = [.. records] }, now: now);
        Assert.Equal(expected: 0, actual: store.Counts.Done);
    }

    /// With the Copilot app on this PC, sessions open in it; without it, they'd open with the Copilot CLI, which isn't on
    /// Windows yet, so nothing opens. It's looked at again on each click, in case you installed or removed the app since.
    [Fact]
    public void OpensInTheAppWhenItsInstalledAndOtherwiseOnlyWhereThatsPorted()
    {
        var installed = true;
        var inApp = new List<string>();
        var withCLI = new List<string>();
        var settings = new CopilotSettings(settings: new MemorySettings(), now: now);
        var store = new SessionStore(settings: settings, openSession: inApp.Add, isAppInstalled: () => installed, isAppFrontmost: () => false);
        store.Receive(snapshot: new EngineSnapshot { Records = [Ended(id: "finished", at: now.AddSeconds(seconds: -120))] }, now: now);
        var session = store.Sessions[0];
        Assert.True(condition: store.AppInstalled);
        Assert.True(condition: store.CanOpen);
        store.Open(session: session, now: now);
        Assert.Equal(expected: ["finished"], actual: inApp);

        installed = false;
        store.Open(session: session, now: now);
        Assert.False(condition: store.AppInstalled);
        Assert.False(condition: store.CanOpen);
        Assert.Equal(expected: ["finished"], actual: inApp);

        var withTerminal = new SessionStore(settings: settings, openSession: inApp.Add, isAppInstalled: () => false, isAppFrontmost: () => false, openCLISession: withCLI.Add);
        withTerminal.Receive(snapshot: new EngineSnapshot { Records = [Ended(id: "finished", at: now.AddSeconds(seconds: -120))] }, now: now);
        Assert.True(condition: withTerminal.CanOpen);
        withTerminal.Open(session: withTerminal.Sessions[0], now: now);
        Assert.Equal(expected: ["finished"], actual: withCLI);
    }

    /// A PC with only the Copilot CLI has no app database, which is no problem there. With the app, it's one; and a
    /// database that's there but can't be read is one either way.
    [Fact]
    public void SaysNothingOfAMissingDatabaseOnlyWithoutTheApp()
    {
        var missing = new EngineSnapshot { Problem = "Could not open Copilot database: unable to open database file", ListedByApp = false, DatabaseMissing = true };
        var settings = new CopilotSettings(settings: new MemorySettings(), now: now);
        var cliOnly = new SessionStore(settings: settings, openSession: _ => { }, isAppInstalled: () => false, isAppFrontmost: () => false);
        cliOnly.Receive(snapshot: missing, now: now);
        Assert.Null(@object: cliOnly.Problem);

        var withApp = new SessionStore(settings: settings, openSession: _ => { }, isAppInstalled: () => true, isAppFrontmost: () => false);
        withApp.Receive(snapshot: missing, now: now);
        Assert.Equal(expected: missing.Problem, actual: withApp.Problem);

        cliOnly.Receive(snapshot: missing with { DatabaseMissing = false }, now: now);
        Assert.Equal(expected: missing.Problem, actual: cliOnly.Problem);
    }

    /// A session's question, which the session coordinating it asks you for it: with Show relayed questions once, once,
    /// where you answer it; without it, as before.
    [Fact]
    public void ARelayedQuestionShowsOnceOnlyWhenTurnedOn()
    {
        var at = now.AddSeconds(seconds: -60);
        var child = new SessionLogState();
        child.Apply(logEvent: new LogEvent(Timestamp: at, Kind: LogEventKind.UserMessage));
        child.Apply(logEvent: new LogEvent(Timestamp: at.AddSeconds(seconds: 1), Kind: LogEventKind.ToolStarted(tool: new ToolStart { CallId = "q", Name = "ask_user", Question = "Which color?" })));
        var coordinator = new SessionLogState();
        coordinator.Apply(logEvent: new LogEvent(Timestamp: at, Kind: LogEventKind.UserMessage));
        coordinator.Apply(logEvent: new LogEvent(Timestamp: at.AddSeconds(seconds: 2), Kind: LogEventKind.ToolStarted(tool: new ToolStart { CallId = "r", Name = "relay_session_input", RelayedSession = "w-child" })));
        var state = new EngineSnapshot
        {
            Records =
            [
                new SessionRecord(Meta: new SessionMeta { Id = "child", Name = "Pick colors", IsRunning = true, WorkspaceId = "w-child" }, Log: child),
                new SessionRecord(Meta: new SessionMeta { Id = "coordinator", Name = "Release 2.5", IsRunning = true }, Log: coordinator),
            ],
        };

        var settings = new CopilotSettings(settings: new MemorySettings(), now: now);
        var opened = new List<string>();
        var store = Store(settings: settings, openSession: opened.Add);
        store.Receive(snapshot: state, now: now);
        Assert.False(condition: settings.ShowRelayedQuestionsOnce);
        Assert.Equal(expected: ["child"], actual: Ids(store: store, phase: DisplayPhase.NeedsYou));
        Assert.Equal(expected: ["coordinator"], actual: Ids(store: store, phase: DisplayPhase.Running));
        Assert.All(collection: store.Sessions, action: session => Assert.True(condition: session.AnswerIn is null && session.AsksFor.Count == 0));

        settings.ShowRelayedQuestionsOnce = true;
        store.Receive(snapshot: state, now: now);
        Assert.Equal(expected: 1, actual: store.Counts.NeedsYou);
        Assert.Equal(expected: 1, actual: store.Counts.Running);
        var asking = store.SessionsIn(phase: DisplayPhase.NeedsYou).Single();
        Assert.Equal(expected: "coordinator", actual: asking.Id);
        Assert.Equal(expected: "Which color?", actual: asking.Detail);
        var waiting = store.SessionsIn(phase: DisplayPhase.Running).Single();
        Assert.Equal(expected: "Answer in “Release 2.5”", actual: waiting.Headline);

        store.Open(session: waiting, now: now);
        store.Open(session: asking, now: now);
        store.OpenItself(session: waiting);
        Assert.Equal(expected: ["coordinator", "coordinator", "child"], actual: opened);
    }

    [Fact]
    public void ShowingRelayedQuestionsOnceIsOptInAndPersists()
    {
        var saved = new MemorySettings();
        Assert.False(condition: new CopilotSettings(settings: saved, now: now).ShowRelayedQuestionsOnce);
        _ = new CopilotSettings(settings: saved, now: now) { ShowRelayedQuestionsOnce = true };
        Assert.True(condition: new CopilotSettings(settings: saved, now: now).ShowRelayedQuestionsOnce);
    }

    /// Sessions under the sessions that started them, in their own groups, only with Nest sessions under their parents
    /// on; counts stay the same.
    [Fact]
    public void NestsSessionsUnderTheirParentsOnlyWhenTurnedOn()
    {
        SessionRecord Running(string id, string name, double since, string? parent = null) => new(
            Meta: new SessionMeta { Id = id, Name = name, IsRunning = true, UpdatedAt = now.AddSeconds(seconds: -since), ParentSessionId = parent },
            Log: null);
        var notes = Ended(id: "notes", at: now.AddSeconds(seconds: -120));
        notes = notes with { Meta = notes.Meta with { ParentSessionId = "lead" } };
        var state = new EngineSnapshot
        {
            Records = [Running(id: "lead", name: "Release 2.5", since: 60), Running(id: "other", name: "Fix the build", since: 30), Running(id: "child", name: "Pick colors", since: 10, parent: "lead"), notes],
        };

        var settings = new CopilotSettings(settings: new MemorySettings(), now: now);
        var opened = new List<string>();
        var store = Store(settings: settings, openSession: opened.Add);
        store.Receive(snapshot: state, now: now);
        Assert.False(condition: settings.NestSessions);
        Assert.Equal(expected: ["child", "other", "lead", "notes"], actual: store.Sessions.Select(selector: session => session.Id));
        Assert.All(collection: store.Sessions, action: session => Assert.True(condition: session.Parent is null && session.Depth == 0));
        var counts = store.Counts;

        settings.NestSessions = true;
        store.Receive(snapshot: state, now: now);
        Assert.Equal(expected: ["lead", "child", "other", "notes"], actual: store.Sessions.Select(selector: session => session.Id));
        Assert.Equal(expected: [0, 1, 0, 0], actual: store.Sessions.Select(selector: session => session.Depth));
        Assert.Equal(expected: counts, actual: store.Counts);
        // Finished, it's in another group than the session that started it, which its tag opens.
        var finished = store.SessionsIn(phase: DisplayPhase.Done).Single();
        Assert.Equal(expected: new RelatedSession(Id: "lead", Name: "Release 2.5"), actual: finished.Parent);
        store.OpenParent(session: finished, now: now);
        Assert.Equal(expected: ["lead"], actual: opened);
    }

    [Fact]
    public void NestingSessionsIsOptInAndPersists()
    {
        var saved = new MemorySettings();
        Assert.False(condition: new CopilotSettings(settings: saved, now: now).NestSessions);
        _ = new CopilotSettings(settings: saved, now: now) { NestSessions = true };
        Assert.True(condition: new CopilotSettings(settings: saved, now: now).NestSessions);
    }

    [Fact]
    public void MovingViewedSessionsToIdleIsOptInAndPersists()
    {
        var saved = new MemorySettings();
        var settings = new CopilotSettings(settings: saved, now: now);
        Assert.False(condition: settings.MoveViewedToIdle);
        settings.MoveViewedToIdle = true;
        Assert.True(condition: new CopilotSettings(settings: saved, now: now).MoveViewedToIdle);
        settings.MoveViewedToIdle = false;
        Assert.False(condition: new CopilotSettings(settings: saved, now: now).MoveViewedToIdle);
    }

    /// What's saved decides, read again: how long finished sessions stay, and the ones cleared or viewed.
    [Fact]
    public void ResolvesAsTheSavedSettingsSay()
    {
        var saved = new MemorySettings();
        saved.SetNumber(key: CopilotSettings.KeepEndedMinutesKey, value: 15);
        saved.SetDates(key: CopilotSettings.ViewedKey, dates: new Dictionary<string, DateTimeOffset> { ["viewed"] = now });
        saved.SetDates(key: CopilotSettings.ClearedKey, dates: new Dictionary<string, DateTimeOffset> { ["cleared"] = now });
        var state = new EngineSnapshot
        {
            Records = [Ended(id: "viewed", at: now.AddSeconds(seconds: -120)), Ended(id: "cleared", at: now.AddSeconds(seconds: -120)), Ended(id: "expired", at: now.AddSeconds(seconds: -901))],
        };
        Dictionary<string, DisplayPhase> Phases()
        {
            var store = Store(settings: new CopilotSettings(settings: saved, now: now));
            store.Receive(snapshot: state, now: now);
            return store.Sessions.ToDictionary(keySelector: session => session.Id, elementSelector: session => session.Phase);
        }
        Assert.Equal(expected: Expected(viewed: DisplayPhase.Done), actual: Phases());
        saved.SetBool(key: CopilotSettings.MoveViewedToIdleKey, value: true);
        Assert.Equal(expected: Expected(viewed: DisplayPhase.Idle), actual: Phases());
        saved.SetBool(key: CopilotSettings.MoveViewedToIdleKey, value: false);
        Assert.Equal(expected: Expected(viewed: DisplayPhase.Done), actual: Phases());

        static Dictionary<string, DisplayPhase> Expected(DisplayPhase viewed) =>
            new() { ["viewed"] = viewed, ["cleared"] = DisplayPhase.Idle, ["expired"] = DisplayPhase.Idle };
    }

    [Fact]
    public void RetentionStillExpiresAndTurningOffForgetsClears()
    {
        var saved = new MemorySettings();
        var settings = new CopilotSettings(settings: saved, now: now) { KeepEndedMinutes = 15 };
        var store = Store(settings: settings);
        store.Receive(snapshot: new EngineSnapshot { Records = [Ended(id: "recent", at: now.AddSeconds(seconds: -120)), Ended(id: "expired", at: now.AddSeconds(seconds: -901))] }, now: now);
        Assert.Equal(expected: ["recent"], actual: Ids(store: store, phase: DisplayPhase.Done));
        Assert.Equal(expected: ["expired"], actual: Ids(store: store, phase: DisplayPhase.Idle));
        store.Clear(phase: DisplayPhase.Done, now: now);
        Assert.NotEmpty(collection: settings.Cleared);
        settings.MarkViewed(ids: ["expired"], date: now);
        settings.ForgetDismissed();
        Assert.Empty(collection: settings.Cleared);
        Assert.Empty(collection: settings.Viewed);
        Assert.Null(@object: saved.Read(key: CopilotSettings.ClearedKey));
        Assert.Null(@object: saved.Read(key: CopilotSettings.ViewedKey));
        // Its settings stay.
        Assert.Equal(expected: 15, actual: new CopilotSettings(settings: saved, now: now).KeepEndedMinutes);
    }

    /// With Move viewed sessions to idle, a finished session the Copilot app shows while it's in front is viewed, as on
    /// the Mac; not while another app is in front.
    [Fact]
    public void ASessionTheAppShowsInFrontIsViewed()
    {
        var settings = new CopilotSettings(settings: new MemorySettings(), now: now) { MoveViewedToIdle = true };
        var frontmost = false;
        var store = new SessionStore(settings: settings, openSession: _ => { }, isAppInstalled: () => true, isAppFrontmost: () => frontmost);
        var state = new EngineSnapshot
        {
            Records = [Ended(id: "finished", at: now.AddSeconds(seconds: -120))],
            View = new AppViewState { ViewedSessionId = "finished" },
        };
        store.Receive(snapshot: state, now: now);
        Assert.Equal(expected: 1, actual: store.Counts.Done);
        Assert.Empty(collection: settings.Viewed);

        frontmost = true;
        store.Receive(snapshot: state, now: now);
        Assert.Equal(expected: 0, actual: store.Counts.Done);
        Assert.Equal(expected: ["finished"], actual: settings.Viewed.Keys);
    }

    static SessionRecord Ended(string id, DateTimeOffset at, bool failed = false)
    {
        var log = new SessionLogState();
        log.Apply(logEvent: new LogEvent(Timestamp: at.AddSeconds(seconds: -30), Kind: LogEventKind.UserMessage));
        log.Apply(logEvent: new LogEvent(Timestamp: at, Kind: failed ? LogEventKind.SessionError(errorType: null, message: "Failed") : LogEventKind.AgentStop(isSubagent: false)));
        return new SessionRecord(Meta: new SessionMeta { Id = id, Name = id, WorkspaceId = id }, Log: log);
    }

    static SessionStore Store(CopilotSettings settings, Action<string>? openSession = null) =>
        new(settings: settings, openSession: openSession ?? (_ => { }), isAppInstalled: () => true, isAppFrontmost: () => false);

    static List<string> Ids(SessionStore store, DisplayPhase phase) => store.SessionsIn(phase: phase).Select(selector: session => session.Id).ToList();
}
