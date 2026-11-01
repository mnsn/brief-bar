using BriefBar.Core.Logging;
using BriefBar.Core.Presentation;

namespace BriefBar.Core.Copilot;

/// What every GitHub Copilot app session is doing: which are running, which need you, and which have finished or
/// stopped. It reads the Copilot app's own files, read-only, and needs no permission. The Mac's `CopilotSource`.
///
/// Its engine reads on the thread pool; it resolves what it read under its own lock, on whichever thread that happens,
/// and says so with `Changed`. Times move on: every 15 seconds it resolves again, as finished sessions go idle.
public sealed class CopilotSource : ISectionSource, IDisposable
{
    /// What it reads. Raise `Version` when it reads more, so that a source you turned on waits until you've seen what.
    public static SourceDescription Description { get; } = new(
        Version: 1,
        Summary: "What each GitHub Copilot app session is doing, and which ones need you",
        Reads: "The GitHub Copilot app's own files in the .copilot folder of your user folder, read-only: its database of "
            + "sessions, and each session's event log. BriefBar never changes them. It keeps only which finished sessions "
            + "you've cleared or, with Move viewed sessions to idle on, viewed, in its own settings.",
        Network: "None. Copilot's list makes no network requests.",
        Needs: "Nothing: Windows doesn't protect these files.");

    static readonly TimeSpan tickInterval = TimeSpan.FromSeconds(value: 15);

    readonly Lock gate = new();
    readonly CopilotSettings settings;
    readonly SessionStore store;
    readonly Func<Action<EngineSnapshot>, ISessionEngine> makeEngine;
    readonly CopilotAppAccess app;
    readonly TimeProvider time;
    ISessionEngine? engine;
    /// Its engine's start, on the thread pool, which stopping waits for, so that a start still waiting to run can't
    /// begin reading once the source is off.
    Task? engineStart;
    ITimer? ticker;
    /// Which start the engine belongs to, so that a stopped engine's late snapshot changes nothing.
    int generation;
    /// Turned off: what it saved is deleted, and it saves nothing more, even before it has stopped.
    bool turnedOff;
    SectionSnapshot snapshot = SectionSnapshot.Starting(info: BriefBar.Core.Sections.CopilotSessions);
    SectionCondition? loggedCondition;

