using BriefBar.Core.Logging;
using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

[Collection(name: nameof(SharedLog))]
public sealed class PanelListsTests
{
    [Fact]
    public void ListsASectionsGroupsInItsOrderLeavingOutEmptyOnes()
    {
        var snapshot = Snapshots.Copilot(
            status: SectionStatus.Live,
            rows:
            [
                Snapshots.Row(id: "done", section: SectionId.CopilotSessions, group: "done", state: ItemState.Done),
                Snapshots.Row(id: "ask", section: SectionId.CopilotSessions, group: "needsYou", state: ItemState.NeedsYou),
                Snapshots.Row(id: "idle", section: SectionId.CopilotSessions, group: "idle", state: null),
            ]);
        var groups = PanelLists.ForSection(snapshot: snapshot);
        Assert.Equal(expected: ["Needs you", "Done", "Idle"], actual: groups.Select(selector: group => group.Title));
        Assert.Equal(expected: [ItemState.NeedsYou, ItemState.Done, null], actual: groups.Select(selector: group => group.State));
        Assert.Equal(expected: ["ask"], actual: groups[0].Rows.Select(selector: row => row.Id));
    }

    [Fact]
    public void KeepsTheSectionsOwnOrderWithinAGroup()
    {
        // Copilot's Needs You sorts the longest wait first; the panel doesn't sort it again.
        var snapshot = Snapshots.Copilot(
            status: SectionStatus.Live,
            rows:
            [
                Snapshots.Row(id: "older", section: SectionId.CopilotSessions, group: "needsYou", state: ItemState.NeedsYou, minutesAgo: 30),
                Snapshots.Row(id: "newer", section: SectionId.CopilotSessions, group: "needsYou", state: ItemState.NeedsYou, minutesAgo: 1),
            ]);
        Assert.Equal(
            expected: ["older", "newer"],
            actual: PanelLists.ForSection(snapshot: snapshot)[0].Rows.Select(selector: row => row.Id));
    }

    [Fact]
    public void LogsRowsInNoGroupWithoutTheirContent()
    {
        var sink = new ListSink();
        Log.UseSink(newSink: sink);
        try
        {
            var snapshot = Snapshots.Copilot(
                status: SectionStatus.Live,
                rows: [Snapshots.Row(id: "lost", section: SectionId.CopilotSessions, group: "nowhere", state: ItemState.NeedsYou)]);
            Assert.Empty(collection: PanelLists.ForSection(snapshot: snapshot));
            var line = Assert.Single(collection: sink.Lines);
            Assert.EndsWith(
                expectedEndString: "copilot.sessions: 1 rows in no group aren't shown",
                actualString: line,
                comparisonType: StringComparison.Ordinal);
            Assert.DoesNotContain(expectedSubstring: "lost", actualString: line, comparisonType: StringComparison.Ordinal);
        }
        finally
        {
            Log.UseSink(newSink: null);
        }
    }

    [Fact]
    public void ListsEverySectionsThingsByStateTheNewestFirstForTheOverview()
    {
        var groups = PanelLists.ForOverview(snapshots:
        [
            Snapshots.Chats(unread: 2),
            Snapshots.BusyCopilot(status: SectionStatus.Live),
        ]);
        Assert.Equal(
            expected: ["Needs you", "Something's wrong", "Running", "Done or ready"],
            actual: groups.Select(selector: group => group.Title));
        // Chats 0 and 1 minutes ago, then Copilot's 2 and 5 minutes ago: the newest first, across sections.
        Assert.Equal(expected: ["chat0", "chat1", "ask", "plan"], actual: groups[0].Rows.Select(selector: row => row.Id));
        // The idle session, in no state, isn't in the Overview.
        Assert.DoesNotContain(collection: groups.SelectMany(selector: group => group.Rows), filter: row => row.Id == "quiet");
    }

    [Fact]
    public void PutsThingsWithNoDateLastInTheOverview()
    {
        var undated = Snapshots.Row(id: "undated", section: SectionId.CopilotSessions, group: "needsYou", state: ItemState.NeedsYou) with
        {
            Date = null,
        };
        var dated = Snapshots.Row(id: "dated", section: SectionId.CopilotSessions, group: "needsYou", state: ItemState.NeedsYou, minutesAgo: 600);
        var groups = PanelLists.ForOverview(snapshots: [Snapshots.Copilot(status: SectionStatus.Live, rows: [undated, dated])]);
        Assert.Equal(expected: ["dated", "undated"], actual: groups[0].Rows.Select(selector: row => row.Id));
    }

    [Fact]
    public void BriefsEachSectionOnItsOwnAndEverySectionTogether()
    {
        var now = Times.At(seconds: 0);
        var snapshots = Core.Demo.DemoData.Snapshots(now: now);
        var copilot = snapshots.Single(predicate: snapshot => snapshot.Info.Id == SectionId.CopilotSessions);
        Assert.All(
            collection: PanelLists.Brief(snapshots: [copilot]),
            action: line => Assert.Equal(expected: SectionId.CopilotSessions, actual: line.Section));
        var overview = PanelLists.Brief(snapshots: snapshots);
        Assert.Equal(expected: 5, actual: overview.Count);
        // Every source with something to say has a line.
        Assert.Equal(
            expected: Enum.GetValues<SourceId>().Order(),
            actual: overview.Select(selector: line => line.Source!.Value).Distinct().Order());
    }
}
