using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Copilot;
using BriefBar.Core.GitHub;
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

    /// GitHub's made-up pull requests (`GitHubDemoData`), as `GitHubSource` shows them once it has read them.
    public static SectionSnapshot GitHubPullRequests(DateTimeOffset now)
    {
        var store = new GitHubStore(settings: new GitHubSettings(settings: new MemorySettings()));
        store.Start();
        store.Receive(load: GitHubDemoData.Load(now: now), now: now);
        return GitHubRows.Snapshot(store: store);
    }

    static DateTimeOffset Ago(DateTimeOffset now, int minutes) => now.AddMinutes(minutes: -minutes);

    static BriefLine Line(string id, SectionId section, ItemState state, DateTimeOffset now, int minutes, string sentence) =>
        new(Id: id, Section: section, State: state, Date: Ago(now: now, minutes: minutes), Sentence: sentence);
}
