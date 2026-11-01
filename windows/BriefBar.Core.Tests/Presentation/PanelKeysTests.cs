using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

public sealed class PanelKeysTests
{
    static readonly PanelTarget copilot = PanelTarget.Of(section: SectionId.CopilotSessions);
    static readonly PanelTarget azureDevOps = PanelTarget.Of(section: SectionId.AzureDevOpsPullRequests);
    static readonly PanelTarget github = PanelTarget.Of(section: SectionId.GitHubPullRequests);
    static readonly IReadOnlyList<PanelTarget> bar = [PanelTarget.Overview, copilot, azureDevOps, github];

    [Fact]
    public void NumbersTheOverviewFirstThenTheItemsInOrderUpToNine()
    {
        Assert.Equal(expected: "Ctrl+1", actual: PanelKeys.Words(position: 0));
        Assert.Equal(expected: "Ctrl+2", actual: PanelKeys.Words(position: 1));
        Assert.Equal(expected: "Ctrl+9", actual: PanelKeys.Words(position: 8));
        Assert.Null(@object: PanelKeys.Words(position: 9));
        Assert.Null(@object: PanelKeys.Words(position: -1));
    }

    [Fact]
    public void ShowsTheItemWithTheNumberPressed()
    {
        Assert.Equal(expected: PanelTarget.Overview, actual: PanelKeys.Numbered(targets: bar, number: 1));
        Assert.Equal(expected: copilot, actual: PanelKeys.Numbered(targets: bar, number: 2));
        Assert.Equal(expected: github, actual: PanelKeys.Numbered(targets: bar, number: 4));
        // A number past the bar's last item, or without a key, shows nothing.
        Assert.Null(@object: PanelKeys.Numbered(targets: bar, number: 5));
        Assert.Null(@object: PanelKeys.Numbered(targets: bar, number: 0));
        var many = Enumerable.Repeat(element: copilot, count: 12).ToList();
        Assert.Null(@object: PanelKeys.Numbered(targets: many, number: 10));
    }

    [Fact]
    public void GoesToTheNextItemAndTheOneBeforeAround()
    {
        Assert.Equal(expected: azureDevOps, actual: PanelKeys.Next(targets: bar, current: copilot, backward: false));
        Assert.Equal(expected: PanelTarget.Overview, actual: PanelKeys.Next(targets: bar, current: copilot, backward: true));
        Assert.Equal(expected: PanelTarget.Overview, actual: PanelKeys.Next(targets: bar, current: github, backward: false));
        Assert.Equal(expected: github, actual: PanelKeys.Next(targets: bar, current: PanelTarget.Overview, backward: true));
    }

    [Fact]
    public void StartsAtAnEndWhenTheOpenItemLeftTheBar()
    {
        // Teams' panel stays open after its source was turned off, so its item is gone from the bar.
        var teams = PanelTarget.Of(section: SectionId.TeamsChats);
        Assert.Equal(expected: PanelTarget.Overview, actual: PanelKeys.Next(targets: bar, current: teams, backward: false));
        Assert.Equal(expected: github, actual: PanelKeys.Next(targets: bar, current: teams, backward: true));
    }

    [Fact]
    public void ShowsNothingElseWithNothingElseInTheBar()
    {
        IReadOnlyList<PanelTarget> overviewOnly = [PanelTarget.Overview];
        Assert.Null(@object: PanelKeys.Next(targets: overviewOnly, current: PanelTarget.Overview, backward: false));
        Assert.Null(@object: PanelKeys.Next(targets: overviewOnly, current: PanelTarget.Overview, backward: true));
        Assert.Null(@object: PanelKeys.Next(targets: [], current: PanelTarget.Overview, backward: false));
    }
}
