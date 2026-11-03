using System.Text.Json.Nodes;
using BriefBar.Core.Settings;

namespace BriefBar.Core.AzureDevOps;

/// Azure DevOps' settings, and which pull requests you've seen or taken off Needs you, by account, in BriefBar's settings,
/// with the Mac's keys. Safe to use from any thread. The Mac's `AppSettings`, in AzureDevOpsUI, without what Windows
/// doesn't have yet: notifications, summaries, pull requests sent in chats, the sprint, pipelines and Copilot tasks.
public sealed class AzureDevOpsSettings
{
    public const string RefreshSecondsKey = "ado.refreshSeconds";
    public const string KeepDoneHoursKey = "ado.keepDoneHours";
    public const string IdleDaysKey = "ado.idleDays";
    public const string ShowToReviewKey = "ado.showToReviewInMenuBar";
    public const string PullRequestOrderKey = "ado.pullRequestOrder";
    public const string FollowMergesKey = "ado.followMerges";
    public const string WatchedPullRequestsKey = "ado.watchedPullRequests";
    public const string OrganizationsKey = "ado.organizations";
    public const string KnownOrganizationsKey = "ado.knownOrganizations";
    public const string HasDiscoveredKey = "ado.hasDiscoveredOrganizations";
    public const string SeenKey = "ado.seenState";
    public const string OtherSeenKey = "ado.otherAccountsSeenState";

    /// Where the account BriefBar last read your pull requests with is from (`AccessToken.AccountTenant`): a directory's ID,
    /// or an identity provider such as live.com.
    public const string AccountOriginKey = "ado.accountOrigin";

    /// How long a pull request no longer listed is remembered as seen, after you last looked at it.
    static readonly TimeSpan seenKept = TimeSpan.FromDays(value: 60);

    readonly Lock gate = new();
    readonly ISettingsStorage settings;
    int refreshSeconds;
    int keepDoneHours;
    int idleDays;
    bool showToReview;
    PROrder pullRequestOrder;
    bool followMerges;
    List<PullRequestLink> watched;
    List<string> organizations;
    List<string> knownOrganizations;
    bool hasDiscovered;
    SeenState seen;
    Dictionary<string, SeenState> otherSeen;
    string? accountOrigin;
    /// What you've seen is saved once Azure DevOps is on (`StartSeeing`), so that its first run is when you turn it on.
    bool hasSavedSeen;

    public AzureDevOpsSettings(ISettingsStorage settings, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        this.settings = settings;
        refreshSeconds = Choice(value: settings.Number(key: RefreshSecondsKey), choices: RefreshChoices, fallback: 60);
        keepDoneHours = Choice(value: settings.Number(key: KeepDoneHoursKey), choices: KeepDoneChoices, fallback: 24);
        idleDays = Choice(value: settings.Read(key: IdleDaysKey) is JsonValue idle && idle.TryGetValue(value: out int days) ? days : -1, choices: IdleChoices, fallback: 14);
        showToReview = settings.Bool(key: ShowToReviewKey);
        pullRequestOrder = settings.Read(key: PullRequestOrderKey) is JsonValue order && order.TryGetValue(value: out string? rawOrder)
            ? PROrders.FromRawValue(rawValue: rawOrder) ?? PROrder.Status
            : PROrder.Status;
        followMerges = settings.Read(key: FollowMergesKey) is not JsonValue follow || !follow.TryGetValue(value: out bool on) || on;
        watched = ReadLinks(node: settings.Read(key: WatchedPullRequestsKey));
        organizations = ReadNames(node: settings.Read(key: OrganizationsKey));
        knownOrganizations = ReadNames(node: settings.Read(key: KnownOrganizationsKey));
        hasDiscovered = settings.Bool(key: HasDiscoveredKey);
        otherSeen = ReadOtherSeen(node: settings.Read(key: OtherSeenKey));
        accountOrigin = settings.Read(key: AccountOriginKey) is JsonValue origin && origin.TryGetValue(value: out string? kept) && kept.Length > 0 ? kept : null;
        if (SeenState.FromJson(node: settings.Read(key: SeenKey)) is { } stored)
        {
            seen = stored;
            hasSavedSeen = true;
        }
        else
        {
            seen = SeenState.FirstRun(now: now);
        }
    }

