using BriefBar.Core.Demo;
using BriefBar.Core.GitHub;
using BriefBar.Core.Presentation;
using BriefBar.Core.Settings;

namespace BriefBar.Core.Tests.GitHub;

/// What the GitHub section shows: its rows, groups, brief, notices, who it reads as, how it stands and what its panel can
/// do, as the Mac's popover shows them.
public sealed class GitHubRowsTests
{
    static readonly DateTimeOffset now = TestTimes.Reference;

    /// A store that read `load`, the demo's unless said, or failed with `error` after it.
    static GitHubStore Store(GitHubLoad? load = null, GitHubError? error = null, bool read = true)
    {
        var store = new GitHubStore(settings: new GitHubSettings(settings: new MemorySettings()));
        store.Start();
        store.BeginRefresh(now: now);
        if (read)
        {
            store.Receive(load: load ?? GitHubDemoData.Load(now: now), now: now);
        }
        if (error is not null)
        {
            store.Fail(error: error, now: now);
        }
        return store;
    }

    [Fact]
    public void ARowSaysWhyItIsWhereItIs()
    {
        var item = GitHubDemoData.Load(now: now).Items.First(predicate: item => item.PullRequest.Number == 412);
        var row = GitHubRows.Row(item: item);
        Assert.Equal(expected: item.Id, actual: row.Id);
        Assert.Equal(expected: SectionId.GitHubPullRequests, actual: row.Section);
        Assert.Equal(expected: "toReview", actual: row.Group);
        Assert.Equal(expected: ItemState.NeedsYou, actual: row.State);
        Assert.Equal(expected: IconKey.Eye, actual: row.Icon);
        Assert.Equal(expected: "Add dark mode to the checkout page", actual: row.Title);
        Assert.Equal(expected: "Review requested · By priya", actual: row.Status);
        Assert.Equal(expected: "contoso/shop-web#412", actual: row.Detail);
        Assert.Equal(expected: now.AddMinutes(minutes: -25), actual: row.Date);
        var open = Assert.Single(collection: row.Commands);
        Assert.Equal(expected: new PanelCommand(Key: GitHubCommands.Open, Title: "Open on GitHub", Opens: true), actual: open);
        Assert.Equal(
            expected: "Add dark mode to the checkout page\ncontoso/shop-web#412\nReview requested · By priya\nClick to open on GitHub",
            actual: row.ToolTip);
        // Narrator says it all, in words.
        Assert.Equal(
            expected: "Add dark mode to the checkout page, Review requested, By priya, contoso/shop-web#412, 25 minutes ago",
            actual: RowWords.SpokenName(row: row, sourceName: null, now: now));
        // Until you've signed in, it isn't counted.
        Assert.Null(@object: GitHubRows.Row(item: item, counted: false).State);
    }

    [Fact]
    public void EachReasonHasTheMacsIcon()
    {
        Assert.Equal(expected: IconKey.Eye, actual: GitHubRows.Icon(reason: GitHubPRReason.ReviewRequested));
        Assert.Equal(expected: IconKey.ArrowReply, actual: GitHubRows.Icon(reason: GitHubPRReason.ChangesRequested));
        Assert.Equal(expected: IconKey.DismissCircle, actual: GitHubRows.Icon(reason: GitHubPRReason.ChecksFailed));
        Assert.Equal(expected: IconKey.Warning, actual: GitHubRows.Icon(reason: GitHubPRReason.Conflicts));
        Assert.Equal(expected: IconKey.CheckmarkCircle, actual: GitHubRows.Icon(reason: GitHubPRReason.Approved));
        Assert.Equal(expected: IconKey.HourglassHalf, actual: GitHubRows.Icon(reason: GitHubPRReason.ChecksRunning));
        Assert.Equal(expected: IconKey.Edit, actual: GitHubRows.Icon(reason: GitHubPRReason.Draft));
        Assert.Equal(expected: IconKey.Clock, actual: GitHubRows.Icon(reason: GitHubPRReason.WaitingForReview));
    }

