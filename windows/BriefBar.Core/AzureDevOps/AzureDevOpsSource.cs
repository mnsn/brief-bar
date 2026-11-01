using System.ComponentModel;
using System.Net.NetworkInformation;
using BriefBar.Core.Logging;
using BriefBar.Core.Presentation;

namespace BriefBar.Core.AzureDevOps;

/// Your Azure DevOps pull requests, by what they need: you, a fix, completing, or someone else. It reads Azure DevOps with
/// the Azure CLI's sign-in, with GET requests only, in the organizations you choose, which it finds for you the first time.
/// The Mac's `AzureDevOpsSource` and `PRStore`, for its pull requests' section.
///
/// Its engine reads on the thread pool; it classifies what it read under its own lock, on whichever thread that happens,
/// and says so with `Changed`. Times move on: every 15 seconds it classifies again, and looks for your organizations again
/// while it couldn't find them. It never calls its engine under its lock, as the engine hands over what it read under its
/// own.
public sealed class AzureDevOpsSource : ISectionSource, IDisposable
{
    /// What it reads. Raise `Version` when it reads more, so that a source you turned on waits until you've seen what.
    public static SourceDescription Description { get; } = new(
        Version: 1,
        Summary: "Your pull requests: which need you, which are failing and which are ready to complete",
        Reads: "Your pull requests and the ones you review, in the organizations you choose, and the ones you watch, by their "
            + "links, with their builds, policies and comment threads, from Azure DevOps; and, after you merge one, while Done "
            + "keeps it, the runs of the pipelines that build its merge and of the ones those start, unless you turn Follow "
            + "pipelines after you merge off. The first time, and when you ask, the organizations you belong to, to find the "
            + "ones where you have pull requests. BriefBar keeps which pull requests you've seen, your organizations and the "
            + "pull requests you watch, in its own settings.",
        Network: "Azure DevOps only: dev.azure.com, and app.vssps.visualstudio.com to find your organizations, with your "
            + "Azure CLI sign-in. Every request is a GET, so it never changes anything there: about 10 to 25 small requests a "
            + "minute, and a few more after you merge a pull request, while its pipelines run.",
        Needs: "The Azure CLI, signed in with az login: BriefBar gets its tokens from it, so there's no personal access token, "
            + "and keeps them in memory only. It runs the Azure CLI in the background, without a window, with fixed "
            + "arguments only.");

    /// What Sign in runs, in a console window: `az login`, which signs in through Windows or your browser, without
    /// listing your subscriptions. BriefBar picks the sign-in up within a minute.
    public static IReadOnlyList<string> SignInArguments { get; } = ["login", "--allow-no-subscriptions", "--output", "none"];

    /// Sign in runs with your own environment, as you'd run it in a terminal.
    static readonly Dictionary<string, string?> yourEnvironment = [];

    static readonly TimeSpan tickInterval = TimeSpan.FromSeconds(value: 15);

    /// As a panel shows the list, it's read again if it was read longer ago than this.
    static readonly TimeSpan staleAfter = TimeSpan.FromSeconds(value: 30);

    /// Where your pull requests are, without an organization to watch.
    static readonly Uri azureDevOps = new(uriString: "https://dev.azure.com");

    readonly Lock gate = new();
    readonly AzureDevOpsSettings settings;
    readonly AzureDevOpsReading reading;
    readonly AzureDevOpsAccess access;
    readonly IProcessRunner processes;
    readonly TimeProvider time;
    readonly PRStore store;
    IPulseEngine? engine;
    ITimer? ticker;
    /// Ends a search for your organizations under way, as the source stops.
    CancellationTokenSource? stopping;
    Task? discovery;
    /// Which start what arrives belongs to, so that a stopped engine's late snapshot, or a search that ends after the
    /// source stopped, changes nothing.
    int generation;
    /// Reading failed in a way BriefBar doesn't expect: the section says so until it's turned off.
    bool failed;
    SectionSnapshot snapshot = SectionSnapshot.Starting(info: BriefBar.Core.Sections.AzureDevOpsPullRequests);
    (SectionCondition Condition, GroupCounts Counts, PulseProblemKind? Problem)? logged;