    /// A setting, what you've seen, or the pull requests you watch changed. Raised on the thread that changed it.
    public event EventHandler? Changed;

    /// Refresh's choices, in seconds.
    public static IReadOnlyList<int> RefreshChoices { get; } = [60, 120, 300];

    /// Keep done for's choices, in hours.
    public static IReadOnlyList<int> KeepDoneChoices { get; } = [4, 24, 72];

    /// Idle after no activity for's choices, in days; 0 is never.
    public static IReadOnlyList<int> IdleChoices { get; } = [7, 14, 30, 0];

    /// How often the pull requests are read, in seconds.
    public int RefreshSeconds
    {
        get => Read(value: () => refreshSeconds);
        set => Write(change: () => Swap(field: ref refreshSeconds, value: Choice(value: value, choices: RefreshChoices, fallback: refreshSeconds)), save: () => settings.SetNumber(key: RefreshSecondsKey, value: refreshSeconds));
    }

    /// How long completed and abandoned pull requests stay in Done, unless you've seen them.
    public int KeepDoneHours
    {
        get => Read(value: () => keepDoneHours);
        set => Write(change: () => Swap(field: ref keepDoneHours, value: Choice(value: value, choices: KeepDoneChoices, fallback: keepDoneHours)), save: () => settings.SetNumber(key: KeepDoneHoursKey, value: keepDoneHours));
    }

    /// Pull requests without activity for this many days are idle; 0 never.
    public int IdleDays
    {
        get => Read(value: () => idleDays);
        set => Write(change: () => Swap(field: ref idleDays, value: Choice(value: value, choices: IdleChoices, fallback: idleDays)), save: () => settings.SetNumber(key: IdleDaysKey, value: idleDays));
    }

    /// Counts To review in the bar, with what needs you.
    public bool ShowToReview
    {
        get => Read(value: () => showToReview);
        set => Write(change: () => Swap(field: ref showToReview, value: value), save: () => settings.SetBool(key: ShowToReviewKey, value: showToReview));
    }

    /// How the pull requests are listed: in their groups, or by when each was created. By status until you choose.
    public PROrder PullRequestOrder
    {
        get => Read(value: () => pullRequestOrder);
        set
        {
            if (!Enum.IsDefined(value: value))
            {
                throw new ArgumentOutOfRangeException(paramName: nameof(value), actualValue: value, message: "Not an order.");
            }
            Write(
                change: () => Swap(field: ref pullRequestOrder, value: value),
                save: () => settings.Write(key: PullRequestOrderKey, value: JsonValue.Create(value: pullRequestOrder.RawValue())));
        }
    }

    /// Follows the pipelines that run after you merge a pull request, while Done keeps it.
    public bool FollowMerges
    {
        get => Read(value: () => followMerges);
        set => Write(change: () => Swap(field: ref followMerges, value: value), save: () => settings.SetBool(key: FollowMergesKey, value: followMerges));
    }

    /// The organizations to watch.
    public IReadOnlyList<string> Organizations
    {
        get => Read(value: () => (IReadOnlyList<string>)[.. organizations]);
        set
        {
            ArgumentNullException.ThrowIfNull(argument: value);
            Write(change: () => SwapList(field: ref organizations, value: value), save: () => settings.Write(key: OrganizationsKey, value: Names(names: organizations)));
        }
    }

    /// Every organization you belong to, as last found.
    public IReadOnlyList<string> KnownOrganizations
    {
        get => Read(value: () => (IReadOnlyList<string>)[.. knownOrganizations]);
        set
        {
            ArgumentNullException.ThrowIfNull(argument: value);
            Write(change: () => SwapList(field: ref knownOrganizations, value: value), save: () => settings.Write(key: KnownOrganizationsKey, value: Names(names: knownOrganizations)));
        }
    }

    /// Your organizations were found once: they aren't looked for again by themselves.
    public bool HasDiscovered
    {
        get => Read(value: () => hasDiscovered);
        set => Write(change: () => Swap(field: ref hasDiscovered, value: value), save: () => settings.SetBool(key: HasDiscoveredKey, value: hasDiscovered));
    }

