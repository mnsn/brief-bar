using BriefBar.Core.Demo;
using BriefBar.Core.GitHub;
using BriefBar.Core.Settings;

namespace BriefBar.Core.Tests.GitHub;

/// The list as the last read found it, and when to read again: the Swift tests' `StoreTests` and `SettingsTests`, for the
/// store's part; reading is `GitHubSource`'s (`GitHubSourceTests`).
public sealed class StoreTests
{
    static readonly DateTimeOffset started = TestTimes.Reference;

    static GitHubStore Store(GitHubSettings? settings = null) => new(settings: settings ?? new GitHubSettings(settings: new MemorySettings()));

    /// A store that has read the made-up pull requests.
    static GitHubStore Loaded(GitHubSettings? settings = null)
    {
        var store = Store(settings: settings);
        store.Start();
        Assert.True(condition: store.BeginRefresh(now: started));
        store.Receive(load: GitHubDemoData.Load(now: started), now: started);
        return store;
    }

    [Fact]
    public void ReceivesWhatAReadFound()
    {
        var store = Loaded();
        Assert.True(condition: store.HasLoaded);
        Assert.False(condition: store.IsRefreshing);
        Assert.Equal(expected: GitHubDemoData.Login, actual: store.Login);
        Assert.Equal(expected: 8, actual: store.Items.Count);
        Assert.Equal(expected: new StateCounts(NeedsYou: 3, Failing: 2, Done: 1), actual: store.Counts.States);
        Assert.Equal(expected: started, actual: store.RefreshedAt);
        Assert.Null(@object: store.Problem);
    }

    [Fact]
    public void StopForgetsEverything()
    {
        var store = Loaded();
        store.Fail(error: GitHubError.Offline, now: started);
        store.Stop();

        Assert.False(condition: store.IsStarted);
        Assert.False(condition: store.HasLoaded);
        Assert.Empty(collection: store.Items);
        Assert.Equal(expected: new GitHubGroupCounts(), actual: store.Counts);
        Assert.Null(@object: store.Problem);
        Assert.Null(@object: store.Login);
        Assert.Null(@object: store.Notice);
        Assert.False(condition: store.MoreThanShown);
        Assert.Null(@object: store.RefreshedAt);
        Assert.True(condition: store.IsStale(date: started));
    }

    [Fact]
    public void NothingReadsBeforeItStarts()
    {
        var store = Store();
        Assert.False(condition: store.IsDue(date: started));
        Assert.False(condition: store.BeginRefresh(now: started));
        Assert.False(condition: store.IsRefreshing);
    }

    /// One read at a time.
    [Fact]
    public void ReadsOnceAtATime()
    {
        var store = Store();
        store.Start();
        Assert.True(condition: store.IsDue(date: started));
        Assert.True(condition: store.BeginRefresh(now: started));
        Assert.True(condition: store.IsRefreshing);
        Assert.False(condition: store.BeginRefresh(now: started.AddMinutes(minutes: 5)));
        store.Fail(error: GitHubError.Http(status: 502), now: started);
        Assert.False(condition: store.IsRefreshing);
        Assert.True(condition: store.BeginRefresh(now: started.AddMinutes(minutes: 5)));
    }

    /// While you need to sign in or you're offline, it tries again every minute, so that a fix shows soon.
    [Fact]
    public void TriesAgainEveryMinuteWhileThereIsSomethingToFix()
    {
        GitHubError[] fixable =
        [
            GitHubError.FromAuth(error: GitHubAuthError.CliNotFound),
            GitHubError.FromAuth(error: GitHubAuthError.SignedOut(message: "not logged in")),
            GitHubError.FromAuth(error: GitHubAuthError.Failed(message: "boom")),
            GitHubError.Unauthorized,
            GitHubError.Offline,
        ];
        foreach (var error in fixable)
        {
            var store = Store();
            store.Start();
            store.BeginRefresh(now: started);
            store.Fail(error: error, now: started);
            Assert.False(condition: store.IsDue(date: started.AddSeconds(seconds: 30)));
            Assert.True(condition: store.IsDue(date: started.AddSeconds(seconds: 61)));
        }
    }

    [Fact]
    public void OtherwiseReadsAsOftenAsSet()
    {
        var settings = new GitHubSettings(settings: new MemorySettings());
        var store = Store(settings: settings);
        store.Start();
        store.BeginRefresh(now: started);
        store.Fail(error: GitHubError.Http(status: 502), now: started);
        Assert.False(condition: store.IsDue(date: started.AddSeconds(seconds: 61)));
        Assert.True(condition: store.IsDue(date: started.AddSeconds(seconds: 121)));

        settings.RefreshMinutes = 5;
        Assert.False(condition: store.IsDue(date: started.AddSeconds(seconds: 121)));
        Assert.True(condition: store.IsDue(date: started.AddSeconds(seconds: 301)));

        // A quicker choice than a minute's retries doesn't slow them.
        settings.RefreshMinutes = 1;
        store.Fail(error: GitHubError.Offline, now: started);
        Assert.True(condition: store.IsDue(date: started.AddSeconds(seconds: 61)));
    }

