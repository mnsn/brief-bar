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

    /// Under each of your open pull requests, what's left before you can complete it, the most pressing first, then what's
    /// done, as the Mac's line says it; its tooltip and Narrator say all of it, and when it was created.
    [Fact]
    public void SaysWhatsLeftUnderEachOfYourPullRequests()
    {
        var (store, settings) = LoadDemo();
        var snapshot = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        var replied = Row(snapshot: snapshot, number: 4102);
        var checklist = replied.Checklist;
        Assert.NotNull(@object: checklist);
        Assert.Equal(
            expected:
            [
                new RowChecklistItem(Icon: IconKey.HandRaise, State: ItemState.NeedsYou, Label: "Resolve 1 comment", IsDone: false),
                new RowChecklistItem(Icon: IconKey.Clock, State: null, Label: "1 of 2 approvals", IsDone: false),
                new RowChecklistItem(Icon: IconKey.Clock, State: null, Label: "Waiting on Sam", IsDone: false),
                new RowChecklistItem(Icon: IconKey.CheckmarkCircle, State: ItemState.Done, Label: "Build passed", IsDone: true),
            ],
            actual: checklist.Items);
        Assert.False(condition: checklist.IsQuiet);
        string[] lines =
        [
            "Left to complete it: Resolve 1 comment (A policy requires resolving every comment); 1 of 2 approvals (Approved by Priya Shah); Waiting on Sam (Required: Sam Rivera)",
            "Done: Build passed (payments-api CI)",
        ];
        Assert.Equal(expected: lines, actual: checklist.Summary);
        // Its tooltip says it in place of who approved, and when it was created.
        var tip = replied.ToolTip!.Split(separator: '\n');
        Assert.Equal(expected: [.. lines, "Created 1d ago"], actual: tip[4..7]);
        Assert.DoesNotContain(collection: tip, filter: line => line.StartsWith(value: "Approved by", comparisonType: StringComparison.Ordinal));
        Assert.Contains(
            expectedSubstring: "Sam Rivera replied, payments-api, Could we cap the backoff",
            actualString: RowWords.SpokenName(row: replied, sourceName: null, now: now),
            comparisonType: StringComparison.Ordinal);
        Assert.Contains(expectedSubstring: lines[0], actualString: RowWords.SpokenName(row: replied, sourceName: null, now: now), comparisonType: StringComparison.Ordinal);

        // Open comments that don't hold it up, quietly; an idle one's words all quiet.
        var idle = Row(snapshot: snapshot, number: 3990).Checklist;
        Assert.NotNull(@object: idle);
        Assert.True(condition: idle.IsQuiet);
        Assert.Equal(
            expected: [(IconKey.DismissCircle, (ItemState?)ItemState.Failing, "Build expired"), (IconKey.Clock, null, "Not approved yet"), (IconKey.Comment, null, "1 open comment")],
            actual: idle.Items.Select(selector: item => (item.Icon, item.State, item.Label)));
        Assert.Equal(expected: "Not required: 1 open comment", actual: idle.Summary[1]);

        // Reviews, and what's closed, don't say it; nor does a review's tooltip say who approved in its place.
        Assert.Null(@object: Row(snapshot: snapshot, number: 4097).Checklist);
        Assert.Null(@object: Row(snapshot: snapshot, number: 4085).Checklist);
        Assert.Contains(expectedSubstring: "\nApproved by Maria Garcia\n", actualString: Row(snapshot: snapshot, number: 4097).ToolTip, comparisonType: StringComparison.Ordinal);
    }

    /// What's left, a line each: what holds it up, what doesn't, what's done; and, once it changed since its policies were
    /// read, that it says what was read last.
    [Fact]
    public void SaysWhatsLeftInWords()
    {
        PRReadinessItem[] items =
        [
            new(Kind: PRReadinessItemKind.Builds, State: ItemState.Failing, Label: "Build failed", Detail: "web-ci · Run unit tests: 2 tests failed"),
            new(Kind: PRReadinessItemKind.Comments, State: null, Label: "2 open comments", IsRequired: false),
            new(Kind: PRReadinessItemKind.Approvals, State: ItemState.Done, Label: "Approved", Detail: "Approved by Priya Shah"),
        ];
        Assert.Equal(
            expected:
            [
                "Left to complete it: Build failed (web-ci · Run unit tests: 2 tests failed)",
                "Not required: 2 open comments",
                "Done: Approved (Approved by Priya Shah)",
            ],
            actual: AzureDevOpsRows.ReadinessLines(readiness: new PRReadiness(Items: [.. items])));
        Assert.Equal(
            expected: ["Nothing left to complete it, as last read", "Done: Approved (Approved by Priya Shah)", "It changed since its policies were read: they're read again at the next refresh"],
            actual: AzureDevOpsRows.ReadinessLines(readiness: new PRReadiness(Items: [items[2]], IsCurrent: false)));
        Assert.Equal(expected: ["Nothing left to complete it"], actual: AzureDevOpsRows.ReadinessLines(readiness: new PRReadiness(Items: [])));
        Assert.Equal(expected: IconKey.ArrowSync, actual: AzureDevOpsRows.Icon(item: new PRReadinessItem(Kind: PRReadinessItemKind.Checks, State: ItemState.Running, Label: "Check running")));
    }

    /// By date, every pull request but Done's and Idle's is in one list, by when each was created, each still in its state;
    /// Done's and Idle's keep their sections after it, Idle's in the same order. What the bar counts and the brief stay
    /// by status.
    [Fact]
    public void ListsThemByDate()
    {
        var (store, settings) = LoadDemo();
        var byStatus = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        settings.PullRequestOrder = PROrder.NewestFirst;
        var snapshot = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        Assert.Equal(expected: [AzureDevOpsRows.DateListKey, "done", "idle"], actual: snapshot.Groups.Select(selector: group => group.Key));
        Assert.Equal(expected: ["Newest first", "Done", "Idle"], actual: snapshot.Groups.Select(selector: group => group.Title));
        var byDate = Group(snapshot: snapshot, key: AzureDevOpsRows.DateListKey);
        Assert.Null(@object: byDate.State);
        Assert.Equal(expected: AzureDevOpsCommands.MarkAsSeen, actual: byDate.Commands.Single().Key);
        Assert.True(condition: Group(snapshot: snapshot, key: "idle").IsFolded);
        Assert.Equal(
            expected: [4110, 4099, 4108, 4102, 4091, 4097, 4093, 4088, 4079, 4071, 4060, 4085, 4105, 3990],
            actual: snapshot.Rows.Select(selector: row => int.Parse(s: row.Id.Split(separator: '/')[1], provider: System.Globalization.CultureInfo.InvariantCulture)));
        Assert.All(collection: snapshot.Rows.Take(count: 11), action: row => Assert.Equal(expected: AzureDevOpsRows.DateListKey, actual: row.Group));
        // Each row's time is how long ago it was created, but Done's.
        var replied = Row(snapshot: snapshot, number: 4102);
        Assert.Equal(expected: now.AddHours(hours: -26), actual: replied.Created);
        Assert.Equal(expected: Row(snapshot: byStatus, number: 4102).Date, actual: replied.Date);
        Assert.Equal(expected: now.AddDays(days: -40), actual: Row(snapshot: snapshot, number: 3990).Created);
        Assert.Null(@object: Row(snapshot: snapshot, number: 4085).Created);
        Assert.EndsWith(expectedEndString: "created 1 day ago", actualString: RowWords.SpokenName(row: replied, sourceName: null, now: now, showsCreated: true), comparisonType: StringComparison.Ordinal);
        Assert.All(collection: byStatus.Rows, action: row => Assert.Null(@object: row.Created));
        // Each in the state it's in, counted and briefed as by status.
        Assert.Equal(
            expected: byStatus.Rows.ToDictionary(keySelector: row => row.Id, elementSelector: row => row.State),
            actual: snapshot.Rows.ToDictionary(keySelector: row => row.Id, elementSelector: row => row.State));
        Assert.Equal(expected: byStatus.Counts, actual: snapshot.Counts);
        Assert.Equal(expected: byStatus.BriefLines, actual: snapshot.BriefLines);

        // Oldest first, the other way round, Idle's too.
        settings.PullRequestOrder = PROrder.OldestFirst;
        var oldest = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        Assert.Equal(expected: "Oldest first", actual: oldest.Groups[0].Title);
        Assert.Equal(
            expected: [4060, 4071, 4079, 4088, 4093, 4097, 4091, 4102, 4108, 4099, 4110, 4085, 3990, 4105],
            actual: oldest.Rows.Select(selector: row => int.Parse(s: row.Id.Split(separator: '/')[1], provider: System.Globalization.CultureInfo.InvariantCulture)));

        // Seen, the list has nothing new to mark.
        store.Clear(group: PRGroup.NeedsYou, now: now);
        store.Recompute(now: now);
        Assert.Empty(collection: Group(snapshot: AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now), key: AzureDevOpsRows.DateListKey).Commands);
    }

    /// Its tooltip's "Created 5m ago" moves on as the Mac's does: the section is built again whenever those words would
    /// change, which is at most once a minute while one was created within the day ("3h 12m"), and once a day after.
    [Fact]
    public void SaysHowLongAgoEachWasCreatedAsTimeMovesOn()
    {
        var (store, settings) = LoadDemo();
        static string Created(ItemRow row) => row.ToolTip!.Split(separator: '\n').Single(predicate: line => line.StartsWith(value: "Created ", comparisonType: StringComparison.Ordinal));
        var young = Row(snapshot: AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now), number: 4110);
        Assert.Equal(expected: "Created 40m ago", actual: Created(row: young));
        Assert.Equal(expected: "Created 41m ago", actual: Created(row: Row(snapshot: AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now.AddMinutes(minutes: 1)), number: 4110)));

        // Within the same minute, nothing it says changes; past it, the young one's does.
        Assert.False(condition: AzureDevOpsRows.CreatedWordsChanged(items: store.Items, then: now, now: now.AddSeconds(seconds: 45)));
        Assert.True(condition: AzureDevOpsRows.CreatedWordsChanged(items: store.Items, then: now, now: now.AddSeconds(seconds: 61)));
        // Without it, nothing changes within the hour: the others were created more than a day ago, and say it in days.
        var older = store.Items.Where(predicate: item => now - item.CreatedAt > TimeSpan.FromDays(value: 1)).ToList();
        Assert.NotEmpty(collection: older);
        Assert.False(condition: AzureDevOpsRows.CreatedWordsChanged(items: older, then: now, now: now.AddHours(hours: 1)));
        Assert.True(condition: AzureDevOpsRows.CreatedWordsChanged(items: older, then: now, now: now.AddDays(days: 1)));
        Assert.Equal(expected: "Created just now", actual: Created(row: AzureDevOpsRows.Row(item: store.Items[0] with { CreatedAt = now.AddSeconds(seconds: -20) }, showToReview: false, now: now)));
    }

    /// Its sort menu, at the top of the panel: each order, and the one in use.
    [Fact]
    public void OffersToSortTheList()
    {
        var (store, settings) = LoadDemo();
        var sort = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now).Sort;
        Assert.NotNull(@object: sort);
        Assert.Equal(
            expected: [("sort.status", "By status"), ("sort.newestFirst", "Newest first"), ("sort.oldestFirst", "Oldest first")],
            actual: sort.Choices.Select(selector: choice => (choice.Key, choice.Title)));
        Assert.Equal(expected: "sort.status", actual: sort.Chosen);
        Assert.Equal(expected: "By status", actual: sort.ChosenChoice?.Title);
        Assert.Equal(expected: "Sort pull requests", actual: sort.Name);
        Assert.StartsWith(expectedStartString: "Sort: By status. By status groups them", actualString: sort.Help, comparisonType: StringComparison.Ordinal);
        Assert.All(collection: PROrders.All, action: order => Assert.Equal(expected: order, actual: AzureDevOpsCommands.SortedBy(command: AzureDevOpsCommands.Sort(order: order))));
        Assert.Null(@object: AzureDevOpsCommands.SortedBy(command: AzureDevOpsCommands.Refresh));
        Assert.Null(@object: AzureDevOpsCommands.SortedBy(command: "sort.sideways"));

        settings.PullRequestOrder = PROrder.OldestFirst;
        var byDate = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now).Sort;
        Assert.Equal(expected: "Oldest first", actual: byDate?.ChosenChoice?.Title);
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

    /// Organization names are case-insensitive in Azure DevOps: a link that spells its organization another way watches
    /// the same pull request, and stopping watching it there stops.
    [Fact]
    public void WatchesALinkSpelledAnotherWay()
    {
        var (store, settings) = LoadDemo();
        Assert.True(condition: settings.Watch(link: new PullRequestLink(Organization: "CONTOSO", Project: "Storefront", Repository: "search", Number: 4071)));
        Assert.False(condition: settings.Watch(link: new PullRequestLink(Organization: AzureDevOpsDemoData.Organization, Project: "Storefront", Repository: "search", Number: 4071)));
        store.Recompute(now: now);
        var watched = Row(snapshot: AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now), number: 4071);
        Assert.Equal(expected: [AzureDevOpsCommands.Open, AzureDevOpsCommands.StopWatching], actual: watched.Commands.Select(selector: command => command.Key));

        settings.Unwatch(keys: new HashSet<PRKey> { new(Organization: AzureDevOpsDemoData.Organization, Number: 4071) });
        Assert.Empty(collection: settings.WatchedPullRequests);
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

    /// Your own directory wants you to sign in again, there, while the Azure CLI is signed in to you in another: it says to
    /// sign in, as when you're signed out, and Sign in signs in there.
    [Fact]
    public void SignsInAgainInYourOwnDirectory()
    {
        var (store, settings) = LoadDemo();
        const string tenant = "0a0a0a0a-1111-4111-8111-111111111111";
        store.Receive(snapshot: AzureDevOpsDemoData.Snapshot(now: now) with { Problem = PulseProblem.SignedOut(detail: "AADSTS50076", tenant: tenant) }, now: now);
        var snapshot = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        Assert.Equal(expected: new StateCounts(), actual: snapshot.Counts);
        Assert.Equal(expected: (SectionCondition.Problem, "Sign in"), actual: (snapshot.Status.Condition, snapshot.Status.ShortProblem));
        Assert.Equal(expected: AzureDevOpsCommands.SignInTo(tenant: tenant), actual: snapshot.ProblemCommand?.Key);
        Assert.Equal(expected: "Sign in…", actual: snapshot.ProblemCommand?.Title);
        Assert.True(condition: snapshot.ProblemCommand?.Opens);
        Assert.Null(@object: snapshot.ProblemHint);
    }

    /// Some organizations are in a directory the Azure CLI isn't signed in to: the others' pull requests stay listed and
    /// counted, out of date, and the banner names those organizations, offers to sign in to their directory, and says what
    /// to do about a project's name entered as an organization's, in the panel only. The directory's ID is only in the
    /// command that signs in there.
    [Fact]
    public void OffersToSignInToTheDirectoryOfOrganizationsInAnother()
    {
        var (store, settings) = LoadDemo();
        const string tenant = "0b0b0b0b-2222-4222-8222-222222222222";
        var problem = PulseProblem.OtherDirectory(organizations: ["fabrikam"], tenant: tenant);
        store.Receive(snapshot: AzureDevOpsDemoData.Snapshot(now: now) with { Problem = problem }, now: now);
        var snapshot = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        Assert.Equal(expected: new StateCounts(NeedsYou: 3, Failing: 2, Done: 2), actual: snapshot.Counts);
        Assert.NotEmpty(collection: snapshot.BriefLines);
        Assert.Equal(expected: SectionCondition.Stale, actual: snapshot.Status.Condition);
        Assert.Equal(expected: "fabrikam is in a directory your Azure CLI isn't signed in to.", actual: snapshot.Status.Problem);
        Assert.Equal(expected: AzureDevOpsCommands.SignInTo(tenant: tenant), actual: snapshot.ProblemCommand?.Key);
        Assert.Equal(expected: tenant, actual: AzureDevOpsCommands.SignInTenant(command: snapshot.ProblemCommand!.Key));
        Assert.Equal(expected: "Sign in…", actual: snapshot.ProblemCommand.Title);
        Assert.Equal(
            expected: "Sign in runs az login there, in a console window. If it's a project rather than an organization, remove it in Settings: a project's organization is the first part of its link.",
            actual: snapshot.ProblemHint);
        Assert.DoesNotContain(expectedSubstring: tenant, actualString: snapshot.Status.Problem + snapshot.ProblemHint + snapshot.ProblemCommand.Title, comparisonType: StringComparison.Ordinal);

        // With nothing else listed, the bar says to sign in.
        var empty = new PRStore(settings: settings);
        empty.Receive(
            snapshot: new PulseSnapshot
            {
                Organizations = ["fabrikam", "northwind"],
                HasLoaded = true,
                Problem = PulseProblem.OtherDirectory(organizations: ["fabrikam", "northwind"], tenant: tenant),
            },
            now: now);
        var nothing = AzureDevOpsRows.Snapshot(store: empty, settings: settings, now: now);
        Assert.Equal(expected: (SectionCondition.Problem, "Sign in"), actual: (nothing.Status.Condition, nothing.Status.ShortProblem));
        Assert.StartsWith(expectedStartString: "Sign in runs az login there, in a console window. If one is a project", actualString: nothing.ProblemHint, comparisonType: StringComparison.Ordinal);
    }

    /// Only a directory's ID is one to sign in to: any other command that starts as signing in to one isn't.
    [Fact]
    public void SignsInOnlyToADirectorysID()
    {
        Assert.Equal(expected: "signIn.0b0b0b0b-2222-4222-8222-222222222222", actual: AzureDevOpsCommands.SignInTo(tenant: "0b0b0b0b-2222-4222-8222-222222222222"));
        Assert.Equal(expected: "0b0b0b0b-2222-4222-8222-222222222222", actual: AzureDevOpsCommands.SignInTenant(command: "signIn.0B0B0B0B-2222-4222-8222-222222222222"));
        Assert.Null(@object: AzureDevOpsCommands.SignInTenant(command: "signIn.contoso & calc"));
        Assert.Null(@object: AzureDevOpsCommands.SignInTenant(command: "signIn."));
        Assert.Null(@object: AzureDevOpsCommands.SignInTenant(command: AzureDevOpsCommands.SignIn));
        Assert.Null(@object: AzureDevOpsCommands.SignInTenant(command: AzureDevOpsCommands.Sort(order: PROrder.NewestFirst)));
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

    /// An organization spelled another way since it was first read, as when finding your organizations again spells it as
    /// Azure DevOps does, has been read: with nothing to list, it's all clear, not loading.
    [Fact]
    public void AnOrganizationSpelledAnotherWayHasBeenRead()
    {
        var settings = new AzureDevOpsSettings(settings: new MemorySettings(), now: now) { Organizations = ["CONTOSO"], HasDiscovered = true };
        var store = new PRStore(settings: settings);
        store.Receive(
            snapshot: new PulseSnapshot
            {
                Organizations = ["CONTOSO"],
                HasLoaded = true,
                RefreshedAt = now,
                FirstLoaded = new Dictionary<string, DateTimeOffset> { [AzureDevOpsDemoData.Organization] = now },
            },
            now: now);
        var snapshot = AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
        Assert.Null(@object: snapshot.EmptyText);
        Assert.Equal(expected: new QuietNote(Title: "All clear", Detail: "No open pull requests"), actual: snapshot.Quiet);
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