    /// - `makeEngine`: the engine that reads the sessions, made with the handler for what it reads: `SessionEngine` on
    ///   the Copilot folder, or made-up sessions for the demo.
    /// - `app`: what Windows does with the Copilot app for it.
    public CopilotSource(
        CopilotSettings settings, Func<Action<EngineSnapshot>, ISessionEngine> makeEngine, CopilotAppAccess app, TimeProvider? time = null)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        ArgumentNullException.ThrowIfNull(argument: makeEngine);
        ArgumentNullException.ThrowIfNull(argument: app);
        this.settings = settings;
        this.makeEngine = makeEngine;
        this.app = app;
        this.time = time ?? TimeProvider.System;
        store = new SessionStore(
            settings: settings, openSession: app.OpenSession, isAppInstalled: app.IsInstalled, isAppFrontmost: app.IsFrontmost);
    }

    public event EventHandler? Changed;

    public SourceId Source => SourceId.Copilot;

    public IReadOnlyList<SectionInfo> Sections { get; } = [BriefBar.Core.Sections.CopilotSessions];

    public Task StartAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Task started;
        lock (gate)
        {
            if (engine is not null)
            {
                return Task.CompletedTask;
            }
            var current = ++generation;
            var starting = engine = makeEngine(arg: state => Receive(state: state, fromGeneration: current));
            ticker = time.CreateTimer(callback: _ => Tick(), state: null, dueTime: tickInterval, period: tickInterval);
            settings.Changed += SettingsChanged;
            // Its first read is on the thread pool, so that starting doesn't wait for it.
            started = engineStart = Task.Run(action: starting.Start, cancellationToken: CancellationToken.None);
        }
        Log.Write(line: $"copilot: starting");
        _ = started.ContinueWith(
            continuationAction: failed => StartFailed(error: failed.Exception!),
            cancellationToken: CancellationToken.None,
            continuationOptions: TaskContinuationOptions.OnlyOnFaulted,
            scheduler: TaskScheduler.Default);
        return Task.CompletedTask;
    }

    public Task StopAsync()
    {
        ISessionEngine? stopping;
        Task? started;
        ITimer? timer;
        lock (gate)
        {
            generation++;
            stopping = engine;
            started = engineStart;
            engine = null;
            engineStart = null;
            timer = ticker;
            ticker = null;
            settings.Changed -= SettingsChanged;
        }
        timer?.Dispose();
        // Outside the lock: the engine may be handing over a snapshot, which takes it.
        return stopping is null ? Task.CompletedTask : StopAfterStartAsync(stopping: stopping, started: started);
    }

    /// Forgets the sessions you cleared or viewed, as turning Copilot off does, and saves nothing from then on, even if its
    /// stop, on the thread pool, hasn't begun. Its settings stay.
    public void DeleteSavedData()
    {
        lock (gate)
        {
            // Once any resolve that's saving has finished: nothing after it saves, and a snapshot its engine hands over
            // from now on changes nothing.
            turnedOff = true;
            generation++;
        }
        settings.ForgetDismissed();
    }

    public SectionSnapshot Snapshot(SectionId section) =>
        section == SectionId.CopilotSessions
            ? Volatile.Read(location: ref snapshot)
            : throw new ArgumentException(message: "Not one of this source's sections.", paramName: nameof(section));

    public void Perform(CommandRequest request)
    {
        ArgumentNullException.ThrowIfNull(argument: request);
        if (request.Section != SectionId.CopilotSessions)
        {
            return;
        }
        if (request.Command == CopilotCommands.OpenApp && request.RowId is null)
        {
            app.Activate();
            return;
        }
        lock (gate)
        {
            if (engine is null || turnedOff)
            {
                // Stopped, not started, or turned off: it saves nothing, so what it saved stays deleted once it's off.
                return;
            }
            var now = time.GetUtcNow();
            var session = request.RowId is { } id ? store.Sessions.FirstOrDefault(predicate: listed => listed.Id == id) : null;
            switch (request.Command)
            {
                case CopilotCommands.Open when session is not null:
                    store.Open(session: session, now: now);
                    break;
                case CopilotCommands.OpenItself when session is not null:
                    store.OpenItself(session: session);
                    break;
                case CopilotCommands.OpenParent when session is not null:
                    store.OpenParent(session: session, now: now);
                    break;
                case CopilotCommands.Clear when request.GroupKey is { } key && CopilotRows.Phase(groupKey: key) is DisplayPhase.Done or DisplayPhase.Stopped:
                    store.Clear(phase: CopilotRows.Phase(groupKey: key)!.Value, now: now);
                    break;
                default:
                    // A row that's gone, or a command it doesn't offer.
                    return;
            }
            Rebuild();
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }

    /// Stops it as `StopAsync` does, without waiting: an engine still starting stops once it has started.
    public void Dispose() => _ = StopAsync();

    /// Stops `stopping` once its start has run, however that went: started on the thread pool, it could otherwise begin
    /// reading after it was told to stop. A start that failed has said so already (`StartFailed`); stopping it still
    /// gives back whatever it holds. On the thread pool, since the engine's lock may be held by a read.
    static async Task StopAfterStartAsync(ISessionEngine stopping, Task? started)
    {
        if (started is not null)
        {
            await started.ConfigureAwait(options: ConfigureAwaitOptions.SuppressThrowing);
        }
        await Task.Run(action: stopping.Stop).ConfigureAwait(continueOnCapturedContext: false);
    }

    void Receive(EngineSnapshot state, int fromGeneration)
    {
        lock (gate)
        {
            if (fromGeneration != generation)
            {
                return;
            }
            store.Receive(snapshot: state, now: time.GetUtcNow());
            Rebuild();
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }

    void Tick()
    {
        bool changed;
        lock (gate)
        {
            if (engine is null || turnedOff || !store.HasLoaded)
            {
                return;
            }
            var before = store.Sessions;
            var wasInstalled = store.AppInstalled;
            store.RefreshAppInstalled();
            store.Recompute(now: time.GetUtcNow());
            changed = !store.Sessions.SequenceEqual(second: before) || store.AppInstalled != wasInstalled;
            if (changed)
            {
                Rebuild();
            }
        }
        if (changed)
        {
            Changed?.Invoke(sender: this, e: EventArgs.Empty);
        }
    }

    /// A setting changed, maybe from within a resolve that marked a session viewed: it's resolved again, after that.
    void SettingsChanged(object? sender, EventArgs e) => _ = Task.Run(action: () =>
    {
        lock (gate)
        {
            if (engine is null || turnedOff || !store.HasLoaded)
            {
                return;
            }
            store.Recompute(now: time.GetUtcNow());
            Rebuild();
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    });

    /// What the section shows now, from the store; logged when how it stands changes, in counts.
    void Rebuild()
    {
        var built = CopilotRows.Snapshot(store: store, settings: settings);
        Volatile.Write(location: ref snapshot, value: built);
        var condition = built.Status.Condition;
        if (condition != loggedCondition)
        {
            loggedCondition = condition;
            var counts = store.Counts;
            Log.Write(line: $"copilot: {condition}, {store.Sessions.Count} sessions, listed by the app {store.State.ListedByApp}: {counts.NeedsYou} need you, {counts.Running} running, {counts.Done} done, {counts.Stopped} stopped, {counts.Idle} idle");
        }
    }

    /// Reading failed in a way BriefBar doesn't expect: the section says so, rather than starting forever.
    void StartFailed(AggregateException error)
    {
        Log.Write(error: error.GetBaseException(), context: $"copilot: couldn't start reading");
        lock (gate)
        {
            Volatile.Write(location: ref snapshot, value: SectionSnapshot.Starting(info: BriefBar.Core.Sections.CopilotSessions) with
            {
                Status = new SectionStatus(
                    Condition: SectionCondition.Problem, Problem: CopilotApp.UnexpectedProblem, ShortProblem: "Can't read"),
            });
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }
}
