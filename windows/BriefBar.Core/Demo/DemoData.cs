using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Copilot;
using BriefBar.Core.Presentation;
using BriefBar.Core.Settings;

namespace BriefBar.Core.Demo;

/// Made-up data for every section, in the spirit of the Mac's `--demo`: for working on the UI, screenshots and UI
/// tests, without reading anything of yours. Dates are minutes before `now`.
public static class DemoData
{
    public static IReadOnlyList<SectionSnapshot> Snapshots(DateTimeOffset now) =>
    [
        TeamsChats(now: now),
        TeamsGroupChats(now: now),
        AzureDevOpsPullRequests(now: now),
        CopilotSessions(now: now),
        GitHubPullRequests(now: now),
    ];

    public static SectionSnapshot TeamsChats(DateTimeOffset now) => new(
        Info: Sections.TeamsChats,
        Status: SectionStatus.Live,
        Groups: [new RowGroup(Key: "unread", Title: "Unread", State: ItemState.NeedsYou)],
        Rows:
        [
            new ItemRow
            {
                Id = "priya", Section = SectionId.TeamsChats, Group = "unread", State = ItemState.NeedsYou,
                Icon = IconKey.Person, Initials = "PS", Title = "Priya Shah",
                Status = "Can you look at the release notes before 5?", StatusTone = StatusTone.Quote,
                Date = Ago(now: now, minutes: 14), Unread = 1,
            },
        ],
        BriefLines:
        [
            Line(id: "priya", section: SectionId.TeamsChats, state: ItemState.NeedsYou, now: now, minutes: 14,
                sentence: "Priya Shah: Can you look at the release notes before 5?"),
        ]);

    public static SectionSnapshot TeamsGroupChats(DateTimeOffset now) => new(
        Info: Sections.TeamsGroupChats,
        Status: SectionStatus.Live,
        Groups: [new RowGroup(Key: "unread", Title: "Unread", State: ItemState.NeedsYou)],
        Rows:
        [
            new ItemRow
            {
                Id = "launch-crew", Section = SectionId.TeamsGroupChats, Group = "unread", State = ItemState.NeedsYou,
                Icon = IconKey.People, Initials = "LC", Title = "Launch crew & Design",
                Status = "Jordan Lee: Shipping at 5 unless someone objects.", StatusTone = StatusTone.Quote,
                Date = Ago(now: now, minutes: 5), Unread = 3,
            },
        ],
        BriefLines:
        [
            Line(id: "launch-crew", section: SectionId.TeamsGroupChats, state: ItemState.NeedsYou, now: now, minutes: 5,
                sentence: "Launch crew & Design: shipping at 5 unless someone objects."),
        ]);

    /// Azure DevOps' made-up pull requests (`AzureDevOpsDemoData`), as `AzureDevOpsSource` shows them, with its settings as
    /// the demo starts them.
    public static SectionSnapshot AzureDevOpsPullRequests(DateTimeOffset now)
    {
        var settings = AzureDevOpsDemoData.Settings(storage: new MemorySettings(), now: now);
        var store = new PRStore(settings: settings);
        store.Receive(snapshot: AzureDevOpsDemoData.Snapshot(now: now), now: now);
        return AzureDevOpsRows.Snapshot(store: store, settings: settings, now: now);
    }

    /// Copilot's made-up sessions (`CopilotDemoData`), as `CopilotSource` shows them, with its settings as they start.
    public static SectionSnapshot CopilotSessions(DateTimeOffset now)
    {
        var settings = new CopilotSettings(settings: new MemorySettings(), now: now);
        var store = new SessionStore(settings: settings, openSession: _ => { }, isAppInstalled: () => true, isAppFrontmost: () => false);
        store.Receive(snapshot: CopilotDemoData.Snapshot(now: now), now: now);
        return CopilotRows.Snapshot(store: store, settings: settings);
    }

    public static SectionSnapshot GitHubPullRequests(DateTimeOffset now) => new(
        Info: Sections.GitHubPullRequests,
        Status: SectionStatus.Updated(time: now.AddSeconds(seconds: -45)),
        Groups:
        [
            new RowGroup(Key: "needsYou", Title: "Needs you", State: ItemState.NeedsYou),
            new RowGroup(Key: "failing", Title: "Failing", State: ItemState.Failing),
            new RowGroup(Key: "ready", Title: "Ready to merge", State: ItemState.Done),
        ],
        Rows:
        [
            new ItemRow
            {
                Id = "checkout-dark-mode", Section = SectionId.GitHubPullRequests, Group = "needsYou", State = ItemState.NeedsYou,
                Icon = IconKey.Eye, Title = "Add dark mode to the checkout page", Status = "priya asks for your review · shop-web",
                Detail = "Required reviewer", Date = Ago(now: now, minutes: 20),
            },
            new ItemRow
            {
                Id = "swift-6-2", Section = SectionId.GitHubPullRequests, Group = "failing", State = ItemState.Failing,
                Icon = IconKey.Dismiss, Title = "Upgrade to Swift 6.2", Status = "Checks are failing · ios-app",
                Detail = "build (macos-15) failed after 6 minutes", Date = Ago(now: now, minutes: 25),
            },
            new ItemRow
            {
                Id = "lodash", Section = SectionId.GitHubPullRequests, Group = "ready", State = ItemState.Done,
                Icon = IconKey.Checkmark, Title = "Bump lodash to 4.17.21", Status = "Ready to merge · shop-web",
                Date = Ago(now: now, minutes: 60),
            },
        ],
        BriefLines:
        [
            Line(id: "checkout-dark-mode", section: SectionId.GitHubPullRequests, state: ItemState.NeedsYou, now: now, minutes: 20,
                sentence: "priya asks for your review on “Add dark mode to the checkout page”."),
            Line(id: "swift-6-2", section: SectionId.GitHubPullRequests, state: ItemState.Failing, now: now, minutes: 25,
                sentence: "Checks are failing on “Upgrade to Swift 6.2”."),
            Line(id: "lodash", section: SectionId.GitHubPullRequests, state: ItemState.Done, now: now, minutes: 60,
                sentence: "“Bump lodash to 4.17.21” is ready to merge."),
        ]);

    static DateTimeOffset Ago(DateTimeOffset now, int minutes) => now.AddMinutes(minutes: -minutes);

    static BriefLine Line(string id, SectionId section, ItemState state, DateTimeOffset now, int minutes, string sentence) =>
        new(Id: id, Section: section, State: state, Date: Ago(now: now, minutes: minutes), Sentence: sentence);
}