    /// The Mac's groups, in its order, colored by the state each counts in; Waiting counts in none, and its rows aren't
    /// counted, as the Mac's menu bar doesn't count them.
    [Fact]
    public void ShowsTheMacsGroupsInItsOrder()
    {
        var snapshot = GitHubRows.Snapshot(store: Store());
        Assert.Equal(expected: ["toReview", "changesRequested", "failing", "ready", "waiting"], actual: snapshot.Groups.Select(selector: group => group.Key));
        Assert.Equal(expected: ["To review", "Changes requested", "Failing", "Ready to merge", "Waiting"], actual: snapshot.Groups.Select(selector: group => group.Title));
        Assert.Equal(
            expected: [ItemState.NeedsYou, ItemState.NeedsYou, ItemState.Failing, ItemState.Done, null],
            actual: snapshot.Groups.Select(selector: group => group.State));
        Assert.All(collection: snapshot.Groups, action: group =>
        {
            Assert.Empty(collection: group.Commands);
            Assert.False(condition: group.IsFolded);
        });
        Assert.All(collection: snapshot.Rows.Where(predicate: row => row.Group == "waiting"), action: row => Assert.Null(@object: row.State));
        Assert.Equal(expected: new StateCounts(NeedsYou: 3, Failing: 2, Done: 1), actual: snapshot.Counts);
        Assert.Equal(expected: 6, actual: snapshot.BriefLines.Count);
        Assert.Equal(expected: PanelLists.ForSection(snapshot: snapshot).Sum(selector: group => group.Rows.Count), actual: snapshot.Rows.Count);
        Assert.Equal(expected: SectionStatus.Updated(time: now), actual: snapshot.Status);
        Assert.Null(@object: snapshot.Quiet);
        Assert.Empty(collection: snapshot.Notices);
    }

    [Fact]
    public void SaysAllIsQuietWithNoOpenPullRequests()
    {
        var snapshot = GitHubRows.Snapshot(store: Store(load: new GitHubLoad(Login: GitHubFixture.Me, Items: [])));
        Assert.Equal(expected: new QuietNote(Title: "All quiet", Detail: "No open pull requests for you"), actual: snapshot.Quiet);
        Assert.Empty(collection: snapshot.Rows);
        // Not when it couldn't read: the list may not be empty.
        Assert.Null(@object: GitHubRows.Snapshot(store: Store(read: false, error: GitHubError.Offline)).Quiet);
        // Nor when GitHub couldn't read some of them, or there are more than it read.
        var empty = new GitHubLoad(Login: GitHubFixture.Me, Items: []);
        Assert.Null(@object: GitHubRows.Snapshot(store: Store(load: empty with { Notice = "Some pull requests couldn't be read: made-up error." })).Quiet);
        Assert.Null(@object: GitHubRows.Snapshot(store: Store(load: empty with { MoreThanShown = true })).Quiet);
        // Nor before it has.
        Assert.Null(@object: GitHubRows.Snapshot(store: Store(read: false)).Quiet);
    }

    /// What GitHub couldn't read, and that there's more on GitHub than BriefBar reads, beside the list.
    [Fact]
    public void SaysWhatItCouldntReadAndThatThereIsMore()
    {
        var load = GitHubDemoData.Load(now: now) with
        {
            Notice = "Some organizations use single sign-on: authorize the GitHub CLI for them to see their pull requests.",
            MoreThanShown = true,
        };
        var snapshot = GitHubRows.Snapshot(store: Store(load: load));
        Assert.Equal(expected: 2, actual: snapshot.Notices.Count);
        Assert.Equal(expected: new SectionNotice(Message: load.Notice), actual: snapshot.Notices[0]);
        Assert.Equal(
            expected: "There are more on GitHub: BriefBar shows your 50 most recently changed pull requests of each kind.",
            actual: snapshot.Notices[1].Message);
        Assert.Equal(expected: GitHubCommands.MoreOnGitHub, actual: snapshot.Notices[1].Command?.Key);
        Assert.Equal(expected: "More on GitHub", actual: snapshot.Notices[1].Command?.Title);
        Assert.True(condition: snapshot.Notices[1].Command?.Opens == true);
        // What it read is the whole story otherwise: it isn't a problem.
        Assert.Equal(expected: SectionCondition.Ready, actual: snapshot.Status.Condition);
    }

    [Fact]
    public void SaysWhoItReadsAs()
    {
        Assert.Equal(
            expected: new SectionAccount(Name: GitHubDemoData.Login, Help: "Signed in to the GitHub CLI as " + GitHubDemoData.Login),
            actual: GitHubRows.Snapshot(store: Store()).Account);
        Assert.Null(@object: GitHubRows.Snapshot(store: Store(read: false)).Account);
    }

