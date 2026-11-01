using BriefBar.Core.Copilot;
using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests;

public sealed class SourceCatalogTests
{
    [Fact]
    public void ListsWhatWindowsHasWithWhatItSaysItReads()
    {
        var copilot = Assert.Single(collection: SourceCatalog.OnWindows);
        Assert.Equal(expected: SourceId.Copilot, actual: copilot.Id);
        Assert.Equal(expected: "GitHub Copilot", actual: copilot.Name);
        Assert.Same(expected: CopilotSource.Description, actual: copilot.Description);
        Assert.Equal(expected: [Sections.CopilotSessions], actual: copilot.Sections);
    }

    [Fact]
    public void NamesTheSourcesStillToCome()
    {
        Assert.Equal(expected: "Azure DevOps, GitHub, and Microsoft Teams", actual: SourceCatalog.StillToCome);
    }

    [Fact]
    public void ListsNamesAsWindowsWritesThem()
    {
        Assert.Equal(expected: string.Empty, actual: ListWords.Join(names: []));
        Assert.Equal(expected: "A", actual: ListWords.Join(names: ["A"]));
        Assert.Equal(expected: "A and B", actual: ListWords.Join(names: ["A", "B"]));
        Assert.Equal(expected: "A, B, and C", actual: ListWords.Join(names: ["A", "B", "C"]));
    }

    /// A source that reads more than you saw reads nothing, and says so, with a way to review it.
    [Fact]
    public async Task APausedSourceReadsNothingAndAsksForAReview()
    {
        var paused = new PausedSource(source: SourceId.Copilot, sections: [Sections.CopilotSessions]);
        await paused.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        var snapshot = paused.Snapshot(section: SectionId.CopilotSessions);
        Assert.Equal(expected: SectionCondition.Paused, actual: snapshot.Status.Condition);
        Assert.Empty(collection: snapshot.Rows);
        Assert.Equal(expected: new StateCounts(), actual: snapshot.Counts);
        var review = Assert.Single(collection: snapshot.Commands);
        Assert.Equal(expected: AppCommands.ReviewSource, actual: review.Key);
        Assert.True(condition: review.Opens);
        Assert.Throws<ArgumentException>(testCode: () => paused.Snapshot(section: SectionId.TeamsChats));
        await paused.StopAsync();
    }
}
