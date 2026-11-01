using BriefBar.Core.Demo;
using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Demo;

public sealed class DemoDataTests
{
    static readonly IReadOnlyList<SectionSnapshot> snapshots = DemoData.Snapshots(now: Times.At(seconds: 0));

    [Fact]
    public void HasEverySectionOfTheBar()
    {
        Assert.Equal(expected: Sections.InBarOrder, actual: snapshots.Select(selector: snapshot => snapshot.Info));
    }

    [Fact]
    public void PutsEveryRowInOneOfItsSectionsGroupsWithThatGroupsState()
    {
        foreach (var snapshot in snapshots)
        {
            Assert.Equal(
                expected: snapshot.Groups.Count,
                actual: snapshot.Groups.Select(selector: group => group.Key).Distinct().Count());
            foreach (var row in snapshot.Rows)
            {
                Assert.Equal(expected: snapshot.Info.Id, actual: row.Section);
                var group = Assert.Single(collection: snapshot.Groups, predicate: group => group.Key == row.Group);
                Assert.Equal(expected: group.State, actual: row.State);
            }
            Assert.Equal(
                expected: snapshot.Rows.Count,
                actual: snapshot.Rows.Select(selector: row => row.Id).Distinct().Count());
        }
    }

    [Fact]
    public void BriefsOnlyWhatItsRowsShowInTheirStates()
    {
        foreach (var snapshot in snapshots)
        {
            foreach (var line in snapshot.BriefLines)
            {
                var row = Assert.Single(collection: snapshot.Rows, predicate: row => row.Id == line.Id);
                Assert.Equal(expected: row.State, actual: line.State);
                Assert.Equal(expected: snapshot.Info.Id, actual: line.Section);
            }
        }
    }

    [Fact]
    public void CountsWhatTheMockupShows()
    {
        var total = snapshots.Aggregate(seed: new StateCounts(), func: (sum, snapshot) => sum + snapshot.Counts);
        Assert.Equal(expected: new StateCounts(NeedsYou: 8, Failing: 3, Running: 2, Done: 3), actual: total);
    }

    [Fact]
    public void ServesEachSourcesSectionsOnly()
    {
        var sources = DemoSource.All(madeAt: Times.At(seconds: 0));
        Assert.Equal(expected: Enum.GetValues<SourceId>(), actual: sources.Select(selector: source => source.Source));
        var teams = sources.Single(predicate: source => source.Source == SourceId.Teams);
        Assert.Equal(
            expected: [SectionId.TeamsChats, SectionId.TeamsGroupChats],
            actual: teams.Sections.Select(selector: section => section.Id));
        Assert.Equal(expected: 1, actual: teams.Snapshot(section: SectionId.TeamsChats).Counts.NeedsYou);
        Assert.Throws<ArgumentException>(testCode: () => teams.Snapshot(section: SectionId.CopilotSessions));
    }
}
