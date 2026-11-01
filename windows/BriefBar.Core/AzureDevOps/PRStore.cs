using BriefBar.Core.Logging;

namespace BriefBar.Core.AzureDevOps;

/// The pull requests as the panel shows them: the engine's records, classified with what you've seen and the time now,
/// in order; their counts; why the list may be out of date; and what you do to them, which is saved in the settings. Also
/// whether BriefBar is finding your organizations. Used under its source's lock. The Mac's `PRStore`, without
/// notifications, summaries, pull requests sent in chats and Copilot tasks.
public sealed class PRStore
{
    /// How long after a failed search for your organizations it's tried again.
    static readonly TimeSpan discoveryRetry = TimeSpan.FromMinutes(value: 1);

    readonly AzureDevOpsSettings settings;
    /// What the open panel has shown in Answered, and when you answered each: seen once the panel closes.
    readonly Dictionary<PRKey, DateTimeOffset> answeredInPanel = [];
    bool isPanelOpen;

    public PRStore(AzureDevOpsSettings settings)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        this.settings = settings;
    }

    /// The engine's latest snapshot.
    public PulseSnapshot State { get; private set; } = new();

    /// Every pull request listed, by group, the most recent first.
    public IReadOnlyList<PRSnapshot> Items { get; private set; } = [];

    public GroupCounts Counts { get; private set; } = new();

    /// Why the list may be missing or out of date; null when it isn't.
    public PulseProblem? Problem { get; private set; }

    public PRDiscovery Discovery { get; private set; } = PRDiscovery.Idle;

    /// Why finding your organizations failed, when it did.
    public PulseProblem? DiscoveryProblem { get; private set; }

    /// When BriefBar last looked for your organizations.
    public DateTimeOffset? LastDiscovery { get; private set; }

    /// Your name in Azure DevOps.
    public string? Reader => State.UserName;

    /// Whether to look for your organizations, as it starts or reads again: you have none, they've never been found, and
    /// it isn't looking already.
    public bool NeedsDiscovery => settings.Organizations.Count == 0 && !settings.HasDiscovered && Discovery != PRDiscovery.Running;

    /// Whether to look for them again by itself, as when you've signed in since: as `NeedsDiscovery`, a minute or more
    /// after it last looked.
    public bool ShouldRetryDiscovery(DateTimeOffset now) => NeedsDiscovery && (LastDiscovery is not { } last || now - last > discoveryRetry);

    /// What the engine read now. Someone else signed in to the Azure CLI: what they've seen is their own, as is what the
    /// panel showed in Answered.
    public void Receive(PulseSnapshot snapshot, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshot);
        if (snapshot.Account is { } account && settings.UseAccount(account: account, now: now))
        {
            answeredInPanel.Clear();
            Log.Write(line: $"azureDevOps: signed in to the Azure CLI as another account");
        }
        State = snapshot;
        if (snapshot.HasLoaded && !snapshot.IsRefreshing && snapshot.Organizations.Count > 0 && snapshot.Problem is null)
        {
            settings.PruneSeen(keeping: snapshot.Records.Select(selector: record => record.Id).ToHashSet(), now: now);
        }
        // Watched pull requests that closed, or that you can't read anymore, aren't watched anymore.
        settings.Unwatch(keys: snapshot.ClosedLinks);
        Recompute(now: now);
    }

    /// Classifies the pull requests again, as what you've seen, a setting or the time changed.
    public void Recompute(DateTimeOffset now)
    {
        var options = settings.ClassifierOptions;
        var watched = settings.WatchedKeys;
        var resolved = State.Records
            .Select(selector: record => watched.Contains(item: record.Id) ? record.Watched() : record)
            .Select(selector: record => PRClassifier.Snapshot(
                record: record, seenCutoff: settings.SeenCutoff(key: record.Id), dismissedCutoff: settings.DismissedCutoff(key: record.Id), now: now, options: options))
            .OfType<PRSnapshot>();
        Items = PROrdering.Sorted(snapshots: resolved);
        if (isPanelOpen)
        {
            NoteAnsweredInPanel(now: now);
        }
        Counts = new GroupCounts(snapshots: Items);
        Problem = CurrentProblem();
    }

    /// The panel shows the list: what it shows in Answered counts as seen once it closes.
    public void PanelOpened(DateTimeOffset now)
    {
        isPanelOpen = true;
        NoteAnsweredInPanel(now: now);
    }

    /// The panel closed: what it showed in Answered goes back to its usual group. Each is seen up to when you answered it,
    /// not up to now, so that whatever came after still counts as new.
    public void PanelClosed()
    {
        if (!isPanelOpen)
        {
            return;
        }
        isPanelOpen = false;
        var shown = answeredInPanel.Select(selector: pair => (pair.Key, pair.Value)).ToList();
        answeredInPanel.Clear();
        settings.MarkSeen(entries: shown);
    }

    /// Sees `item`, as opening it does: comments that wait on you keep it in Needs you, no longer as new, until you
    /// answer them or take it off.
    public void MarkSeen(PRSnapshot item, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: item);
        var newest = Newest(item: item);
        settings.MarkSeen(entries: [(item.Key, newest is { } date && date > now ? date : now)]);
    }

    /// Sees `group`'s pull requests, each up to what the panel showed, not up to now, so that a comment that comes before
    /// the next refresh still counts as new: Needs you keeps only those whose comments still wait on you, and Done
    /// empties.
    public void Clear(PRGroup group, DateTimeOffset now) =>
        settings.MarkSeen(entries: Items.Where(predicate: item => item.Group == group).Select(selector: item => (item.Key, Newest(item: item) ?? item.Since ?? now)).ToList());

    /// Takes `item` off Needs you, up to what the panel showed: what waited on you there doesn't anymore, and it's seen.
    /// Anything that comes after needs you again.
    public void Dismiss(PRSnapshot item, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: item);
        settings.Dismiss(entries: [(item.Key, Newest(item: item) ?? item.Since ?? now)]);
    }

    /// Starts looking for your organizations; false when it's looking already.
    public bool StartDiscovery(DateTimeOffset now)
    {
        if (Discovery == PRDiscovery.Running)
        {
            return false;
        }
        Discovery = PRDiscovery.Running;
        LastDiscovery = now;
        Problem = CurrentProblem();
        return true;
    }

    public void DiscoveryFinished()
    {
        Discovery = PRDiscovery.Idle;
        DiscoveryProblem = null;
        Problem = CurrentProblem();
    }

    /// Finding your organizations failed for `problem`: it's tried again a minute later.
    public void DiscoveryFailed(PulseProblem problem)
    {
        ArgumentNullException.ThrowIfNull(argument: problem);
        Discovery = PRDiscovery.Failed;
        DiscoveryProblem = problem;
        Problem = CurrentProblem();
    }

    static DateTimeOffset? Newest(PRSnapshot item) => item.Events.Count == 0 ? null : item.Events.Max(selector: entry => entry.At);

    void NoteAnsweredInPanel(DateTimeOffset now)
    {
        foreach (var item in Items.Where(predicate: item => item.Group == PRGroup.Answered))
        {
            var at = item.Since ?? now;
            answeredInPanel[item.Key] = answeredInPanel.TryGetValue(key: item.Key, value: out var noted) && noted > at ? noted : at;
        }
    }

    /// The engine's problem, unless the organizations just chosen haven't been read yet, or BriefBar is finding them.
    PulseProblem? CurrentProblem()
    {
        var problem = State.Problem;
        if (problem?.Kind == PulseProblemKind.NoOrganizations && settings.Organizations.Count > 0)
        {
            problem = null;
        }
        if (settings.Organizations.Count == 0)
        {
            problem = Discovery switch
            {
                // The panel says it's looking.
                PRDiscovery.Running => null,
                PRDiscovery.Failed => DiscoveryProblem ?? State.Problem,
                _ => settings.HasDiscovered ? State.Problem : null,
            };
        }
        return problem;
    }
}
