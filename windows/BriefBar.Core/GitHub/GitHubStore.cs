namespace BriefBar.Core.GitHub;

/// Your GitHub pull requests as the last read found them, why the list may be missing or out of date, and when to read
/// again: every few minutes, as `GitHubSettings` says, every minute while there's something to fix, never before GitHub
/// said to, and as a panel opens unless it just did. It reads nothing itself: `GitHubSource` reads, and tells it how that
/// went, under its own lock, as this isn't safe to use from several threads at once. Stopped, it forgets everything. The
/// Mac's `GitHubStore`, without its timer and its reads.
public sealed class GitHubStore
{
    readonly GitHubSettings settings;
    DateTimeOffset? lastAttempt;

    public GitHubStore(GitHubSettings settings)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        this.settings = settings;
    }

    /// How soon a panel opening reads again.
    public static TimeSpan MinimumGap { get; } = TimeSpan.FromSeconds(value: 10);

    /// How often it tries again while you need to sign in or are offline, so that a fix shows within a minute.
    public static TimeSpan RetryInterval { get; } = TimeSpan.FromMinutes(value: 1);

    public IReadOnlyList<GitHubPRSnapshot> Items { get; private set; } = [];

    public GitHubGroupCounts Counts { get; private set; } = new();

    public GitHubProblem? Problem { get; private set; }

    /// What GitHub couldn't read, alongside the list.
    public string? Notice { get; private set; }

    public bool MoreThanShown { get; private set; }

    /// Who the GitHub CLI is signed in as.
    public string? Login { get; private set; }

    /// It has read, or tried to, since it started.
    public bool HasLoaded { get; private set; }

    public bool IsRefreshing { get; private set; }

    /// When it last read the list.
    public DateTimeOffset? RefreshedAt { get; private set; }

    public bool IsStarted { get; private set; }

    public void Start() => IsStarted = true;

    /// Stops reading, and forgets what it read.
    public void Stop()
    {
        IsStarted = false;
        lastAttempt = null;
        Items = [];
        Counts = new GitHubGroupCounts();
        Problem = null;
        Notice = null;
        MoreThanShown = false;
        Login = null;
        HasLoaded = false;
        IsRefreshing = false;
        RefreshedAt = null;
    }

    /// Whether it's time to read again, at `date`: every few minutes, every minute while there's something to fix, and not
    /// before GitHub said to.
    public bool IsDue(DateTimeOffset date)
    {
        if (!IsStarted || IsThrottled(at: date))
        {
            return false;
        }
        if (lastAttempt is not { } last)
        {
            return true;
        }
        var interval = settings.RefreshInterval;
        if (Problem?.Kind is GitHubProblemKind.CliNotFound or GitHubProblemKind.SignedOut or GitHubProblemKind.AuthFailed or GitHubProblemKind.Offline
            && RetryInterval < interval)
        {
            interval = RetryInterval;
        }
        return date - last >= interval;
    }

    /// Whether a panel opening should read again, at `date`: unless it read in the last 10 seconds.
    public bool IsStale(DateTimeOffset date) => lastAttempt is not { } last || date - last >= MinimumGap;

    /// Starts a read at `now`, unless one is under way, it's stopped, or GitHub said to wait: returns whether to read.
    public bool BeginRefresh(DateTimeOffset now)
    {
        if (!IsStarted || IsRefreshing || IsThrottled(at: now))
        {
            return false;
        }
        lastAttempt = now;
        IsRefreshing = true;
        return true;
    }

    /// A read found `load`, at `now`.
    public void Receive(GitHubLoad load, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: load);
        IsRefreshing = false;
        Items = load.Items;
        Counts = load.Counts;
        Login = load.Login;
        Notice = load.Notice;
        MoreThanShown = load.MoreThanShown;
        Problem = null;
        HasLoaded = true;
        RefreshedAt = now;
    }

    /// A read failed with `error`, at `now`. Signed out, or as someone else, the list was theirs, and goes; otherwise the
    /// last one stays, which may be out of date.
    public void Fail(GitHubError error, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: error);
        IsRefreshing = false;
        Problem = GitHubProblem.From(error: error, now: now);
        HasLoaded = true;
        if (Problem.NeedsSignIn)
        {
            Items = [];
            Counts = new GitHubGroupCounts();
            Login = null;
            Notice = null;
            MoreThanShown = false;
        }
    }

    public IReadOnlyList<GitHubPRSnapshot> ItemsIn(GitHubPRGroup group) => Items.Where(predicate: item => item.Group == group).ToList();

    bool IsThrottled(DateTimeOffset at) => Problem is { Kind: GitHubProblemKind.Throttled, Until: { } until } && at < until;
}
