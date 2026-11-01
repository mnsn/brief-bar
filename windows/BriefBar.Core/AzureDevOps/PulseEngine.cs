using BriefBar.Core.Logging;

namespace BriefBar.Core.AzureDevOps;

/// Polls Azure DevOps, with GET requests only: the pull request lists every refresh, three requests an organization; the
/// details, policies and threads, of the pull requests the `RefreshPlanner` picks, two requests each; once, the timeline
/// of each failed build of your pull requests, for where it failed (`BuildFailureReader`); and the pipelines after your
/// merges (`MergeFollower`). Azure DevOps can't push changes to a personal app, and pull requests and builds take minutes
/// to hours, so a refresh a minute is plenty. The Mac's `PulseEngine` ([How it
/// works](../../../docs/how-it-works.md#where-the-data-comes-from-1)).
///
/// Its state is kept under one lock and changed only between requests, so asking for its snapshot, or changing what it
/// reads, is safe from any thread while a refresh waits for Azure DevOps. One refresh runs at a time. What it knows is
/// handed to `onChange`, on the refresh's thread, whenever it changes.
public sealed class PulseEngine : IPulseEngine
{
    /// The most of your pull requests that left the list looked up in one refresh.
    const int VanishedPerRefresh = 5;

    /// The most pull requests sent to you or watched read in one refresh.
    const int LinkedPerRefresh = 10;

    /// How long a linked pull request that's closed or can't be read waits to be read again.
    static readonly TimeSpan linkedRetry = TimeSpan.FromHours(value: 1);

    readonly Lock gate = new();
    readonly Lock publishing = new();
    readonly SemaphoreSlim refreshing = new(initialCount: 1, maxCount: 1);
    readonly ADOClient client;
    readonly Action<PulseSnapshot> onChange;
    readonly TimeProvider time;
    readonly Waker waker = new();
    readonly BuildFailureReader builds = new();
    readonly MergeFollower merges = new();
    PulseEngineConfiguration configuration;
    CancellationTokenSource? stopping;
    Task? loop;

    /// Organization → your identity's ID there.
    readonly Dictionary<string, string> identities = new(comparer: StringComparer.Ordinal);
    /// Whose sign-in the identities, lists and details are for.
    string? account;
    string? userName;
    readonly Dictionary<string, DateTimeOffset> firstLoaded = new(comparer: StringComparer.Ordinal);
    /// Pull requests sent to you or watched, to list even when you're not on them.
    HashSet<PRKey> linkedKeys = [];
    /// Linked pull requests that couldn't be read or are closed, and when, to try again only an hour later.
    readonly Dictionary<PRKey, DateTimeOffset> linkedFailures = [];
    /// Linked pull requests as last read, and when: kept between refreshes, which read only a few each.
    readonly Dictionary<PRKey, (PulseListed Listed, DateTimeOffset ReadAt)> linked = [];
    /// Linked pull requests read as closed, or gone or forbidden.
    readonly HashSet<PRKey> closedLinks = [];
    Dictionary<PRKey, PulseListed> active = [];
    Dictionary<PRKey, PullRequest> done = [];
    readonly Dictionary<PRKey, PRDetails> details = [];
    readonly Dictionary<PRKey, RefreshPlannerEntry> entries = [];
    /// Your pull requests that left the active list without completing: abandoned, or completed just now. Each is looked
    /// up by its ID, a few a refresh, until that works or it's too old to show as done.
    readonly Dictionary<PRKey, PulseVanished> vanished = [];
    PulseProblem? problem;
    DateTimeOffset? refreshedAt;
    bool hasLoaded;
    bool isRefreshing;
    /// Refreshes in a row that read nothing, for backing off.
    int failures;
    PulseSnapshot? lastPublished;

    public PulseEngine(ADOClient client, PulseEngineConfiguration configuration, Action<PulseSnapshot> onChange, TimeProvider? time = null)
    {
        ArgumentNullException.ThrowIfNull(argument: client);
        ArgumentNullException.ThrowIfNull(argument: configuration);
        ArgumentNullException.ThrowIfNull(argument: onChange);
        this.client = client;
        this.configuration = configuration;
        this.onChange = onChange;
        this.time = time ?? TimeProvider.System;
    }

