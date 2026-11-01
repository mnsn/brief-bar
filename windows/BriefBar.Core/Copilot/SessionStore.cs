namespace BriefBar.Core.Copilot;

/// Turns what the engine read into the sorted, resolved session list, as Copilot's settings say, and does what the list
/// asks: open a session, clear a group. Not thread-safe: `CopilotSource` uses it under its lock. The Mac's
/// `SessionStore`, without its UI, and without the tasks BriefBar sends to Copilot, which aren't on Windows yet.
public sealed class SessionStore
{
    readonly CopilotSettings settings;
    readonly Action<string> openSession;
    readonly Action<string>? openCLISession;
    readonly Func<bool> isAppInstalled;
    readonly Func<bool> isAppFrontmost;
    EngineSnapshot state = new();

    /// - `openSession`: opens a session in the Copilot app.
    /// - `openCLISession`: opens one without the app, in a terminal with the Copilot CLI (`CLISession`), as the Mac does in
    ///   Terminal; without it, nothing opens without the app.
    /// - `isAppInstalled`: whether the Copilot app is on this PC, looked at again on each click and every so often.
    /// - `isAppFrontmost`: whether the Copilot app is the window in front, for Move Viewed Sessions to Idle.
    public SessionStore(
        CopilotSettings settings, Action<string> openSession, Func<bool> isAppInstalled, Func<bool> isAppFrontmost,
        Action<string>? openCLISession = null)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        ArgumentNullException.ThrowIfNull(argument: openSession);
        ArgumentNullException.ThrowIfNull(argument: isAppInstalled);
        ArgumentNullException.ThrowIfNull(argument: isAppFrontmost);
        this.settings = settings;
        this.openSession = openSession;
        this.openCLISession = openCLISession;
        this.isAppInstalled = isAppInstalled;
        this.isAppFrontmost = isAppFrontmost;
        AppInstalled = isAppInstalled();
    }

    public IReadOnlyList<SessionSnapshot> Sessions { get; private set; } = [];

    public PhaseCounts Counts { get; private set; }

    public string? Problem { get; private set; }

    /// It received what the engine read at least once.
    public bool HasLoaded { get; private set; }

    /// The Copilot app is on this PC. Without it, sessions are the Copilot CLI's.
    public bool AppInstalled { get; private set; }

    /// What the engine read last.
    public EngineSnapshot State => state;

    /// Where a session opens: in the app, or without it, in a terminal.
    public SessionOpening Opening => AppInstalled ? SessionOpening.App : openCLISession is not null ? SessionOpening.Terminal : SessionOpening.Nowhere;

    public IEnumerable<SessionSnapshot> SessionsIn(DisplayPhase phase) => Sessions.Where(predicate: session => session.Phase == phase);

    public void Receive(EngineSnapshot snapshot, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshot);
        state = snapshot;
        HasLoaded = true;
        UpdateProblem();
        Recompute(now: now);
    }

    /// Opens the session: in the Copilot app, or without it, in a terminal. Only Move Viewed
    /// Sessions to Idle dismisses its recent completion. A session whose question another session asks you for opens
    /// that one, where you answer it.
    public void Open(SessionSnapshot session, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: session);
        MarkViewedIfEnded(session: session, now: now);
        OpenSession(id: session.AnswerIn?.Id ?? session.Id);
    }

    /// Opens a session itself, even when its question is asked in another session.
    public void OpenItself(SessionSnapshot session)
    {
        ArgumentNullException.ThrowIfNull(argument: session);
        OpenSession(id: session.Id);
    }

    /// Opens the session that started this one, which its ↳ tag names: that session itself, even when another session
    /// asks you its question.
    public void OpenParent(SessionSnapshot session, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: session);
        if (session.Parent is not { } parent)
        {
            return;
        }
        if (Sessions.FirstOrDefault(predicate: listed => listed.Id == parent.Id) is { } listedParent)
        {
            MarkViewedIfEnded(session: listedParent, now: now);
        }
        OpenSession(id: parent.Id);
    }

    /// Moves a group's sessions to Idle: Clear, on Done and Stopped.
    public void Clear(DisplayPhase phase, DateTimeOffset now)
    {
        settings.Clear(ids: SessionsIn(phase: phase).Select(selector: session => session.Id).ToList(), date: now);
        Recompute(now: now);
    }

    /// Looks again whether the Copilot app is on this PC, since you may have installed or removed it.
    public void RefreshAppInstalled()
    {
        var installed = isAppInstalled();
        if (installed == AppInstalled)
        {
            return;
        }
        AppInstalled = installed;
        if (state.DatabaseMissing)
        {
            UpdateProblem();
        }
    }

    public void Recompute(DateTimeOffset now)
    {
        var options = settings.Options;
        var records = state.Records;
        var resolved = records.Select(selector: record => StatusResolver.Snapshot(
            record: record, now: now, options: options, view: state.View,
            clearedAt: settings.ClearedAt(id: record.Id), viewedAt: settings.ViewedAt(id: record.Id))).ToList();

        if (options.MoveViewedToIdle && state.View.ViewedSessionId is { } viewedId
            && resolved.FindIndex(match: session => session.Id == viewedId) is var index and >= 0
            && resolved[index].Phase is DisplayPhase.Done or DisplayPhase.Stopped
            && isAppFrontmost())
        {
            settings.MarkViewed(ids: [viewedId], date: now);
            resolved[index] = StatusResolver.Snapshot(
                record: records[index], now: now, options: options, view: state.View,
                clearedAt: settings.ClearedAt(id: viewedId), viewedAt: now);
        }
        if (options.ShowRelayedQuestionsOnce)
        {
            resolved = RelayedQuestions.Merge(snapshots: resolved, records: records);
        }

        var sorted = SessionOrdering.Sorted(snapshots: resolved);
        Sessions = settings.NestSessions ? SessionNesting.Nest(snapshots: sorted, records: records) : sorted;
        Counts = new PhaseCounts(snapshots: Sessions);
    }

    /// With Move Viewed Sessions to Idle, opening a finished or stopped session dismisses it.
    void MarkViewedIfEnded(SessionSnapshot session, DateTimeOffset now)
    {
        if (settings.MoveViewedToIdle && session.Phase is DisplayPhase.Done or DisplayPhase.Stopped)
        {
            settings.MarkViewed(ids: [session.Id], date: now);
            Recompute(now: now);
        }
    }

    void OpenSession(string id)
    {
        RefreshAppInstalled();
        if (AppInstalled)
        {
            openSession(obj: id);
        }
        else
        {
            openCLISession?.Invoke(obj: id);
        }
    }

    /// The engine's problem, unless it's only that there's no app database on a PC without the app.
    void UpdateProblem() => Problem = CopilotApp.Problem(state: state, isInstalled: AppInstalled);
}
