using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Demo;
using BriefBar.Core.Presentation;
using BriefBar.Core.Settings;

namespace BriefBar.Core.Tests.AzureDevOps;

/// What the pull requests' section shows: the bar counts what its rows' states say, as the Mac's `StateRowsTests`, its
/// brief says the same pull requests, and its panel says how it stands, with the demo's made-up pull requests.
public sealed class AzureDevOpsRowsTests
{
    static readonly DateTimeOffset now = TestTimes.T(seconds: 0);

    [Fact]
    public void CountsWhatItsRowsSayByState()
    {
        var (store, settings) = LoadDemo();
        var snapshot = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        Assert.Equal(expected: new StateCounts(NeedsYou: 3, Failing: 2, Done: 2), actual: snapshot.Counts);
        Assert.Equal(expected: store.Counts.States(showToReview: false), actual: snapshot.Counts);
        Assert.Equal(expected: snapshot.Rows.Count, actual: snapshot.Rows.Select(selector: row => row.Id).Distinct().Count());
        Assert.Equal(expected: SectionStatus.Updated(time: now.AddSeconds(seconds: -20)), actual: snapshot.Status);

        // To review joins what needs you only while the bar shows it.
        settings.ShowToReview = true;
        var withToReview = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        Assert.Equal(expected: new StateCounts(NeedsYou: 4, Failing: 2, Done: 2), actual: withToReview.Counts);
        Assert.Equal(expected: ItemState.NeedsYou, actual: withToReview.Groups.Single(predicate: group => group.Key == "toReview").State);
    }

    [Fact]
    public void SaysTheSamePullRequestsInTheBrief()
    {
        var (store, settings) = LoadDemo();
        var snapshot = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        var counts = snapshot.BriefLines.Aggregate(seed: new StateCounts(), func: (sum, line) => sum.Adding(state: line.State, count: 1));
        Assert.Equal(expected: snapshot.Counts, actual: counts);
        Assert.Equal(expected: snapshot.BriefLines.Count, actual: snapshot.BriefLines.Select(selector: line => line.Id).Distinct().Count());
        Assert.All(collection: snapshot.BriefLines, action: line =>
        {
            Assert.Equal(expected: SectionId.AzureDevOpsPullRequests, actual: line.Section);
            Assert.Contains(collection: snapshot.Rows, filter: row => row.Id == line.Id && row.State == line.State);
            Assert.NotEmpty(collection: line.Sentence);
        });
        Assert.Contains(collection: snapshot.BriefLines, filter: line => line.Sentence == "Sam Rivera replied on “Add retry with backoff to the payments client”.");
    }