    /// - `reading`: how it reads Azure DevOps, or the demo's made-up pull requests.
    /// - `access`: what Windows does for it.
    /// - `processes`: what starts `az login` for Sign in.
    public AzureDevOpsSource(
        AzureDevOpsSettings settings, AzureDevOpsReading reading, AzureDevOpsAccess access, IProcessRunner processes, TimeProvider? time = null)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        ArgumentNullException.ThrowIfNull(argument: reading);
        ArgumentNullException.ThrowIfNull(argument: access);
        ArgumentNullException.ThrowIfNull(argument: processes);
        this.settings = settings;
        this.reading = reading;
        this.access = access;
        this.processes = processes;
        this.time = time ?? TimeProvider.System;
        store = new PRStore(settings: settings);
    }

    public event EventHandler? Changed;

    public SourceId Source => SourceId.AzureDevOps;

    public IReadOnlyList<SectionInfo> Sections { get; } = [BriefBar.Core.Sections.AzureDevOpsPullRequests];

    /// Starts its engine, which reads at once on the thread pool, and looks for your organizations if you have none yet.
    public Task StartAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        IPulseEngine made;
        int current;
        lock (gate)
        {
            if (engine is not null)
            {
                return Task.CompletedTask;
            }
            current = ++generation;
            failed = false;
            made = engine = reading.MakeEngine(onChange: state => Receive(state: state, fromGeneration: current));
            stopping = new CancellationTokenSource();
            ticker = time.CreateTimer(callback: _ => Tick(), state: null, dueTime: tickInterval, period: tickInterval);
            settings.Changed += SettingsChanged;
        }
        Log.Write(line: $"azureDevOps: starting");
        // What you've seen counts from now, the first time; the engine reads what the settings say.
        settings.StartSeeing(now: time.GetUtcNow());
        made.SetConfiguration(newConfiguration: settings.EngineConfiguration);
        made.SetLinkedPullRequests(keys: settings.WatchedKeys);
        Task loop;
        lock (gate)
        {
            if (current != generation)
            {
                // Stopped meanwhile.
                return Task.CompletedTask;
            }
            loop = made.Start();
        }
        NetworkChange.NetworkAvailabilityChanged += NetworkAvailabilityChanged;
        _ = loop.ContinueWith(
            continuationAction: stopped => Failed(error: stopped.Exception!, fromGeneration: current),
            cancellationToken: CancellationToken.None,
            continuationOptions: TaskContinuationOptions.OnlyOnFaulted,
            scheduler: TaskScheduler.Default);
        FindOrganizations(wanted: _ => store.NeedsDiscovery);
        return Task.CompletedTask;
    }

    public Task StopAsync()
    {
        IPulseEngine? stoppingEngine;
        ITimer? timer;
        CancellationTokenSource? cancel;
        Task? finding;
        lock (gate)
        {
            generation++;
            stoppingEngine = engine;
            engine = null;
            timer = ticker;
            ticker = null;
            cancel = stopping;
            stopping = null;
            finding = discovery;
            discovery = null;
            settings.Changed -= SettingsChanged;
        }
        NetworkChange.NetworkAvailabilityChanged -= NetworkAvailabilityChanged;
        timer?.Dispose();
        cancel?.Cancel();
        // Outside the lock: the engine may be handing over a snapshot, which takes it.
        return stoppingEngine is null ? Task.CompletedTask : StopEngineAsync(stopping: stoppingEngine, finding: finding, cancel: cancel);
    }

    /// Forgets which pull requests you've seen, with every account, as turning Azure DevOps off does. Its settings stay,
    /// with your organizations and the pull requests you watch.
    public void DeleteSavedData() => settings.ForgetSeen(now: time.GetUtcNow());

    public SectionSnapshot Snapshot(SectionId section) =>
        section == SectionId.AzureDevOpsPullRequests
            ? Volatile.Read(location: ref snapshot)
            : throw new ArgumentException(message: "Not one of this source's sections.", paramName: nameof(section));

    public void Perform(CommandRequest request)
    {
        ArgumentNullException.ThrowIfNull(argument: request);
        if (request.Section != SectionId.AzureDevOpsPullRequests || !IsRunning)
        {
            // Stopped, or not started: it saves nothing, so what it saved stays deleted once it's off.
            return;
        }
        if (request.RowId is null && request.GroupKey is null && PerformForSection(command: request.Command))
        {
            return;
        }
        Uri? page = null;
        lock (gate)
        {
            var now = time.GetUtcNow();
            var item = request.RowId is { } id ? store.Items.FirstOrDefault(predicate: listed => listed.Id == id) : null;
            var group = request.GroupKey is { } key ? AzureDevOpsRows.Group(groupKey: key) : null;
            switch (request.Command)
            {
                case AzureDevOpsCommands.Open when item is not null:
                    store.MarkSeen(item: item, now: now);
                    page = item.Url;
                    break;
                case AzureDevOpsCommands.RemoveFromNeedsYou when item is { Group: PRGroup.NeedsYou }:
                    store.Dismiss(item: item, now: now);
                    break;
                case AzureDevOpsCommands.StopWatching when item is { IsWatched: true }:
                    settings.Unwatch(keys: new HashSet<PRKey> { item.Key });
                    break;
                case AzureDevOpsCommands.MarkAsSeen when group == PRGroup.NeedsYou:
                case AzureDevOpsCommands.Clear when group == PRGroup.Done:
                    store.Clear(group: group.Value, now: now);
                    break;
                default:
                    // A row that's gone, or a command it doesn't offer.
                    return;
            }
            // The panel follows at once; the settings' own change classifies again too, later (`SettingsChanged`).
            store.Recompute(now: now);
            Rebuild();
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
        if (page is not null)
        {
            access.OpenLink(obj: page);
        }
    }

    /// Reads again now if what the panel would show was read more than 30 seconds ago, as on the Mac.
    public void PanelWillShow(SectionId section)
    {
        if (section != SectionId.AzureDevOpsPullRequests)
        {
            return;
        }
        bool stale;
        lock (gate)
        {
            stale = engine is not null && (store.State.RefreshedAt is not { } refreshed || time.GetUtcNow() - refreshed > staleAfter);
        }
        if (stale)
        {
            Refresh();
        }
    }

    /// What its panel shows in Answered counts as seen once it closes.
    public void PanelVisibilityChanged(SectionId section, bool isShowing)
    {
        if (section != SectionId.AzureDevOpsPullRequests)
        {
            return;
        }
        lock (gate)
        {
            if (engine is null)
            {
                return;
            }
            if (isShowing)
            {
                store.PanelOpened(now: time.GetUtcNow());
            }
            else
            {
                store.PanelClosed();
            }
        }
    }

    /// Stops it as `StopAsync` does, without waiting, and lets go of its connection to Azure DevOps once it has stopped.
    public void Dispose() => _ = StopAsync().ContinueWith(
        continuationAction: _ => reading.Dispose(),
        cancellationToken: CancellationToken.None,
        continuationOptions: TaskContinuationOptions.ExecuteSynchronously,
        scheduler: TaskScheduler.Default);

    /// Stops `stopping`, and waits for a search for your organizations under way to end, which `cancel` asks.
    static async Task StopEngineAsync(IPulseEngine stopping, Task? finding, CancellationTokenSource? cancel)
    {
        try
        {
            await stopping.StopAsync().ConfigureAwait(continueOnCapturedContext: false);
            stopping.Dispose();
            if (finding is not null)
            {
                await finding.ConfigureAwait(options: ConfigureAwaitOptions.SuppressThrowing);
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
                return engine is not null;
            }
        }
    }

    /// Does what the section's footer or banner asked; false for a command that isn't the section's.
    bool PerformForSection(string command)
    {
        switch (command)
        {
            case AzureDevOpsCommands.OpenAzureDevOps:
                access.OpenLink(obj: settings.Organizations.Count > 0 ? ADOEndpoint.MyPullRequestsPage(organization: settings.Organizations[0]) : azureDevOps);
                return true;
            case AzureDevOpsCommands.Refresh:
                Refresh();
                return true;
            case AzureDevOpsCommands.SignIn:
                SignIn();
                return true;
            case AzureDevOpsCommands.InstallCli:
                access.OpenLink(obj: AzureDevOpsRows.InstallCliPage);
                return true;
            case AzureDevOpsCommands.FindOrganizations:
                FindOrganizations(wanted: _ => true);
                return true;
            default:
                return false;
        }
    }

    /// Reads again now, and looks for your organizations if they were never found, as when you've signed in since.
    void Refresh()
    {
        IPulseEngine? running;
        lock (gate)
        {
            running = engine;
        }
        running?.Refresh();
        FindOrganizations(wanted: _ => store.NeedsDiscovery);
    }

    /// Runs `az login` in a console window, which stays open once it's done, so you can read what it said; or, without
    /// the Azure CLI, or with one it can't start, opens the page that says how to install it.
    void SignIn()
    {
        if (reading.LocateCli() is not { } program)
        {
            access.OpenLink(obj: AzureDevOpsRows.InstallCliPage);
            return;
        }
        Log.Write(line: $"azureDevOps: signing in with az login");
        try
        {
            processes.StartInConsole(program: program, arguments: SignInArguments, workingDirectory: null, environment: yourEnvironment, keepOpen: true);
        }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException or IOException or ArgumentException)
        {
            // It was uninstalled or moved since BriefBar found it, or it's at a path that `cmd.exe` can't take, with a
            // percent sign (`ProcessRunner`): what to install comes up in its place.
            Log.Write(error: error, context: $"azureDevOps: couldn't start az login");
            access.OpenLink(obj: AzureDevOpsRows.InstallCliPage);
        }
    }

    /// Looks for your organizations, on the thread pool, if `wanted` says so now and it isn't looking already: then it
    /// watches the ones where you have pull requests, keeping those you chose. It tries again if that fails, rather than
    /// settling on none.
    void FindOrganizations(Func<DateTimeOffset, bool> wanted)
    {
        lock (gate)
        {
            var now = time.GetUtcNow();
            if (engine is null || stopping is null || !wanted(arg: now) || !store.StartDiscovery(now: now))
            {
                return;
            }
            var current = generation;
            var cancellationToken = stopping.Token;
            Rebuild();
            discovery = Task.Run(
                function: () => FindOrganizationsAsync(fromGeneration: current, cancellationToken: cancellationToken),
                cancellationToken: CancellationToken.None);
            _ = discovery.ContinueWith(
                continuationAction: search => Failed(error: search.Exception!, fromGeneration: current),
                cancellationToken: CancellationToken.None,
                continuationOptions: TaskContinuationOptions.OnlyOnFaulted,
                scheduler: TaskScheduler.Default);
        }
        Log.Write(line: $"azureDevOps: finding your organizations");
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }

    async Task FindOrganizationsAsync(int fromGeneration, CancellationToken cancellationToken)
    {
        OrganizationsFound found;
        try
        {
            found = await reading.FindOrganizationsAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        }
        catch (ADOException error)
        {
            lock (gate)
            {
                if (fromGeneration != generation)
                {
                    return;
                }
                store.DiscoveryFailed(problem: PulseProblem.From(error: error.Error, now: time.GetUtcNow()));
                Rebuild();
            }
            Log.Write(line: $"azureDevOps: couldn't find your organizations: {error.Error.Kind}");
            Changed?.Invoke(sender: this, e: EventArgs.Empty);
            return;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return;
        }
        lock (gate)
        {
            if (fromGeneration != generation)
            {
                // Turned off meanwhile: it saves nothing more.
                return;
            }
            settings.KnownOrganizations = found.All;
            // The ones you chose yourself stay too, spelled the way Azure DevOps does.
            settings.Organizations = OrganizationDiscovery.Merged(names: settings.Organizations, preferred: found.WithPullRequests);
            settings.HasDiscovered = true;
            store.DiscoveryFinished();
            store.Recompute(now: time.GetUtcNow());
            Rebuild();
        }
        Log.Write(line: $"azureDevOps: found {found.All.Count} organizations, {found.WithPullRequests.Count} with pull requests");
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }

    void Receive(PulseSnapshot state, int fromGeneration)
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

    /// Times move on: what's new, done or idle may have changed. And it looks for your organizations again, a minute
    /// after it couldn't find them.
    void Tick()
    {
        bool changed;
        lock (gate)
        {
            if (engine is null)
            {
                return;
            }
            var items = store.Items;
            var problem = store.Problem;
            store.Recompute(now: time.GetUtcNow());
            changed = !store.Items.SequenceEqual(second: items) || !Equals(objA: store.Problem, objB: problem);
            if (changed)
            {
                Rebuild();
            }
        }
        if (changed)
        {
            Changed?.Invoke(sender: this, e: EventArgs.Empty);
        }
        FindOrganizations(wanted: now => store.ShouldRetryDiscovery(now: now));
    }

    /// A setting, what you've seen, or the pull requests you watch changed, maybe as the store received a snapshot: the
    /// engine reads what the settings say now, and the pull requests are classified again, after that, on the thread pool.
    void SettingsChanged(object? sender, EventArgs e) => _ = Task.Run(action: () =>
    {
        IPulseEngine? running;
        lock (gate)
        {
            running = engine;
        }
        if (running is null)
        {
            return;
        }
        running.SetConfiguration(newConfiguration: settings.EngineConfiguration);
        running.SetLinkedPullRequests(keys: settings.WatchedKeys);
        lock (gate)
        {
            if (engine != running)
            {
                return;
            }
            store.Recompute(now: time.GetUtcNow());
            Rebuild();
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    });

    /// Back online: it reads again at once.
    void NetworkAvailabilityChanged(object? sender, NetworkAvailabilityEventArgs e)
    {
        if (e.IsAvailable)
        {
            Log.Write(line: $"azureDevOps: back online, reading again");
            Refresh();
        }
    }

    /// What the section shows now, from the store; logged when how it stands changes, in counts.
    void Rebuild()
    {
        if (failed)
        {
            return;
        }
        var built = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: time.GetUtcNow());
        Volatile.Write(location: ref snapshot, value: built);
        (SectionCondition Condition, GroupCounts Counts, PulseProblemKind? Problem) state = (built.Status.Condition, store.Counts, store.Problem?.Kind);
        if (logged is { } last && last.Condition == state.Condition && last.Counts.Equals(other: state.Counts) && last.Problem == state.Problem)
        {
            return;
        }
        logged = state;
        var counts = state.Counts;
        Log.Write(line: $"azureDevOps: {state.Condition}, problem {state.Problem}, organizations {store.State.Organizations.Count}: {counts[PRGroup.NeedsYou]} need you, {counts[PRGroup.Answered]} answered, {counts[PRGroup.Failing]} failing, {counts[PRGroup.Ready]} ready, {counts[PRGroup.ToReview]} to review, {counts[PRGroup.Waiting]} waiting, {counts[PRGroup.Done]} done, {counts[PRGroup.Idle]} idle");
    }

    /// Reading failed in a way BriefBar doesn't expect: the section says so, rather than going on as if it read.
    void Failed(AggregateException error, int fromGeneration)
    {
        Log.Write(error: error.GetBaseException(), context: $"azureDevOps: stopped reading");
        lock (gate)
        {
            if (fromGeneration != generation)
            {
                return;
            }
            failed = true;
            Volatile.Write(location: ref snapshot, value: SectionSnapshot.Starting(info: BriefBar.Core.Sections.AzureDevOpsPullRequests) with
            {
                Status = new SectionStatus(Condition: SectionCondition.Problem, Problem: "BriefBar couldn't read Azure DevOps.", ShortProblem: "Can't read"),
            });
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }
}
