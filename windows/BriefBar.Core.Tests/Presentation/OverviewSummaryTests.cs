using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

public sealed class OverviewSummaryTests
{
    [Fact]
    public void SaysWhatNeedsYouWentWrongAndIsDoneButNotWhatsRunning()
    {
        var summary = OverviewSummary.Of(snapshots:
        [
            Snapshots.Chats(unread: 2),
            Snapshots.BusyCopilot(status: SectionStatus.Live),
        ]);
        Assert.Equal(
            expected: [(ItemState.NeedsYou, 4, "need you"), (ItemState.Failing, 1, "went wrong"), (ItemState.Done, 1, "done or ready")],
            actual: summary.Parts.Select(selector: part => (part.State, part.Count, part.Words)));
        // What's running is in the tooltip and for Narrator.
        Assert.Equal(expected: "Overview\nNeeds you: 4 · Something's wrong: 1 · Running: 1 · Done or ready: 1", actual: summary.ToolTip);
        Assert.Equal(expected: "Overview: 4 need you, 1 went wrong, 1 running, 1 done or ready.", actual: summary.AutomationName);
    }

    [Fact]
    public void SaysWhenNothingNeedsYouAndWhenNoSourceIsOn()
    {
        var calm = OverviewSummary.Of(snapshots: [Snapshots.Chats(unread: 0)]);
        Assert.Empty(collection: calm.Parts);
        Assert.Equal(expected: "Nothing needs you", actual: calm.EmptyText);
        Assert.Equal(expected: "Overview: Nothing needs you.", actual: calm.AutomationName);

        var off = OverviewSummary.Of(snapshots: []);
        Assert.Empty(collection: off.Parts);
        Assert.Equal(expected: "No source is on", actual: off.EmptyText);
        Assert.Equal(expected: "Overview\nNo source is on", actual: off.ToolTip);
    }

    [Fact]
    public void LeavesOutWhatsOnlyRunning()
    {
        var runningOnly = Snapshots.Copilot(
            status: SectionStatus.Live,
            rows: [Snapshots.Row(id: "work", section: SectionId.CopilotSessions, group: "running", state: ItemState.Running)]);
        var summary = OverviewSummary.Of(snapshots: [runningOnly]);
        Assert.Empty(collection: summary.Parts);
        Assert.Equal(expected: "Nothing needs you", actual: summary.EmptyText);
        Assert.Equal(expected: "Overview\nRunning: 1", actual: summary.ToolTip);
    }
}