    /// The pull requests you watch by their links, though you're not on them: listed as if you reviewed them, until they
    /// close or you stop watching them.
    public IReadOnlyList<PullRequestLink> WatchedPullRequests => Read(value: () => (IReadOnlyList<PullRequestLink>)[.. watched]);

    public IReadOnlySet<PRKey> WatchedKeys => Read(value: () => (IReadOnlySet<PRKey>)watched.Select(selector: link => link.Key).ToHashSet());

    /// What the account signed in now has seen.
    public SeenState Seen => Read(value: () => seen);

    /// The Azure CLI account whose seen state is in use, once known.
    public string? Account => Read(value: () => seen.Account);

    /// Where that account is from (`AccessToken.AccountTenant`), so that after a restart, your own directory wanting you to
    /// sign in again isn't taken for someone else's sign-in. Turning Azure DevOps off forgets it (`ForgetSeen`).
    public string? AccountOrigin
    {
        get => Read(value: () => accountOrigin);
        set => Write(
            change: () => Swap(field: ref accountOrigin, value: string.IsNullOrEmpty(value: value) ? null : value),
            save: () => settings.Write(key: AccountOriginKey, value: accountOrigin is null ? null : JsonValue.Create(value: accountOrigin)));
    }

    /// What the engine reads, as these settings say.
    public PulseEngineConfiguration EngineConfiguration => Read(value: () => new PulseEngineConfiguration
    {
        Organizations = new ValueList<string>(items: organizations),
        Interval = TimeSpan.FromSeconds(value: refreshSeconds),
        KeepDoneFor = TimeSpan.FromHours(value: keepDoneHours),
        InactiveAfter = idleDays > 0 ? TimeSpan.FromDays(value: idleDays) : null,
        FollowMerges = followMerges,
    });

    /// How pull requests are classified, as these settings say.
    public ClassifierOptions ClassifierOptions => Read(value: () => new ClassifierOptions
    {
        InactiveAfter = idleDays > 0 ? TimeSpan.FromDays(value: idleDays) : null,
        KeepDoneFor = TimeSpan.FromHours(value: keepDoneHours),
    });

    /// "Every minute", "Every 2 minutes".
    public static string RefreshTitle(int seconds) => seconds == 60
        ? "Every minute"
        : "Every " + (seconds / 60).ToString(provider: System.Globalization.CultureInfo.InvariantCulture) + " minutes";

    /// "4 hours", "1 day", "3 days".
    public static string KeepDoneTitle(int hours) => hours switch
    {
        24 => "1 day",
        _ when hours % 24 == 0 => (hours / 24).ToString(provider: System.Globalization.CultureInfo.InvariantCulture) + " days",
        1 => "1 hour",
        _ => hours.ToString(provider: System.Globalization.CultureInfo.InvariantCulture) + " hours",
    };

    /// "1 week", "2 weeks", "1 month", "Never".
    public static string IdleTitle(int days) => days switch
    {
        0 => "Never",
        7 => "1 week",
        14 => "2 weeks",
        30 => "1 month",
        _ => days.ToString(provider: System.Globalization.CultureInfo.InvariantCulture) + " days",
    };

