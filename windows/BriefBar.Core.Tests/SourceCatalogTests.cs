using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Copilot;
using BriefBar.Core.GitHub;
using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests;

public sealed class SourceCatalogTests
{
    [Fact]
    public void ListsWhatWindowsHasWithWhatItSaysItReads()
    {
        Assert.Equal(expected: [SourceId.AzureDevOps, SourceId.Copilot, SourceId.GitHub], actual: SourceCatalog.OnWindows.Select(selector: entry => entry.Id));
        var azureDevOps = SourceCatalog.OnWindows[0];
        Assert.Equal(expected: "Azure DevOps", actual: azureDevOps.Name);
        Assert.Same(expected: AzureDevOpsSource.Description, actual: azureDevOps.Description);
        Assert.Equal(expected: [Sections.AzureDevOpsPullRequests], actual: azureDevOps.Sections);
        var copilot = SourceCatalog.OnWindows[1];
        Assert.Equal(expected: SourceId.Copilot, actual: copilot.Id);
        Assert.Equal(expected: "GitHub Copilot", actual: copilot.Name);
        Assert.Same(expected: CopilotSource.Description, actual: copilot.Description);
        Assert.Equal(expected: [Sections.CopilotSessions], actual: copilot.Sections);
        var gitHub = SourceCatalog.OnWindows[2];
        Assert.Equal(expected: SourceId.GitHub, actual: gitHub.Id);
        Assert.Equal(expected: "GitHub", actual: gitHub.Name);
        Assert.Same(expected: GitHubSource.Description, actual: gitHub.Description);
        Assert.Equal(expected: [Sections.GitHubPullRequests], actual: gitHub.Sections);
        Assert.Equal(expected: Sections.GitHubPullRequests.Glyph, actual: gitHub.Glyph);
        Assert.Equal(expected: Sections.GitHubPullRequests.Tint, actual: gitHub.Tint);
    }

    [Fact]
    public void NamesTheSourcesStillToCome()
    {
        Assert.Equal(expected: "Microsoft Teams", actual: SourceCatalog.StillToCome);
    }

    [Fact]
    public void ListsNamesAsWindowsWritesThem()
    {
        Assert.Equal(expected: string.Empty, actual: ListWords.Join(names: []));
        Assert.Equal(expected: "A", actual: ListWords.Join(names: ["A"]));
        Assert.Equal(expected: "A and B", actual: ListWords.Join(names: ["A", "B"]));
        Assert.Equal(expected: "A, B, and C", actual: ListWords.Join(names: ["A", "B", "C"]));
        // Past a limit, the first names and how many more, as the Mac's `PullRequestStory.names` says them.
        Assert.Equal(expected: "A, B, and C", actual: ListWords.Join(names: ["A", "B", "C"], limit: 3));
        Assert.Equal(expected: "A, B, C, and 2 more", actual: ListWords.Join(names: ["A", "B", "C", "D", "E"], limit: 3));
        Assert.Equal(expected: "A and 1 more", actual: ListWords.Join(names: ["A", "B"], limit: 1));
        Assert.Throws<ArgumentOutOfRangeException>(testCode: () => ListWords.Join(names: ["A"], limit: 0));
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