    /// Its foot opens GitHub, and, once it has read, reads again from an icon beside Settings.
    [Fact]
    public void ItsFootOpensGitHubAndRefreshes()
    {
        var starting = GitHubRows.Snapshot(store: Store(read: false));
        Assert.Equal(expected: SectionStatus.Starting, actual: starting.Status);
        Assert.Equal(expected: "Loading your pull requests…", actual: starting.EmptyText);
        Assert.Equal(
            expected: [new PanelCommand(Key: GitHubCommands.OpenGitHub, Title: "Open GitHub", Help: "Your pull requests on GitHub", Opens: true)],
            actual: starting.Commands);

        var loaded = GitHubRows.Snapshot(store: Store());
        Assert.Null(@object: loaded.EmptyText);
        Assert.Equal(expected: [GitHubCommands.OpenGitHub, GitHubCommands.Refresh], actual: loaded.Commands.Select(selector: command => command.Key));
        var refresh = loaded.Commands[1];
        Assert.True(condition: refresh.IconOnly);
        Assert.Equal(expected: IconKey.ArrowSync, actual: refresh.Icon);
        Assert.False(condition: refresh.Opens);
    }

    /// Each problem in a word or two for the bar, in a sentence for the panel, and with what fixes it.
    [Fact]
    public void SaysWhatsWrongAndWhatFixesIt()
    {
        (GitHubError Error, bool HadRead, SectionCondition Condition, string Short, string? Command)[] cases =
        [
            (GitHubError.FromAuth(error: GitHubAuthError.CliNotFound), true, SectionCondition.Problem, "Needs gh", GitHubCommands.InstallCli),
            (GitHubError.FromAuth(error: GitHubAuthError.SignedOut(message: "not logged in")), true, SectionCondition.Problem, "Sign in", GitHubCommands.SignIn),
            (GitHubError.Unauthorized, true, SectionCondition.Problem, "Sign in", GitHubCommands.SignIn),
            (GitHubError.FromAuth(error: GitHubAuthError.Failed(message: "boom")), true, SectionCondition.Stale, "Can't sign in", GitHubCommands.Refresh),
            (GitHubError.Offline, true, SectionCondition.Stale, "Offline", GitHubCommands.Refresh),
            (GitHubError.Offline, false, SectionCondition.Problem, "Offline", GitHubCommands.Refresh),
            (GitHubError.Throttled(retryAfter: TimeSpan.FromMinutes(value: 10)), true, SectionCondition.Stale, "Slowed down", null),
            (GitHubError.Http(status: 502), true, SectionCondition.Stale, "Can't refresh", GitHubCommands.Refresh),
            (GitHubError.Http(status: 502), false, SectionCondition.Problem, "Can't read", GitHubCommands.Refresh),
        ];
        foreach (var (error, hadRead, condition, shortProblem, command) in cases)
        {
            var store = Store(read: hadRead, error: error);
            var snapshot = GitHubRows.Snapshot(store: store);
            Assert.Equal(expected: condition, actual: snapshot.Status.Condition);
            Assert.Equal(expected: shortProblem, actual: snapshot.Status.ShortProblem);
            Assert.Equal(expected: store.Problem!.Message, actual: snapshot.Status.Problem);
            Assert.Equal(expected: command, actual: snapshot.ProblemCommand?.Key);
            Assert.Equal(expected: hadRead ? now : (DateTimeOffset?)null, actual: snapshot.Status.UpdatedAt);
        }
        Assert.Equal(expected: "Install the GitHub CLI…", actual: GitHubRows.Snapshot(store: Store(error: GitHubError.FromAuth(error: GitHubAuthError.CliNotFound))).ProblemCommand?.Title);
        Assert.Equal(expected: "Sign in…", actual: GitHubRows.Snapshot(store: Store(error: GitHubError.Unauthorized)).ProblemCommand?.Title);
        Assert.Equal(expected: "Try again", actual: GitHubRows.Snapshot(store: Store(error: GitHubError.Offline)).ProblemCommand?.Title);
    }

    /// The demo's section, as `DemoData` makes it, through the real store.
    [Fact]
    public void TheDemoShowsItsMadeUpPullRequests()
    {
        var snapshot = DemoData.GitHubPullRequests(now: now);
        Assert.Equal(expected: Sections.GitHubPullRequests, actual: snapshot.Info);
        Assert.Equal(expected: new StateCounts(NeedsYou: 3, Failing: 2, Done: 1), actual: snapshot.Counts);
        Assert.Equal(expected: 8, actual: snapshot.Rows.Count);
        Assert.Equal(expected: GitHubDemoData.Login, actual: snapshot.Account?.Name);
    }
}
