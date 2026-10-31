using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

public sealed class PanelToggleTests
{
    static readonly PanelTarget copilot = PanelTarget.Of(section: SectionId.CopilotSessions);
    static readonly PanelTarget github = PanelTarget.Of(section: SectionId.GitHubPullRequests);

    [Fact]
    public void OpensClosesAndSwitchesPanels()
    {
        var toggle = new PanelToggle();
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, open: null, now: 1_000));
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: github, open: copilot, now: 2_000));
        Assert.Equal(expected: PanelToggleAction.Close, actual: toggle.Press(target: github, open: github, now: 3_000));
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: PanelTarget.Overview, open: null, now: 4_000));
    }

    [Fact]
    public void IgnoresAPressThatArrivesTwice()
    {
        var toggle = new PanelToggle();
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, open: null, now: 1_000));
        // The same press again, 130 ms later, would close the panel it opened.
        Assert.Equal(expected: PanelToggleAction.Ignore, actual: toggle.Press(target: copilot, open: copilot, now: 1_130));
        Assert.Equal(expected: PanelToggleAction.Close, actual: toggle.Press(target: copilot, open: copilot, now: 1_130 + 350));
    }

    [Fact]
    public void OpensTheSameItemsPanelUnderAnotherBar()
    {
        var toggle = new PanelToggle();
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, open: null, now: 1_000));
        // Copilot's panel is open under the first display's bar; on the second, nothing is.
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, open: null, now: 3_000));
        // There, it's now open, and the same item closes it.
        Assert.Equal(expected: PanelToggleAction.Close, actual: toggle.Press(target: copilot, open: copilot, now: 5_000));
    }

    [Fact]
    public void DoesntReopenAPanelThatThePressClosed()
    {
        var toggle = new PanelToggle();
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, open: null, now: 1_000));
        // The press moved focus from the panel, which closed, before it reached its item.
        toggle.Closed(target: copilot, now: 5_000);
        Assert.Equal(expected: PanelToggleAction.Ignore, actual: toggle.Press(target: copilot, open: null, now: 5_100));
        // Another item still opens.
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: github, open: null, now: 5_150));
        // And so does the same one, a moment later.
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, open: null, now: 5_000 + 600));
    }
}