    /// The Mac's groups, in its order: Needs you's Mark as seen while something there is new, Done's Clear, Idle folded.
    [Fact]
    public void ShowsTheMacsGroups()
    {
        var (store, settings) = LoadDemo();
        var snapshot = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        Assert.Equal(
            expected: ["needsYou", "answered", "failing", "ready", "toReview", "waiting", "done", "idle"],
            actual: snapshot.Groups.Select(selector: group => group.Key));
        Assert.Equal(
            expected: ["Needs you", "Answered", "Failing", "Ready to complete", "To review", "Waiting", "Done", "Idle"],
            actual: snapshot.Groups.Select(selector: group => group.Title));
        Assert.Equal(expected: AzureDevOpsCommands.MarkAsSeen, actual: Group(snapshot: snapshot, key: "needsYou").Commands.Single().Key);
        Assert.Equal(expected: AzureDevOpsCommands.Clear, actual: Group(snapshot: snapshot, key: "done").Commands.Single().Key);
        Assert.True(condition: Group(snapshot: snapshot, key: "idle").IsFolded);
        Assert.DoesNotContain(collection: snapshot.Groups, filter: group => group.Key != "idle" && group.IsFolded);
        // Its foot opens Azure DevOps, and refreshes from an icon beside Settings, as the Mac's does.
        Assert.Equal(
            expected: [(AzureDevOpsCommands.OpenAzureDevOps, false), (AzureDevOpsCommands.Refresh, true)],
            actual: snapshot.Commands.Select(selector: command => (command.Key, command.IconOnly)));
        Assert.Equal(expected: "Refresh now", actual: snapshot.Commands[1].Help);

        // Seen, Needs you has nothing new to mark.
        store.Clear(group: PRGroup.NeedsYou, now: now);
        store.Recompute(now: now);
        Assert.Empty(collection: Group(snapshot: AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now), key: "needsYou").Commands);
    }

    /// A row: its reason's icon, where it stands and where, what's new, and what opening and its menu do.
    [Fact]
    public void ShowsEachPullRequestOnARow()
    {
        var (store, settings) = LoadDemo();
        var snapshot = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        var replied = Row(snapshot: snapshot, number: 4102);
        Assert.Equal(expected: IconKey.ArrowReply, actual: replied.Icon);
        Assert.Equal(expected: "Add retry with backoff to the payments client", actual: replied.Title);
        Assert.Equal(expected: "Sam Rivera replied · payments-api", actual: replied.Status);
        Assert.StartsWith(expectedStartString: "Could we cap the backoff", actualString: replied.Detail, comparisonType: StringComparison.Ordinal);
        Assert.False(condition: replied.IsNew);
        Assert.Equal(expected: [AzureDevOpsCommands.Open, AzureDevOpsCommands.RemoveFromNeedsYou], actual: replied.Commands.Select(selector: command => command.Key));
        Assert.True(condition: replied.Commands[0].Opens);
        Assert.Contains(expectedSubstring: "You've seen it", actualString: replied.ToolTip, comparisonType: StringComparison.Ordinal);

        var mentioned = Row(snapshot: snapshot, number: 4097);
        Assert.True(condition: mentioned.IsNew);
        Assert.Equal(expected: IconKey.Mention, actual: mentioned.Icon);

        var failing = Row(snapshot: snapshot, number: 4088);
        Assert.Equal(expected: ItemState.Failing, actual: failing.State);
        Assert.Equal(expected: [AzureDevOpsCommands.Open], actual: failing.Commands.Select(selector: command => command.Key));

        var idle = Row(snapshot: snapshot, number: 3990);
        Assert.Null(@object: idle.State);
        Assert.Equal(expected: "idle", actual: idle.Group);
    }

    /// Every reason has an icon of its own kind.
    [Fact]
    public void HasAnIconForEveryReason()
    {
        Assert.All(collection: Enum.GetValues<PRReason>(), action: reason => AzureDevOpsRows.Icon(reason: reason));
    }

    /// A pull request you watch can be unwatched from its menu.
    [Fact]
    public void OffersToStopWatching()
    {
        var (store, settings) = LoadDemo();
        settings.Watch(link: new PullRequestLink(Organization: AzureDevOpsDemoData.Organization, Project: "Storefront", Repository: "search", Number: 4071));
        store.Recompute(now: now);
        var watched = Row(snapshot: AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now), number: 4071);
        Assert.Equal(expected: [AzureDevOpsCommands.Open, AzureDevOpsCommands.StopWatching], actual: watched.Commands.Select(selector: command => command.Key));
        Assert.Contains(expectedSubstring: "You watch it", actualString: watched.ToolTip, comparisonType: StringComparison.Ordinal);
    }

    /// Until you've signed in, what it lists may be someone else's: nothing's counted, nor in the brief, and the bar says
    /// to sign in, which the banner offers.
    [Fact]
    public void AsksYouToSignInWithoutCountingAnything()
    {
        var (store, settings) = LoadDemo();
        store.Receive(snapshot: AzureDevOpsDemoData.Snapshot(now: now) with { Problem = new PulseProblem(Kind: PulseProblemKind.SignedOut) }, now: now);
        var snapshot = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        Assert.Equal(expected: new StateCounts(), actual: snapshot.Counts);
        Assert.Empty(collection: snapshot.BriefLines);
        Assert.NotEmpty(collection: snapshot.Rows);
        Assert.Equal(expected: SectionCondition.Problem, actual: snapshot.Status.Condition);
        Assert.Equal(expected: "Sign in", actual: snapshot.Status.ShortProblem);
        Assert.Equal(expected: "Sign in to the Azure CLI to see your pull requests.", actual: snapshot.Status.Problem);
        Assert.Equal(expected: AzureDevOpsCommands.SignIn, actual: snapshot.ProblemCommand?.Key);
        // Once you've signed in, it can read again at once.
        Assert.Contains(collection: snapshot.Commands, filter: command => command.Key == AzureDevOpsCommands.Refresh);

        store.Receive(snapshot: AzureDevOpsDemoData.Snapshot(now: now) with { Problem = PulseProblem.CliNotFound }, now: now);
        var withoutCli = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        Assert.Equal(expected: AzureDevOpsCommands.InstallCli, actual: withoutCli.ProblemCommand?.Key);
        Assert.True(condition: withoutCli.ProblemCommand?.Opens);
    }

    /// It couldn't read Azure DevOps this time: what it read before stays, out of date, with a way to try again.
    [Fact]
    public void KeepsWhatItReadWhenItCantReadAgain()
    {
        var (store, settings) = LoadDemo();
        var problem = new PulseProblem(Kind: PulseProblemKind.Unreachable, Detail: "Azure DevOps didn't answer in time.");
        store.Receive(snapshot: AzureDevOpsDemoData.Snapshot(now: now) with { Problem = problem }, now: now);
        var snapshot = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        Assert.Equal(expected: SectionCondition.Stale, actual: snapshot.Status.Condition);
        Assert.Equal(expected: new StateCounts(NeedsYou: 3, Failing: 2, Done: 2), actual: snapshot.Counts);
        Assert.Equal(expected: "Azure DevOps didn't answer in time. The list may be out of date.", actual: snapshot.Status.Problem);
        Assert.Equal(expected: AzureDevOpsCommands.Refresh, actual: snapshot.ProblemCommand?.Key);

        // Without anything read before, it can't read at all.
        var empty = new PRStore(settings: settings);
        empty.Receive(snapshot: new PulseSnapshot { Organizations = [AzureDevOpsDemoData.Organization], HasLoaded = true, Problem = PulseProblem.Offline }, now: now);
        var offline = AzureDevOpsRows.Snapshot(store: empty, settings: settings, now: now);
        Assert.Equal(expected: SectionCondition.Problem, actual: offline.Status.Condition);
        Assert.Equal(expected: "Offline", actual: offline.Status.ShortProblem);
    }

    /// The first time, it says it's finding your organizations; found, but with none to watch, it says so and offers to
    /// choose them.
    [Fact]
    public void SaysWhatItDoesBeforeItHasOrganizations()
    {
        var settings = new AzureDevOpsSettings(settings: new MemorySettings(), now: now);
        var store = new PRStore(settings: settings);
        store.Receive(snapshot: new PulseSnapshot { Problem = PulseProblem.NoOrganizations, HasLoaded = true }, now: now);
        store.StartDiscovery(now: now);
        var finding = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        Assert.Equal(expected: SectionCondition.Starting, actual: finding.Status.Condition);
        Assert.StartsWith(expectedStartString: "Finding your Azure DevOps organizations", actualString: finding.EmptyText, comparisonType: StringComparison.Ordinal);
        Assert.Null(@object: finding.Quiet);

        settings.HasDiscovered = true;
        store.DiscoveryFinished();
        var none = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        Assert.Equal(expected: SectionCondition.Ready, actual: none.Status.Condition);
        Assert.StartsWith(expectedStartString: "No organizations to watch", actualString: none.EmptyText, comparisonType: StringComparison.Ordinal);
        Assert.Null(@object: none.ProblemCommand);
        Assert.Equal(expected: AppCommands.ReviewSource, actual: none.Commands[0].Key);
        Assert.Null(@object: none.Quiet);

        // Organizations just chosen: it's loading them, not done.
        settings.Organizations = [AzureDevOpsDemoData.Organization];
        store.Recompute(now: now);
        var loading = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        Assert.Equal(expected: SectionCondition.Starting, actual: loading.Status.Condition);
        Assert.Equal(expected: "Loading your pull requests…", actual: loading.EmptyText);

        // The engine reads them now, but hasn't yet: still loading, not all clear.
        store.Receive(snapshot: new PulseSnapshot { Organizations = [AzureDevOpsDemoData.Organization], HasLoaded = true, IsRefreshing = true }, now: now);
        Assert.Equal(expected: "Loading your pull requests…", actual: AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now).EmptyText);

        // Read, with nothing to list: all clear.
        store.Receive(
            snapshot: new PulseSnapshot
            {
                Organizations = [AzureDevOpsDemoData.Organization],
                HasLoaded = true,
                RefreshedAt = now,
                FirstLoaded = new Dictionary<string, DateTimeOffset> { [AzureDevOpsDemoData.Organization] = now },
            },
            now: now);
        var read = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        Assert.Equal(expected: SectionStatus.Updated(time: now), actual: read.Status);
        Assert.Null(@object: read.EmptyText);
        Assert.Equal(expected: new QuietNote(Title: "All clear", Detail: "No open pull requests"), actual: read.Quiet);

        // Reading again, it stays all clear: the bar doesn't say it's starting at every refresh.
        store.Receive(snapshot: store.State with { IsRefreshing = true }, now: now);
        Assert.Equal(expected: SectionCondition.Ready, actual: AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now).Status.Condition);
    }

    /// Nothing needs counting: "All clear", over what's idle.
    [Fact]
    public void SaysAllClearOverWhatsIdle()
    {
        var settings = new AzureDevOpsSettings(settings: new MemorySettings(), now: now) { Organizations = [AzureDevOpsDemoData.Organization] };
        var store = new PRStore(settings: settings);
        var draft = AzureDevOpsDemoData.Records(now: now).Single(predicate: record => record.PullRequest.Key.Number == 4105);
        store.Receive(snapshot: new PulseSnapshot { Records = [draft], Organizations = [AzureDevOpsDemoData.Organization], HasLoaded = true, RefreshedAt = now }, now: now);
        var snapshot = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        Assert.Equal(expected: new QuietNote(Title: "All clear", Detail: "1 idle pull request"), actual: snapshot.Quiet);
        Assert.Equal(expected: "No open pull requests", actual: AzureDevOpsRows.IdleWords(idle: 0));
        Assert.Equal(expected: "3 idle pull requests", actual: AzureDevOpsRows.IdleWords(idle: 3));
    }

    static (PRStore Store, AzureDevOpsSettings Settings) LoadDemo()
    {
        var settings = AzureDevOpsDemoData.Settings(storage: new MemorySettings(), now: now);
        var store = new PRStore(settings: settings);
        store.Receive(snapshot: AzureDevOpsDemoData.Snapshot(now: now), now: now);
        return (store, settings);
    }

    static RowGroup Group(SectionSnapshot snapshot, string key) => Assert.Single(collection: snapshot.Groups, predicate: group => group.Key == key);

    static ItemRow Row(SectionSnapshot snapshot, int number) =>
        Assert.Single(collection: snapshot.Rows, predicate: row => row.Id == AzureDevOpsDemoData.Organization + "/" + number.ToString(provider: System.Globalization.CultureInfo.InvariantCulture));
}