    [Fact]
    public void WaitsAsLongAsGitHubAsked()
    {
        var store = Store();
        store.Start();
        store.BeginRefresh(now: started);
        store.Fail(error: GitHubError.Throttled(retryAfter: TimeSpan.FromMinutes(value: 10)), now: started);
        Assert.False(condition: store.IsDue(date: started.AddMinutes(minutes: 5)));
        Assert.False(condition: store.BeginRefresh(now: started.AddMinutes(minutes: 5)));
        Assert.True(condition: store.IsDue(date: started.AddSeconds(seconds: 601)));
        Assert.True(condition: store.BeginRefresh(now: started.AddSeconds(seconds: 601)));
    }

    [Fact]
    public void APanelOpeningReadsAgainOnlyAfterAWhile()
    {
        var store = Store();
        store.Start();
        Assert.True(condition: store.IsStale(date: started));
        store.BeginRefresh(now: started);
        Assert.False(condition: store.IsStale(date: started.AddSeconds(seconds: 9)));
        Assert.True(condition: store.IsStale(date: started.AddSeconds(seconds: 10)));
    }

    /// Signed out, or as someone else: the list was theirs.
    [Fact]
    public void SigningOutClearsTheList()
    {
        GitHubError[] signedOut = [GitHubError.FromAuth(error: GitHubAuthError.SignedOut(message: "not logged in")), GitHubError.FromAuth(error: GitHubAuthError.CliNotFound), GitHubError.Unauthorized];
        foreach (var error in signedOut)
        {
            var store = Loaded();
            store.Fail(error: error, now: started);
            Assert.True(condition: store.Problem!.NeedsSignIn);
            Assert.Empty(collection: store.Items);
            Assert.Equal(expected: new GitHubGroupCounts(), actual: store.Counts);
            Assert.Null(@object: store.Login);
        }
    }

    [Fact]
    public void OtherProblemsKeepTheLastList()
    {
        var store = Loaded();
        GitHubError[] errors = [GitHubError.Offline, GitHubError.Http(status: 500), GitHubError.Throttled(retryAfter: TimeSpan.FromMinutes(value: 1))];
        foreach (var error in errors)
        {
            store.Fail(error: error, now: started);
            Assert.NotNull(@object: store.Problem);
            Assert.Equal(expected: 8, actual: store.Items.Count);
            Assert.Equal(expected: GitHubDemoData.Login, actual: store.Login);
            Assert.Equal(expected: started, actual: store.RefreshedAt);
        }

        store.Receive(load: GitHubDemoData.Load(now: started), now: started.AddMinutes(minutes: 2));
        Assert.Null(@object: store.Problem);
        Assert.Equal(expected: started.AddMinutes(minutes: 2), actual: store.RefreshedAt);
    }

    [Fact]
    public void GroupsTheList()
    {
        var store = Loaded();
        foreach (var group in GitHubPRGroups.All)
        {
            Assert.Equal(expected: store.Counts[group], actual: store.ItemsIn(group: group).Count);
            Assert.All(collection: store.ItemsIn(group: group), action: item => Assert.Equal(expected: group, actual: item.Group));
        }
    }

    [Fact]
    public void ReadsEveryTwoMinutesAtFirst()
    {
        var settings = new GitHubSettings(settings: new MemorySettings());
        Assert.Equal(expected: 2, actual: settings.RefreshMinutes);
        Assert.Equal(expected: TimeSpan.FromMinutes(value: 2), actual: settings.RefreshInterval);
    }

    [Fact]
    public void RemembersTheChoice()
    {
        var storage = new MemorySettings();
        new GitHubSettings(settings: storage).RefreshMinutes = 5;
        Assert.Equal(expected: 5, actual: storage.Number(key: GitHubSettings.RefreshMinutesKey));
        Assert.Equal(expected: 5, actual: new GitHubSettings(settings: storage).RefreshMinutes);
        Assert.Equal(expected: TimeSpan.FromMinutes(value: 5), actual: new GitHubSettings(settings: storage).RefreshInterval);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(3)]
    [InlineData(-1)]
    [InlineData(1_000)]
    public void AChoiceItDoesntOfferIsTheDefault(int saved)
    {
        var storage = new MemorySettings();
        storage.SetNumber(key: GitHubSettings.RefreshMinutesKey, value: saved);
        var settings = new GitHubSettings(settings: storage);
        Assert.Equal(expected: GitHubSettings.DefaultRefreshMinutes, actual: settings.RefreshMinutes);
        // Nor can it be chosen.
        settings.RefreshMinutes = saved;
        Assert.Equal(expected: GitHubSettings.DefaultRefreshMinutes, actual: settings.RefreshMinutes);
    }

    [Fact]
    public void EveryChoiceIsAtLeastAMinute()
    {
        Assert.Equal(expected: [1, 2, 5, 15], actual: GitHubSettings.RefreshChoices);
        Assert.Contains(expected: GitHubSettings.DefaultRefreshMinutes, collection: GitHubSettings.RefreshChoices);
        Assert.Equal(
            expected: ["Every minute", "Every 2 minutes", "Every 5 minutes", "Every 15 minutes"],
            actual: GitHubSettings.RefreshChoices.Select(selector: GitHubSettings.RefreshTitle));
    }
}
