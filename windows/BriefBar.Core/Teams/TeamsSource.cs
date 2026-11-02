using BriefBar.Core.Logging;
using BriefBar.Core.Presentation;

namespace BriefBar.Core.Teams;

/// Your unread Microsoft Teams chats, from Teams' own data on this PC: 1:1 chats and group chats, each a section of its
/// own. The Mac's `TeamsSource`, which reads the notifications Teams posts instead: on Windows, new Teams shows its own by
/// default, and posts none that Windows keeps.
///
/// Its engine reads on the thread pool; it decides what's unread under its own lock, on whichever thread that happens,
/// and says so with `Changed`. Times move on: every 15 seconds it decides again, as Keep Unread For and Recent pass.
public sealed class TeamsSource : ISectionSource, IDisposable
{
    /// What it reads. Raise `Version` when it reads more, so that a source you turned on waits until you've seen what.
    public static SourceDescription Description { get; } = new(
        Version: 1,
        Summary: "Your unread Teams chats: 1:1 chats, and group and meeting chats",
        Reads: "Teams' own data on this PC, read-only, from the new Teams app's web storage: each chat's title and kind, "
            + "its newest message and who sent it, and how far you've read it in Teams; and, for chats with unread "
            + "messages, their messages, from Teams' message cache. BriefBar keeps them in memory only, and never changes "
            + "Teams' data. When you mark a chat read in BriefBar, it keeps the chat's ID and the ID of the message you read "
            + "it to, encrypted for your Windows account, until you've read that far in Teams. This differs from BriefBar "
            + "for Mac, which reads the notifications Teams posts: new Teams on Windows shows its own notifications, which "
            + "Windows doesn't keep.",
        Network: "None. Nothing about your chats leaves your PC.",
        Needs: "The new Teams app, signed in on this PC. BriefBar needs no permission to read its data, as Windows lets "
            + "the programs you run read each other's.");

    static readonly TimeSpan tickInterval = TimeSpan.FromSeconds(value: 15);

    readonly Lock gate = new();
    readonly TeamsSettings settings;
    readonly Func<Action<TeamsSnapshot>, ITeamsEngine> makeEngine;
    readonly TeamsAccess access;
    readonly Func<TeamsReadMarks> makeMarks;
    readonly TimeProvider time;
    ITeamsEngine? engine;
    /// Its engine's start, on the thread pool, which stopping waits for, so that a start still waiting to run can't begin
    /// reading once the source is off.
    Task? engineStart;
    ITimer? ticker;
    /// Which start the engine belongs to, so that a stopped engine's late snapshot changes nothing.
    int generation;
    /// Turned off: what it saved is deleted, and it saves nothing more, even before it has stopped.
    bool turnedOff;
    /// Made as it starts, never while it's off: making one reads the chats you marked read.
    TeamsStore? store;
    SectionSnapshot chats = SectionSnapshot.Starting(info: BriefBar.Core.Sections.TeamsChats);
    SectionSnapshot groups = SectionSnapshot.Starting(info: BriefBar.Core.Sections.TeamsGroupChats);
    string? loggedState;

