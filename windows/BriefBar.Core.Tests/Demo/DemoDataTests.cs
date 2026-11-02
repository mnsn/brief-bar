using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Demo;
using BriefBar.Core.GitHub;
using BriefBar.Core.Presentation;
using BriefBar.Core.Settings;

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
        Assert.Equal(expected: new StateCounts(NeedsYou: 11, Failing: 5, Running: 2, Done: 4), actual: total);
    }

    /// The made-up pull requests go through the classifier, as GitHub's do, into the groups they're made for.
    [Fact]
    public void PutsTheMadeUpGitHubPullRequestsInTheGroupsTheyAreMadeFor()
    {
        var load = GitHubDemoData.Load(now: Times.At(seconds: 0));
        Assert.All(collection: GitHubPRGroups.All, action: group => Assert.Equal(expected: GitHubDemoData.ExpectedCounts[group], actual: load.Counts[group]));
        Assert.Null(@object: load.Notice);
        Assert.False(condition: load.MoreThanShown);
    }

    /// The made-up pull requests go through the classifier, as Azure DevOps' do, into the groups they're made for.
    [Fact]
    public void PutsTheMadeUpPullRequestsInTheGroupsTheyAreMadeFor()
    {
        var now = Times.At(seconds: 0);
        var settings = AzureDevOpsDemoData.Settings(storage: new MemorySettings(), now: now);
        var store = new PRStore(settings: settings);
        store.Receive(snapshot: AzureDevOpsDemoData.Snapshot(now: now), now: now);
        Assert.All(collection: PRGroups.All, action: group => Assert.Equal(expected: AzureDevOpsDemoData.ExpectedCounts[group], actual: store.Counts[group]));
        Assert.Null(@object: store.Problem);
        var answered = Assert.Single(collection: store.Items, predicate: item => item.Group == PRGroup.Answered);
        Assert.Equal(expected: PRReason.Answered, actual: answered.Reason);
        // Sam's reply on the pull request you've opened since still waits on you, no longer as new.
        var seen = Assert.Single(collection: store.Items, predicate: item => item.Key.Number == 4102);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: seen.Group);
        Assert.False(condition: seen.HasNews);
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