    /// Refreshes now, and then every interval, on the thread pool, until stopped. The task ends with an error only for one
    /// BriefBar doesn't expect: what Azure DevOps and the Azure CLI do wrong is the snapshot's `Problem`.
    public Task Start()
    {
        lock (gate)
        {
            if (loop is not null)
            {
                return loop;
            }
            stopping = new CancellationTokenSource();
            var token = stopping.Token;
            loop = Task.Run(function: () => LoopAsync(cancellationToken: token), cancellationToken: CancellationToken.None);
            return loop;
        }
    }

    /// Stops refreshing, and waits for a refresh under way to stop.
    public async Task StopAsync()
    {
        Task? running;
        CancellationTokenSource? stop;
        lock (gate)
        {
            running = loop;
            stop = stopping;
            loop = null;
            stopping = null;
        }
        if (stop is null)
        {
            return;
        }
        await stop.CancelAsync().ConfigureAwait(continueOnCapturedContext: false);
        waker.Wake();
        try
        {
            await running!.ConfigureAwait(options: ConfigureAwaitOptions.SuppressThrowing);
        }
        finally
        {
            stop.Dispose();
        }
    }

    /// Asks for a refresh as soon as possible, as when the panel opens or the PC wakes.
    public void Refresh() => waker.Wake();

    public void SetConfiguration(PulseEngineConfiguration newConfiguration)
    {
        ArgumentNullException.ThrowIfNull(argument: newConfiguration);
        lock (gate)
        {
            if (newConfiguration == configuration)
            {
                return;
            }
            var organizationsChanged = !newConfiguration.Organizations.Equals(other: configuration.Organizations);
            configuration = newConfiguration;
            if (organizationsChanged)
            {
                var kept = newConfiguration.Organizations.ToHashSet(comparer: StringComparer.Ordinal);
                // Pull requests sent to you or watched stay, whichever organizations are watched.
                active = active.Where(predicate: pair => kept.Contains(item: pair.Key.Organization) || linked.ContainsKey(key: pair.Key))
                    .ToDictionary(keySelector: pair => pair.Key, elementSelector: pair => pair.Value);
                done = done.Where(predicate: pair => kept.Contains(item: pair.Key.Organization)).ToDictionary(keySelector: pair => pair.Key, elementSelector: pair => pair.Value);
                RemoveWhere(dictionary: vanished, predicate: key => !kept.Contains(item: key.Organization));
                RemoveWhere(dictionary: firstLoaded, predicate: organization => !kept.Contains(item: organization));
            }
        }
        Publish();
        waker.Wake();
    }

    /// The pull requests sent to you, or that you watch: those not in your lists are read by their IDs, and listed as
    /// `Linked`, or by your role on them.
    public void SetLinkedPullRequests(IReadOnlySet<PRKey> keys)
    {
        ArgumentNullException.ThrowIfNull(argument: keys);
        bool added;
        lock (gate)
        {
            if (linkedKeys.SetEquals(other: keys))
            {
                return;
            }
            added = !keys.IsSubsetOf(other: linkedKeys);
            linkedKeys = [.. keys];
            RemoveWhere(dictionary: linkedFailures, predicate: key => !keys.Contains(item: key));
            closedLinks.IntersectWith(other: keys);
            // The ones listed only because of a link go with their links, now rather than on the next refresh.
            foreach (var key in linked.Keys.Where(predicate: key => !keys.Contains(item: key)).ToList())
            {
                linked.Remove(key: key);
                active.Remove(key: key);
                details.Remove(key: key);
                entries.Remove(key: key);
            }
            if (configuration.Organizations.Count == 0 && keys.Count == 0)
            {
                ListNothing();
            }
        }
        Publish();
        if (added)
        {
            waker.Wake();
        }
    }

    public PulseSnapshot CurrentSnapshot()
    {
        lock (gate)
        {
            return Snapshot();
        }
    }

    /// One load, without the timer: for tests.
    public static async Task<PulseSnapshot> LoadOnceAsync(ADOClient client, PulseEngineConfiguration configuration, CancellationToken cancellationToken, TimeProvider? time = null)
    {
        using var engine = new PulseEngine(client: client, configuration: configuration, onChange: _ => { }, time: time);
        await engine.RefreshNowAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        return engine.CurrentSnapshot();
    }