    /// - `makeEngine`: the engine that reads Teams' data, made with the handler for what it reads: `TeamsEngine` on Teams'
    ///   folder, or made-up chats for the demo.
    /// - `access`: what Windows does with Teams for it.
    /// - `makeMarks`: where the chats you mark read are kept, sealed.
    public TeamsSource(
        TeamsSettings settings,
        Func<Action<TeamsSnapshot>, ITeamsEngine> makeEngine,
        TeamsAccess access,
        Func<TeamsReadMarks> makeMarks,
        TimeProvider? time = null)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        ArgumentNullException.ThrowIfNull(argument: makeEngine);
        ArgumentNullException.ThrowIfNull(argument: access);
        ArgumentNullException.ThrowIfNull(argument: makeMarks);
        this.settings = settings;
        this.makeEngine = makeEngine;
        this.access = access;
        this.makeMarks = makeMarks;
        this.time = time ?? TimeProvider.System;
    }

    public event EventHandler? Changed;

    public SourceId Source => SourceId.Teams;

    public IReadOnlyList<SectionInfo> Sections { get; } = [BriefBar.Core.Sections.TeamsChats, BriefBar.Core.Sections.TeamsGroupChats];

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
            var starting = engine = makeEngine(arg: snapshot => Receive(snapshot: snapshot, fromGeneration: current));
            ticker = time.CreateTimer(callback: _ => Tick(), state: null, dueTime: tickInterval, period: tickInterval);
            settings.Changed += SettingsChanged;
            // Reading the chats you marked read, then Teams' data, is on the thread pool, so that starting doesn't wait.
            started = engineStart = Task.Run(action: () => LoadAndStart(engine: starting, fromGeneration: current), cancellationToken: CancellationToken.None);
        }
        Log.Write(line: $"teams: starting");
        _ = started.ContinueWith(
            continuationAction: failed => StartFailed(error: failed.Exception!),
            cancellationToken: CancellationToken.None,
            continuationOptions: TaskContinuationOptions.OnlyOnFaulted,
            scheduler: TaskScheduler.Default);
        return Task.CompletedTask;
    }

    public Task StopAsync()
    {
        ITeamsEngine? stopping;
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

    /// Deletes the chats you marked read, as turning Teams off does, and saves nothing from then on, even if its stop, on
    /// the thread pool, hasn't begun. Its settings stay. It reads nothing to do it, and nothing of Teams' own.
    public void DeleteSavedData()
    {
        lock (gate)
        {
            turnedOff = true;
            generation++;
            store = null;
            // A source that never started has no marks of its own: one made now reads nothing, and deletes the file.
            makeMarks().Delete();
        }
    }

    public SectionSnapshot Snapshot(SectionId section) => section switch
    {
        _ when section == SectionId.TeamsChats => Volatile.Read(location: ref chats),
        _ when section == SectionId.TeamsGroupChats => Volatile.Read(location: ref groups),
        _ => throw new ArgumentException(message: "Not one of this source's sections.", paramName: nameof(section)),
    };

    public void Perform(CommandRequest request)
    {
        ArgumentNullException.ThrowIfNull(argument: request);
        if (request.Section != SectionId.TeamsChats && request.Section != SectionId.TeamsGroupChats)
        {
            return;
        }
        if (request.Command == TeamsCommands.OpenApp && request.RowId is null)
        {
            access.OpenApp();
            return;
        }
        Uri? opening = null;
        lock (gate)
        {
            if (engine is null || turnedOff || store is null)
            {
                // Stopped, not started, or turned off: it saves nothing, so what it saved stays deleted once it's off.
                return;
            }
            var now = time.GetUtcNow();
            var conversation = request.RowId is { } id ? store.Find(id: id) : null;
            switch (request.Command)
            {
                case TeamsCommands.Open when conversation is not null:
                    opening = conversation.Link;
                    store.MarkRead(conversation: conversation, now: now);
                    break;
                case TeamsCommands.MarkRead when conversation is { IsUnread: true }:
                    store.MarkRead(conversation: conversation, now: now);
                    break;
                case TeamsCommands.MarkAllRead when request.GroupKey == TeamsRows.UnreadGroup:
                    store.MarkAllRead(group: request.Section == SectionId.TeamsChats ? ChatGroup.Chats : ChatGroup.Groups, now: now);
                    break;
                default:
                    // A row that's gone, or a command it doesn't offer.
                    return;
            }
            Rebuild();
        }
        if (opening is not null)
        {
            access.OpenLink(obj: opening);
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }

    /// A panel is about to show one of its sections: it reads what Teams wrote since, on the thread pool, as the Mac
    /// reads Notification Center again.
    public void PanelWillShow(SectionId section)
    {
        ITeamsEngine? running;
        lock (gate)
        {
            running = turnedOff ? null : engine;
        }
        if (running is not null)
        {
            _ = Task.Run(action: running.Refresh);
        }
    }

    /// Stops it as `StopAsync` does, without waiting: an engine still starting stops once it has started.
    public void Dispose() => _ = StopAsync();

    /// Stops `stopping` once its start has run, however that went: started on the thread pool, it could otherwise begin
    /// reading after it was told to stop. On the thread pool, since the engine's lock may be held by a read.
    static async Task StopAfterStartAsync(ITeamsEngine stopping, Task? started)
    {
        if (started is not null)
        {
            await started.ConfigureAwait(options: ConfigureAwaitOptions.SuppressThrowing);
        }
        await Task.Run(action: stopping.Stop).ConfigureAwait(continueOnCapturedContext: false);
    }

    /// Reads the chats you marked read, then starts reading Teams' data, unless it was turned off or stopped meanwhile.
    void LoadAndStart(ITeamsEngine engine, int fromGeneration)
    {
        var marks = makeMarks();
        marks.Load();
        lock (gate)
        {
            if (fromGeneration != generation || turnedOff)
            {
                return;
            }
            store = new TeamsStore(settings: settings, marks: marks);
        }
        engine.Start();
    }

    void Receive(TeamsSnapshot snapshot, int fromGeneration)
    {
        lock (gate)
        {
            if (fromGeneration != generation || store is null)
            {
                return;
            }
            store.Receive(snapshot: snapshot, now: time.GetUtcNow());
            Rebuild();
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }

    void Tick()
    {
        bool changed;
        lock (gate)
        {
            if (engine is null || turnedOff || store is not { HasLoaded: true })
            {
                return;
            }
            var before = Shape();
            store.Recompute(now: time.GetUtcNow());
            changed = !Shape().SequenceEqual(second: before);
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

    /// A setting changed: what's unread, and what rows say, are decided again.
    void SettingsChanged(object? sender, EventArgs e) => _ = Task.Run(action: () =>
    {
        lock (gate)
        {
            if (engine is null || turnedOff || store is not { HasLoaded: true })
            {
                return;
            }
            store.Recompute(now: time.GetUtcNow());
            Rebuild();
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    });

    /// Which chats each list has, and how many unread messages each: what a tick may change.
    List<(string Id, int Unread)> Shape() => Enum.GetValues<ChatGroup>()
        .SelectMany(selector: group => store!.Unread(group: group).Concat(second: store.Recent(group: group)))
        .Select(selector: conversation => (conversation.Id, conversation.Unread.Count))
        .ToList();

    /// What the sections show now, from the store; logged when how they stand changes, in counts.
    void Rebuild()
    {
        var builtChats = TeamsRows.Snapshot(store: store!, settings: settings, group: ChatGroup.Chats);
        var builtGroups = TeamsRows.Snapshot(store: store!, settings: settings, group: ChatGroup.Groups);
        Volatile.Write(location: ref chats, value: builtChats);
        Volatile.Write(location: ref groups, value: builtGroups);
        var report = store!.Snapshot?.Report ?? new TeamsDataReport();
        var unreadChats = store.Unread(group: ChatGroup.Chats).Count;
        var unreadGroups = store.Unread(group: ChatGroup.Groups).Count;
        var recentChats = store.Recent(group: ChatGroup.Chats).Count;
        var recentGroups = store.Recent(group: ChatGroup.Groups).Count;
        var state = string.Create(
            provider: System.Globalization.CultureInfo.InvariantCulture,
            handler: $"{builtChats.Status.Condition}|{store.Problem}|{unreadChats}|{unreadGroups}|{recentChats}|{recentGroups}|{report.Chats}");
        if (state != loggedState)
        {
            loggedState = state;
            Log.Write(line: $"teams: {builtChats.Status.Condition}, problem {store.Problem}; {report.Chats} chats of {report.Conversations} conversations, {report.WithMarker} with a read marker; unread {unreadChats} chats and {unreadGroups} group chats, recent {recentChats} and {recentGroups}");
        }
    }

    /// Reading failed in a way BriefBar doesn't expect: the sections say so, rather than starting forever.
    void StartFailed(AggregateException error)
    {
        Log.Write(error: error.GetBaseException(), context: $"teams: couldn't start reading");
        lock (gate)
        {
            var status = new SectionStatus(
                Condition: SectionCondition.Problem, Problem: "BriefBar couldn't start reading Teams' data.", ShortProblem: "Can't read");
            Volatile.Write(location: ref chats, value: SectionSnapshot.Starting(info: BriefBar.Core.Sections.TeamsChats) with { Status = status });
            Volatile.Write(location: ref groups, value: SectionSnapshot.Starting(info: BriefBar.Core.Sections.TeamsGroupChats) with { Status = status });
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }
}
