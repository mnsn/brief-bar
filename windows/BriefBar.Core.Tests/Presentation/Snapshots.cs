using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

/// Made-up sections and rows for the presentation tests.
internal static class Snapshots
{
    public static ItemRow Row(string id, SectionId section, string group, ItemState? state, double minutesAgo = 1) => new()
    {
        Id = id,
        Section = section,
        Group = group,
        State = state,
        Icon = IconKey.Checkmark,
        Title = "Made-up " + id,
        Status = "Made-up status",
        Date = Times.At(seconds: -minutesAgo * 60),
    };

    public static SectionSnapshot Copilot(SectionStatus status, IReadOnlyList<ItemRow> rows) => new(
        Info: Sections.CopilotSessions,
        Status: status,
        Groups:
        [
            new RowGroup(Key: "needsYou", Title: "Needs you", State: ItemState.NeedsYou),
            new RowGroup(Key: "running", Title: "Running", State: ItemState.Running),
            new RowGroup(Key: "done", Title: "Done", State: ItemState.Done),
            new RowGroup(Key: "stopped", Title: "Stopped", State: ItemState.Failing),
            new RowGroup(Key: "idle", Title: "Idle", State: null),
        ],
        Rows: rows,
        BriefLines: []);

    /// Copilot sessions: 2 that need you, 1 running, 1 done, 1 stopped and 1 idle.
    public static SectionSnapshot BusyCopilot(SectionStatus status) => Copilot(
        status: status,
        rows:
        [
            Row(id: "ask", section: SectionId.CopilotSessions, group: "needsYou", state: ItemState.NeedsYou, minutesAgo: 2),
            Row(id: "plan", section: SectionId.CopilotSessions, group: "needsYou", state: ItemState.NeedsYou, minutesAgo: 5),
            Row(id: "work", section: SectionId.CopilotSessions, group: "running", state: ItemState.Running),
            Row(id: "finished", section: SectionId.CopilotSessions, group: "done", state: ItemState.Done),
            Row(id: "stuck", section: SectionId.CopilotSessions, group: "stopped", state: ItemState.Failing),
            Row(id: "quiet", section: SectionId.CopilotSessions, group: "idle", state: null),
        ]);

    public static SectionSnapshot Chats(int unread) => new(
        Info: Sections.TeamsChats,
        Status: SectionStatus.Live,
        Groups: [new RowGroup(Key: "unread", Title: "Unread", State: ItemState.NeedsYou)],
        Rows: Enumerable.Range(start: 0, count: unread)
            .Select(selector: index => Row(
                id: "chat" + index, section: SectionId.TeamsChats, group: "unread", state: ItemState.NeedsYou, minutesAgo: index))
            .ToList(),
        BriefLines: []);
}