    /// One refresh: the lists, then the details the planner picks, then where failed builds failed and the pipelines after
    /// your merges.
    public async Task RefreshNowAsync(CancellationToken cancellationToken)
    {
        await refreshing.WaitAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        try
        {
            PulseEngineConfiguration current;
            bool nothingToRead;
            lock (gate)
            {
                current = configuration;
                // Pull requests sent to you are read even without organizations to watch.
                nothingToRead = current.Organizations.Count == 0 && linkedKeys.Count == 0;
                if (nothingToRead)
                {
                    ListNothing();
                }
                else
                {
                    isRefreshing = true;
                }
            }
            Publish();
            if (nothingToRead)
            {
                return;
            }
            try
            {
                await RefreshAsync(configuration: current, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
            }
            finally
            {
                lock (gate)
                {
                    isRefreshing = false;
                    hasLoaded = true;
                }
                Publish();
            }
        }
        finally
        {
            refreshing.Release();
        }
    }

    /// Stops refreshing, without waiting for a refresh under way, which stops at its next request.
    public void Dispose()
    {
        lock (gate)
        {
            stopping?.Cancel();
        }
        waker.Wake();
    }

    static void RemoveWhere<TKey, TValue>(Dictionary<TKey, TValue> dictionary, Func<TKey, bool> predicate)
        where TKey : notnull
    {
        foreach (var key in dictionary.Keys.Where(predicate: predicate).ToList())
        {
            dictionary.Remove(key: key);
        }
    }

    async Task LoopAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                await RefreshNowAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
                await waker.WaitAsync(delay: NextDelay(), time: time, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            Log.Write(line: $"azureDevOps: stopped refreshing");
        }
    }

