using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Copilot;
using BriefBar.Core.GitHub;
using BriefBar.Core.Presentation;
using BriefBar.Core.Settings;
using BriefBar.Core.Teams;

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

    /// Teams' made-up 1:1 chats (`TeamsDemoData`), as `TeamsSource` shows them, with its settings as they start.
    public static SectionSnapshot TeamsChats(DateTimeOffset now) => Teams(now: now, group: ChatGroup.Chats);

    /// Teams' made-up group and meeting chats, as `TeamsSource` shows them.
    public static SectionSnapshot TeamsGroupChats(DateTimeOffset now) => Teams(now: now, group: ChatGroup.Groups);

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

    static SectionSnapshot Teams(DateTimeOffset now, ChatGroup group)
    {
        var settings = new TeamsSettings(settings: new MemorySettings());
        var store = new TeamsStore(settings: settings, marks: TeamsReadMarks.InMemory());
        store.Receive(snapshot: TeamsDemoData.Snapshot(now: now), now: now);
        return TeamsRows.Snapshot(store: store, settings: settings, group: group);
    }
}