    /// Azure DevOps starts: what you've seen counts from now, the first time.
    public void StartSeeing(DateTimeOffset now)
    {
        lock (gate)
        {
            if (hasSavedSeen)
            {
                return;
            }
            seen = SeenState.FirstRun(now: now);
            PersistSeen();
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }

    /// Forgets what you've seen, with every account, and where the account is from, as turning Azure DevOps off does. Your
    /// organizations and the pull requests you watch stay, with the other settings.
    public void ForgetSeen(DateTimeOffset now)
    {
        lock (gate)
        {
            settings.Write(key: SeenKey, value: null);
            settings.Write(key: OtherSeenKey, value: null);
            settings.Write(key: AccountOriginKey, value: null);
            hasSavedSeen = false;
            seen = SeenState.FirstRun(now: now);
            otherSeen = new Dictionary<string, SeenState>(comparer: StringComparer.Ordinal);
            accountOrigin = null;
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }

    /// Activity up to this, for `key`, counts as seen.
    public DateTimeOffset SeenCutoff(PRKey key) => Read(value: () => seen.Cutoff(key: key));

    /// Comments up to this that still wait on you in `key` don't need you anymore.
    public DateTimeOffset DismissedCutoff(PRKey key) => Read(value: () => seen.DismissedCutoff(key: key));

    /// Each pull request seen up to its own time.
    public void MarkSeen(IEnumerable<(PRKey Key, DateTimeOffset Date)> entries) => Update(entries: entries, dismissing: false);

    /// Takes each pull request off Needs you up to its own time, which sees it too: the comments that waited on you there
    /// don't anymore, and what comes after needs you again.
    public void Dismiss(IEnumerable<(PRKey Key, DateTimeOffset Date)> entries) => Update(entries: entries, dismissing: true);

    /// Forgets the pull requests that aren't listed anymore and were last seen two months before `now`, or longer.
    public void PruneSeen(IReadOnlySet<PRKey> keeping, DateTimeOffset now)
    {
        lock (gate)
        {
            var pruned = seen.Pruning(keeping: keeping, olderThan: now - seenKept);
            if (pruned.Equals(other: seen))
            {
                return;
            }
            seen = pruned;
            PersistSeen();
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }

    /// Switches what you've seen to `account`, signed in to the Azure CLI now, keeping the last one's for when it's back.
    /// Returns whether another account was signed in before.
    public bool UseAccount(string account, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: account);
        bool switched;
        lock (gate)
        {
            var (book, signedOut) = new SeenBook(Current: seen, Others: otherSeen).SigningIn(account: account, now: now);
            switched = signedOut;
            if (book.Current.Equals(other: seen) && book.Others.Count == otherSeen.Count)
            {
                return switched;
            }
            otherSeen = new Dictionary<string, SeenState>(collection: book.Others, comparer: StringComparer.Ordinal);
            seen = book.Current;
            PersistSeen();
            PersistOtherSeen();
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
        return switched;
    }

    /// Watches the pull request `link` names. Returns false when it's watched already.
    public bool Watch(PullRequestLink link)
    {
        ArgumentNullException.ThrowIfNull(argument: link);
        var added = false;
        Write(
            change: () =>
            {
                if (watched.Exists(match: existing => existing.Key == link.Key))
                {
                    return false;
                }
                watched = [.. watched, link];
                added = true;
                return true;
            },
            save: () => settings.Write(key: WatchedPullRequestsKey, value: Links(links: watched)));
        return added;
    }

    /// Stops watching `keys`.
    public void Unwatch(IReadOnlySet<PRKey> keys)
    {
        ArgumentNullException.ThrowIfNull(argument: keys);
        Write(
            change: () =>
            {
                if (!watched.Exists(match: link => keys.Contains(item: link.Key)))
                {
                    return false;
                }
                watched = watched.Where(predicate: link => !keys.Contains(item: link.Key)).ToList();
                return true;
            },
            save: () => settings.Write(key: WatchedPullRequestsKey, value: Links(links: watched)));
    }

    /// Whether `name` is watched: organization names are case-insensitive in Azure DevOps.
    public bool IsWatching(string name) =>
        Read(value: () => organizations.Exists(match: organization => string.Equals(a: organization, b: name, comparisonType: StringComparison.OrdinalIgnoreCase)));

    /// Watches `name`, or stops watching it, by any spelling, unless it's that way already: in one step, so that whoever
    /// else watches it meanwhile, as the check of an organization you add does while you switch it on in Settings, nobody
    /// undoes it, as looking first and then switching it could.
    public void SetWatching(string name, bool watching)
    {
        ArgumentNullException.ThrowIfNull(argument: name);
        Write(
            change: () =>
            {
                var wasWatching = organizations.Exists(match: organization => string.Equals(a: organization, b: name, comparisonType: StringComparison.OrdinalIgnoreCase));
                if (wasWatching == watching)
                {
                    return false;
                }
                organizations = watching
                    ? [.. OrganizationDiscovery.Merged(names: organizations, preferred: [name])]
                    : organizations.Where(predicate: organization => !string.Equals(a: organization, b: name, comparisonType: StringComparison.OrdinalIgnoreCase)).ToList();
                return true;
            },
            save: () => settings.Write(key: OrganizationsKey, value: Names(names: organizations)));
    }

    static int Choice(int value, IReadOnlyList<int> choices, int fallback) => choices.Contains(value: value) ? value : fallback;

    static bool Swap<T>(ref T field, T value)
    {
        if (EqualityComparer<T>.Default.Equals(x: field, y: value))
        {
            return false;
        }
        field = value;
        return true;
    }

    static bool SwapList(ref List<string> field, IReadOnlyList<string> value)
    {
        if (field.SequenceEqual(second: value, comparer: StringComparer.Ordinal))
        {
            return false;
        }
        field = [.. value];
        return true;
    }

    static List<string> ReadNames(JsonNode? node) =>
        node is JsonArray array
            ? array.OfType<JsonValue>().Select(selector: value => value.TryGetValue(value: out string? name) ? name : null).OfType<string>().ToList()
            : [];

    static JsonArray Names(IEnumerable<string> names) => new(items: [.. names.Select(selector: name => (JsonNode)JsonValue.Create(value: name))]);

    /// The links saved, without those that can't be read.
    static List<PullRequestLink> ReadLinks(JsonNode? node)
    {
        var links = new List<PullRequestLink>();
        foreach (var item in (node as JsonArray ?? []).OfType<JsonObject>())
        {
            if (item["organization"] is JsonValue organization && organization.TryGetValue(value: out string? org)
                && item["project"] is JsonValue project && project.TryGetValue(value: out string? projectName)
                && item["repository"] is JsonValue repository && repository.TryGetValue(value: out string? repositoryName)
                && item["number"] is JsonValue number && number.TryGetValue(value: out int id) && id > 0
                && OrganizationDiscovery.IsValidName(name: org))
            {
                links.Add(item: new PullRequestLink(Organization: org, Project: projectName, Repository: repositoryName, Number: id));
            }
        }
        return links;
    }

    static JsonArray Links(IEnumerable<PullRequestLink> links) => new(items: [.. links.Select(selector: link => (JsonNode)new JsonObject
    {
        ["organization"] = link.Organization,
        ["project"] = link.Project,
        ["repository"] = link.Repository,
        ["number"] = link.Number,
    })]);

    static Dictionary<string, SeenState> ReadOtherSeen(JsonNode? node)
    {
        var states = new Dictionary<string, SeenState>(comparer: StringComparer.Ordinal);
        foreach (var (account, value) in node as JsonObject ?? [])
        {
            if (SeenState.FromJson(node: value) is { } state)
            {
                states[account] = state;
            }
        }
        return states;
    }

    void Update(IEnumerable<(PRKey Key, DateTimeOffset Date)> entries, bool dismissing)
    {
        ArgumentNullException.ThrowIfNull(argument: entries);
        lock (gate)
        {
            var updated = seen;
            foreach (var (key, date) in entries)
            {
                updated = dismissing ? updated.Dismissing(keys: [key], date: date) : updated.MarkingSeen(keys: [key], date: date);
            }
            if (updated.Equals(other: seen))
            {
                return;
            }
            seen = updated;
            PersistSeen();
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }

    /// Under the lock.
    void PersistSeen()
    {
        hasSavedSeen = true;
        settings.Write(key: SeenKey, value: seen.ToJson());
    }

    /// Under the lock.
    void PersistOtherSeen()
    {
        var saved = new JsonObject();
        foreach (var (account, state) in otherSeen.OrderBy(keySelector: pair => pair.Key, comparer: StringComparer.Ordinal))
        {
            saved[account] = state.ToJson();
        }
        settings.Write(key: OtherSeenKey, value: saved);
    }

    T Read<T>(Func<T> value)
    {
        lock (gate)
        {
            return value();
        }
    }

    /// Changes a setting under the lock, saves it if it changed, and says so, outside the lock.
    void Write(Func<bool> change, Func<bool> save)
    {
        lock (gate)
        {
            if (!change())
            {
                return;
            }
            save();
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }
}