    async Task RefreshAsync(PulseEngineConfiguration configuration, CancellationToken cancellationToken)
    {
        var organizations = configuration.Organizations;
        // Signing in comes first: nothing works without a token, and a failure here says exactly what's wrong.
        AccessToken token;
        try
        {
            token = await client.Tokens.TokenAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        }
        catch (AuthException error)
        {
            lock (gate)
            {
                problem = PulseProblem.From(error: ADOError.FromAuth(error: error.Error), now: time.GetUtcNow());
                failures++;
            }
            return;
        }
        Dictionary<string, string> known;
        lock (gate)
        {
            // Someone else signed in: your identity in each organization, and everything read as the last one, is out of
            // date.
            if (token.Account is { } signedIn)
            {
                if (account is { } previous && previous != signedIn)
                {
                    ForgetAccount();
                }
                account = signedIn;
            }
            known = new Dictionary<string, string>(collection: identities, comparer: StringComparer.Ordinal);
        }

        var startedAt = time.GetUtcNow();
        var closedSince = startedAt - configuration.KeepDoneFor;
        var results = await Task.WhenAll(tasks: organizations.Select(selector: organization => ListsAsync(
            organization: organization, me: known.GetValueOrDefault(key: organization), closedSince: closedSince, cancellationToken: cancellationToken)))
            .ConfigureAwait(continueOnCapturedContext: false);

        var listed = new Dictionary<PRKey, PulseListed>();
        var completed = new Dictionary<PRKey, PullRequest>();
        var errors = new List<(string Organization, ADOError Error)>();
        lock (gate)
        {
            foreach (var (organization, lists, error) in results)
            {
                if (lists is not null)
                {
                    identities[organization] = lists.Me;
                    if (lists.Name is { } name)
                    {
                        userName = name;
                    }
                    firstLoaded.TryAdd(key: organization, value: startedAt);
                    foreach (var pr in lists.Mine.Where(predicate: pr => pr.Status == PullRequestStatus.Active))
                    {
                        listed[pr.Key] = new PulseListed(PullRequest: pr, Role: PRRole.Author);
                    }
                    foreach (var pr in lists.Reviewing.Where(predicate: pr => pr.Status == PullRequestStatus.Active && pr.Author.Id != lists.Me && !listed.ContainsKey(key: pr.Key)))
                    {
                        listed[pr.Key] = new PulseListed(PullRequest: pr, Role: PRRole.Reviewer);
                    }
                    foreach (var pr in lists.Completed)
                    {
                        completed[pr.Key] = pr;
                    }
                }
                else
                {
                    errors.Add(item: (organization, error!));
                    // Keep what was there until it can be read again.
                    foreach (var (key, item) in active.Where(predicate: pair => pair.Key.Organization == organization))
                    {
                        listed[key] = item;
                    }
                    foreach (var (key, pr) in done.Where(predicate: pair => pair.Key.Organization == organization))
                    {
                        completed[key] = pr;
                    }
                }
            }
            if (errors.Count > 0 && errors.Count == organizations.Count)
            {
                var (organization, error) = errors[0];
                problem = PulseProblem.From(error: error, now: time.GetUtcNow(), organization: organizations.Count > 1 ? organization : null);
                failures++;
                return;
            }
            failures = 0;
        }

        var succeeded = organizations.Except(second: errors.Select(selector: failed => failed.Organization), comparer: StringComparer.Ordinal).ToHashSet(comparer: StringComparer.Ordinal);
        await LookUpVanishedAsync(
            listed: listed, completed: completed, succeeded: succeeded, startedAt: startedAt, closedSince: closedSince, configuration: configuration, cancellationToken: cancellationToken)
            .ConfigureAwait(continueOnCapturedContext: false);

        lock (gate)
        {
            foreach (var (key, pr) in done.Where(predicate: pair => !completed.ContainsKey(key: pair.Key) && !listed.ContainsKey(key: pair.Key)))
            {
                completed[key] = pr;
            }
            // The organizations may have changed while the lists loaded: only the ones still watched stay.
            var watched = this.configuration.Organizations.ToHashSet(comparer: StringComparer.Ordinal);
            RemoveWhere(dictionary: listed, predicate: key => !watched.Contains(item: key.Organization));
            RemoveWhere(dictionary: completed, predicate: key => !watched.Contains(item: key.Organization));
            RemoveWhere(dictionary: vanished, predicate: key => !watched.Contains(item: key.Organization));
            RemoveWhere(dictionary: firstLoaded, predicate: organization => !watched.Contains(item: organization));
        }
        await AddLinkedAsync(listed: listed, date: startedAt, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);

        IReadOnlyList<PRKey> keys;
        lock (gate)
        {
            active = listed;
            done = completed.Where(predicate: pair => !listed.ContainsKey(key: pair.Key) && (pair.Value.ClosedAt ?? DateTimeOffset.MinValue) > closedSince)
                .ToDictionary(keySelector: pair => pair.Key, elementSelector: pair => pair.Value);
            RemoveWhere(dictionary: details, predicate: key => !listed.ContainsKey(key: key));
            RemoveWhere(dictionary: entries, predicate: key => !listed.ContainsKey(key: key));
            // Details for every pull request without them, all of them on the first load, and a budget of others.
            keys = RefreshPlanner.Plan(
                candidates: listed.Values.Select(selector: item => new RefreshPlannerCandidate(Key: item.PullRequest.Key, Fingerprint: item.PullRequest.Fingerprint)),
                cache: entries,
                now: startedAt,
                options: configuration.Planner,
                limit: configuration.Planner.Budget);
        }
        var throttled = await FetchDetailsAsync(
            pullRequests: keys.Where(predicate: listed.ContainsKey).Select(selector: key => listed[key].PullRequest).ToList(),
            configuration: configuration,
            cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        throttled ??= await builds.ReadAsync(wanted: FailedBuilds(), client: client, date: startedAt, interval: configuration.Interval, cancellationToken: cancellationToken)
            .ConfigureAwait(continueOnCapturedContext: false);
        if (throttled is null)
        {
            List<PullRequest> merged;
            lock (gate)
            {
                merged = [.. done.Values];
            }
            throttled = await merges.FollowAsync(done: merged, configuration: configuration, client: client, date: startedAt, cancellationToken: cancellationToken)
                .ConfigureAwait(continueOnCapturedContext: false);
        }

        lock (gate)
        {
            refreshedAt = time.GetUtcNow();
            if (throttled is not null)
            {
                problem = PulseProblem.From(error: throttled, now: time.GetUtcNow());
            }
            else if (errors.Count > 0)
            {
                var names = string.Join(separator: ", ", values: errors.Select(selector: failed => failed.Organization + " (" + failed.Error.Description + ")"));
                problem = new PulseProblem(Kind: PulseProblemKind.SomeOrganizations, Detail: "Couldn't read " + names + ".");
            }
            else
            {
                problem = null;
            }
        }
    }

    /// Your pull requests that left the active list without completing were abandoned, or completed just now: each is
    /// looked up by its ID, a few a refresh, the ones never looked up first, and again next time if that fails.
    async Task LookUpVanishedAsync(
        Dictionary<PRKey, PulseListed> listed,
        Dictionary<PRKey, PullRequest> completed,
        HashSet<string> succeeded,
        DateTimeOffset startedAt,
        DateTimeOffset closedSince,
        PulseEngineConfiguration configuration,
        CancellationToken cancellationToken)
    {
        List<PulseVanished> due;
        lock (gate)
        {
            foreach (var item in active.Values.Where(predicate: item => item.Role == PRRole.Author && succeeded.Contains(item: item.PullRequest.Key.Organization)))
            {
                var key = item.PullRequest.Key;
                if (!listed.ContainsKey(key: key) && !completed.ContainsKey(key: key) && !vanished.ContainsKey(key: key))
                {
                    vanished[key] = new PulseVanished(PullRequest: item.PullRequest, Since: startedAt);
                }
            }
            // Back in the list, listed as completed, or gone longer than Done shows anything.
            RemoveWhere(dictionary: vanished, predicate: key => listed.ContainsKey(key: key) || completed.ContainsKey(key: key) || vanished[key].Since <= closedSince);
            due = vanished.Values
                .Where(predicate: item => succeeded.Contains(item: item.PullRequest.Key.Organization) && item.IsDue(date: startedAt, interval: configuration.Interval))
                .OrderBy(keySelector: item => item.LastLookup ?? DateTimeOffset.MinValue)
                .ThenBy(keySelector: item => item.Since)
                .ThenBy(keySelector: item => item.PullRequest.Key)
                .Take(count: VanishedPerRefresh)
                .ToList();
        }
        foreach (var item in due)
        {
            var key = item.PullRequest.Key;
            try
            {
                var dto = await client.GetAsync(url: ADOEndpoint.PullRequest(organization: key.Organization, id: key.Number), read: ADOPullRequest.Read, cancellationToken: cancellationToken)
                    .ConfigureAwait(continueOnCapturedContext: false);
                var fresh = PullRequest.From(organization: key.Organization, dto: dto);
                if (fresh.Status is PullRequestStatus.Completed or PullRequestStatus.Abandoned)
                {
                    completed[key] = fresh;
                }
                lock (gate)
                {
                    vanished.Remove(key: key);
                }
            }
            catch (ADOException error) when (error.Error.Kind is ADOErrorKind.NotFound or ADOErrorKind.Forbidden)
            {
                // Deleted, or moved somewhere you can't read: nothing to show.
                lock (gate)
                {
                    vanished.Remove(key: key);
                }
            }
            catch (ADOException error) when (error.Error.Kind == ADOErrorKind.Throttled)
            {
                break;
            }
            catch (ADOException error)
            {
                Log.Write(line: $"azureDevOps: a pull request that left the list couldn't be looked up, {error.Error.Kind}; trying again later");
                lock (gate)
                {
                    if (vanished.TryGetValue(key: key, value: out var current))
                    {
                        vanished[key] = current with { LastLookup = startedAt, Failures = current.Failures + 1 };
                    }
                }
            }
        }
    }

    /// Reads the pull requests sent to you or watched that aren't in your lists, ten a refresh: the ones never read first,
    /// then the ones read longest ago. Each stays listed as it was last read in between. One that's closed or couldn't be
    /// read is tried again an hour later.
    async Task AddLinkedAsync(Dictionary<PRKey, PulseListed> listed, DateTimeOffset date, CancellationToken cancellationToken)
    {
        List<PRKey> due;
        lock (gate)
        {
            var wanted = linkedKeys.Where(predicate: key => !listed.ContainsKey(key: key)).ToHashSet();
            RemoveWhere(dictionary: linked, predicate: key => !wanted.Contains(item: key));
            due = wanted
                .Where(predicate: key => !linkedFailures.TryGetValue(key: key, value: out var failed) || date - failed > linkedRetry)
                .OrderBy(keySelector: key => linked.TryGetValue(key: key, value: out var read) ? read.ReadAt : DateTimeOffset.MinValue)
                .ThenBy(keySelector: key => key)
                .Take(count: LinkedPerRefresh)
                .ToList();
        }
        foreach (var key in due)
        {
            try
            {
                string? me;
                lock (gate)
                {
                    me = identities.GetValueOrDefault(key: key.Organization);
                }
                if (me is null)
                {
                    me = (await client.GetAsync(url: ADOEndpoint.ConnectionData(organization: key.Organization), read: ADOConnectionData.Read, cancellationToken: cancellationToken)
                        .ConfigureAwait(continueOnCapturedContext: false)).AuthenticatedUser.Id.ToLowerInvariant();
                    lock (gate)
                    {
                        identities[key.Organization] = me;
                    }
                }
                var dto = await client.GetAsync(url: ADOEndpoint.PullRequest(organization: key.Organization, id: key.Number), read: ADOPullRequest.Read, cancellationToken: cancellationToken)
                    .ConfigureAwait(continueOnCapturedContext: false);
                var pr = PullRequest.From(organization: key.Organization, dto: dto);
                lock (gate)
                {
                    // A closed one is read again an hour later too, in case it's reopened.
                    if (pr.Status == PullRequestStatus.Active)
                    {
                        linkedFailures.Remove(key: key);
                    }
                    else
                    {
                        linkedFailures[key] = date;
                    }
                    if (pr.Status != PullRequestStatus.Active || !linkedKeys.Contains(item: key))
                    {
                        linked.Remove(key: key);
                        if (linkedKeys.Contains(item: key))
                        {
                            closedLinks.Add(item: key);
                        }
                        continue;
                    }
                    closedLinks.Remove(item: key);
                    var role = pr.Author.Id == me ? PRRole.Author : pr.FindReviewer(id: me) is not null ? PRRole.Reviewer : PRRole.Linked;
                    linked[key] = (new PulseListed(PullRequest: pr, Role: role), date);
                }
            }
            catch (ADOException error)
            {
                lock (gate)
                {
                    linkedFailures[key] = date;
                    // Gone, or no access: nothing to list. Otherwise it stays as last read.
                    if (error.Error.Kind is ADOErrorKind.NotFound or ADOErrorKind.Forbidden)
                    {
                        linked.Remove(key: key);
                        closedLinks.Add(item: key);
                    }
                }
            }
        }
        lock (gate)
        {
            foreach (var (key, read) in linked)
            {
                listed[key] = read.Listed;
            }
        }
    }

    /// Reads the details of `pullRequests`, `Concurrency` at a time. Returns the error when Azure DevOps asked BriefBar to
    /// slow down, after which nothing more is read.
    async Task<ADOError?> FetchDetailsAsync(List<PullRequest> pullRequests, PulseEngineConfiguration configuration, CancellationToken cancellationToken)
    {
        if (pullRequests.Count == 0)
        {
            return null;
        }
        var fetchedAt = time.GetUtcNow();
        ADOError? throttled = null;
        using var slots = new SemaphoreSlim(initialCount: Math.Max(val1: 1, val2: configuration.Concurrency));
        async Task Fetch(PullRequest pr)
        {
            await slots.WaitAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
            try
            {
                if (Volatile.Read(location: ref throttled) is not null)
                {
                    return;
                }
                var (policies, policiesError, threads, threadsError) = await DetailsAsync(pr: pr, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
                lock (gate)
                {
                    Keep(pr: pr, policies: policies, policiesError: policiesError, threads: threads, threadsError: threadsError, fetchedAt: fetchedAt, configuration: configuration);
                }
                var slowDown = policiesError?.Kind == ADOErrorKind.Throttled ? policiesError : threadsError?.Kind == ADOErrorKind.Throttled ? threadsError : null;
                if (slowDown is not null)
                {
                    Interlocked.CompareExchange(location1: ref throttled, value: slowDown, comparand: null);
                }
            }
            finally
            {
                slots.Release();
            }
        }
        await Task.WhenAll(tasks: pullRequests.Select(selector: Fetch)).ConfigureAwait(continueOnCapturedContext: false);
        return throttled;
    }

    /// What one read of `pr`'s details said: both read, or what could be. What its policies say now replaces what they
    /// said, even when its threads couldn't be read: a pull request whose policies you may no longer read, or whose build
    /// failed since, isn't ready. A read that failed is tried again on the usual schedule, rather than every refresh.
    void Keep(
        PullRequest pr,
        IReadOnlyList<ADOPolicyEvaluation>? policies,
        ADOError? policiesError,
        IReadOnlyList<ADOThread>? threads,
        ADOError? threadsError,
        DateTimeOffset fetchedAt,
        PulseEngineConfiguration configuration)
    {
        var key = pr.Key;
        if (policiesError is null && threadsError is null)
        {
            var fetched = PRDetails.From(fetchedAt: fetchedAt, pullRequest: pr, evaluations: policies, threads: threads!);
            details[key] = fetched;
            entries[key] = new RefreshPlannerEntry(
                FetchedAt: fetchedAt, Fingerprint: pr.Fingerprint, IsBusy: fetched.HasChecksInProgress, IsQuiet: IsQuiet(pr: pr, details: fetched, configuration: configuration, date: fetchedAt));
            return;
        }
        if (policiesError is null && details.TryGetValue(key: key, value: out var kept))
        {
            details[key] = kept with
            {
                Checks = new ValueList<Check>(items: (policies ?? []).Select(selector: Check.From).OfType<Check>()),
                ChecksKnown = policies is not null,
            };
        }
        var known = details.GetValueOrDefault(key: key);
        entries[key] = new RefreshPlannerEntry(
            FetchedAt: fetchedAt,
            Fingerprint: pr.Fingerprint,
            IsBusy: known?.HasChecksInProgress ?? false,
            IsQuiet: known is not null && IsQuiet(pr: pr, details: known, configuration: configuration, date: fetchedAt));
    }

    static bool IsQuiet(PullRequest pr, PRDetails details, PulseEngineConfiguration configuration, DateTimeOffset date)
    {
        if (pr.IsDraft)
        {
            return true;
        }
        if (configuration.InactiveAfter is not { } inactiveAfter || details.LastActivity is not { } last)
        {
            return false;
        }
        return date - (last > pr.CreatedAt ? last : pr.CreatedAt) > inactiveAfter;
    }

    /// The failed builds of your pull requests, as their policies report them now.
    HashSet<FailedBuild> FailedBuilds()
    {
        lock (gate)
        {
            var failed = new HashSet<FailedBuild>();
            foreach (var (key, item) in active.Where(predicate: pair => pair.Value.Role == PRRole.Author))
            {
                foreach (var check in details.GetValueOrDefault(key: key)?.Checks ?? [])
                {
                    if (check.FailedBuildId is { } buildId)
                    {
                        failed.Add(item: new FailedBuild(Organization: key.Organization, ProjectId: item.PullRequest.ProjectId, BuildId: buildId, CompletedAt: check.CompletedAt));
                    }
                }
            }
            return failed;
        }
    }

    /// An organization's lists: who you are there, the first time, then your active pull requests, those you review, and
    /// yours completed since `closedSince`, the three at once.
    async Task<(string Organization, PulseOrganizationLists? Lists, ADOError? Error)> ListsAsync(
        string organization, string? me, DateTimeOffset closedSince, CancellationToken cancellationToken)
    {
        try
        {
            string? name = null;
            if (me is null)
            {
                var user = (await client.GetAsync(url: ADOEndpoint.ConnectionData(organization: organization), read: ADOConnectionData.Read, cancellationToken: cancellationToken)
                    .ConfigureAwait(continueOnCapturedContext: false)).AuthenticatedUser;
                me = user.Id.ToLowerInvariant();
                name = user.ProviderDisplayName;
            }
            var mine = client.ListAsync(
                url: ADOEndpoint.PullRequests(organization: organization, status: "active", creatorId: me), read: ADOPullRequest.Read, cancellationToken: cancellationToken);
            var reviewing = client.ListAsync(
                url: ADOEndpoint.PullRequests(organization: organization, status: "active", reviewerId: me), read: ADOPullRequest.Read, cancellationToken: cancellationToken);
            var completed = client.ListAsync(
                url: ADOEndpoint.PullRequests(organization: organization, status: "completed", creatorId: me, closedSince: closedSince, top: 50),
                read: ADOPullRequest.Read,
                cancellationToken: cancellationToken);
            await Task.WhenAll(mine, reviewing, completed).ConfigureAwait(continueOnCapturedContext: false);
            IReadOnlyList<PullRequest> Convert(ADOList<ADOPullRequest> list) => list.Value.Select(selector: dto => PullRequest.From(organization: organization, dto: dto)).ToList();
            return (organization, new PulseOrganizationLists(Me: me, Name: name, Mine: Convert(list: mine.Result), Reviewing: Convert(list: reviewing.Result), Completed: Convert(list: completed.Result)), null);
        }
        catch (ADOException error)
        {
            return (organization, null, error.Error);
        }
    }

    /// `pr`'s policies and threads, read at once: either can fail while the other doesn't. Policies a project doesn't let
    /// you read are null, which isn't the same as having none: whether the pull request is ready is unknown.
    async Task<(IReadOnlyList<ADOPolicyEvaluation>? Policies, ADOError? PoliciesError, IReadOnlyList<ADOThread>? Threads, ADOError? ThreadsError)> DetailsAsync(
        PullRequest pr, CancellationToken cancellationToken)
    {
        var organization = pr.Key.Organization;
        var policies = Capture(read: client.ListAsync(
            url: ADOEndpoint.PolicyEvaluations(organization: organization, projectId: pr.ProjectId, pullRequestId: pr.Key.Number),
            read: ADOPolicyEvaluation.Read,
            cancellationToken: cancellationToken));
        var threads = Capture(read: client.ListAsync(
            url: ADOEndpoint.Threads(organization: organization, projectId: pr.ProjectId, repositoryId: pr.RepositoryId, pullRequestId: pr.Key.Number),
            read: ADOThread.Read,
            cancellationToken: cancellationToken));
        var (policyList, policyError) = await policies.ConfigureAwait(continueOnCapturedContext: false);
        var (threadList, threadError) = await threads.ConfigureAwait(continueOnCapturedContext: false);
        if (policyError?.Kind is ADOErrorKind.Forbidden or ADOErrorKind.NotFound)
        {
            return (null, null, threadList?.Value, threadError);
        }
        return (policyList?.Value, policyError, threadList?.Value, threadError);
    }

    static async Task<(ADOList<T>? List, ADOError? Error)> Capture<T>(Task<ADOList<T>> read)
        where T : class
    {
        try
        {
            return (await read.ConfigureAwait(continueOnCapturedContext: false), null);
        }
        catch (ADOException error)
        {
            return (null, error.Error);
        }
    }

    TimeSpan NextDelay()
    {
        lock (gate)
        {
            var interval = configuration.Interval;
            switch (problem?.Kind)
            {
                case PulseProblemKind.Throttled:
                    var wait = (problem.Until ?? time.GetUtcNow()) - time.GetUtcNow();
                    return wait > interval ? wait : interval;
                case PulseProblemKind.CliNotFound or PulseProblemKind.SignedOut or PulseProblemKind.AuthFailed:
                    // Picks up an `az login` within a minute: asking the CLI costs nothing on the network.
                    return interval < TimeSpan.FromMinutes(value: 1) ? interval : TimeSpan.FromMinutes(value: 1);
                default:
                    if (failures == 0)
                    {
                        return interval;
                    }
                    var seconds = interval.TotalSeconds * Math.Pow(x: 2, y: Math.Min(val1: failures, val2: 4));
                    return TimeSpan.FromSeconds(value: Math.Min(val1: seconds, val2: 600));
            }
        }
    }

    /// Without organizations to watch or pull requests sent to you, there's nothing to read, or to list. Under the lock.
    void ListNothing()
    {
        active = [];
        done = [];
        details.Clear();
        entries.Clear();
        vanished.Clear();
        linked.Clear();
        closedLinks.Clear();
        builds.Forget();
        merges.Forget();
        problem = PulseProblem.NoOrganizations;
        hasLoaded = true;
    }

    /// Someone else signed in: everything read as the last one goes. Under the lock.
    void ForgetAccount()
    {
        identities.Clear();
        userName = null;
        firstLoaded.Clear();
        active = [];
        done = [];
        details.Clear();
        entries.Clear();
        vanished.Clear();
        linkedFailures.Clear();
        linked.Clear();
        closedLinks.Clear();
        builds.Forget();
        merges.Forget();
    }

    /// What it knows now. Under the lock.
    PulseSnapshot Snapshot()
    {
        var now = time.GetUtcNow();
        var records = active.Select(selector: pair => new PRRecord(
                pullRequest: pair.Value.PullRequest,
                role: pair.Value.Role,
                me: identities.GetValueOrDefault(key: pair.Key.Organization) ?? string.Empty,
                details: builds.WithFailures(details: details.GetValueOrDefault(key: pair.Key), pr: pair.Value.PullRequest)))
            .Concat(second: done.Select(selector: pair => new PRRecord(
                pullRequest: pair.Value,
                role: PRRole.Author,
                me: identities.GetValueOrDefault(key: pair.Key.Organization) ?? string.Empty,
                merge: merges.Pipelines(pr: pair.Value, now: now))))
            .OrderBy(keySelector: record => record.Id);
        return new PulseSnapshot
        {
            Records = new ValueList<PRRecord>(items: records),
            Organizations = configuration.Organizations,
            Account = account,
            UserName = userName,
            FirstLoaded = new Dictionary<string, DateTimeOffset>(collection: firstLoaded, comparer: StringComparer.Ordinal),
            Problem = problem,
            RefreshedAt = refreshedAt,
            IsRefreshing = isRefreshing,
            HasLoaded = hasLoaded,
            ClosedLinks = new HashSet<PRKey>(collection: closedLinks),
        };
    }

    /// Hands what it knows to `onChange`, if that changed since it last did.
    void Publish()
    {
        lock (publishing)
        {
            PulseSnapshot current;
            lock (gate)
            {
                current = Snapshot();
            }
            if (current.Equals(other: lastPublished))
            {
                return;
            }
            lastPublished = current;
            onChange(obj: current);
        }
    }
}
