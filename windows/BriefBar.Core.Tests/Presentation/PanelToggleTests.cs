using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

public sealed class PanelToggleTests
{
    static readonly PanelTarget copilot = PanelTarget.Of(section: SectionId.CopilotSessions);
    static readonly PanelTarget github = PanelTarget.Of(section: SectionId.GitHubPullRequests);
    static readonly nint firstBar = 1;
    static readonly nint secondBar = 2;

    [Fact]
    public void OpensClosesAndSwitchesPanels()
    {
        var toggle = new PanelToggle();
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, bar: firstBar, open: null, now: 1_000));
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: github, bar: firstBar, open: copilot, now: 2_000));
        Assert.Equal(expected: PanelToggleAction.Close, actual: toggle.Press(target: github, bar: firstBar, open: github, now: 3_000));
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: PanelTarget.Overview, bar: firstBar, open: null, now: 4_000));
    }

    [Fact]
    public void IgnoresAPressThatArrivesTwice()
    {
        var toggle = new PanelToggle();
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, bar: firstBar, open: null, now: 1_000));
        // The same press again, 130 ms later, would close the panel it opened.
        Assert.Equal(expected: PanelToggleAction.Ignore, actual: toggle.Press(target: copilot, bar: firstBar, open: copilot, now: 1_130));
        Assert.Equal(expected: PanelToggleAction.Close, actual: toggle.Press(target: copilot, bar: firstBar, open: copilot, now: 1_130 + 350));
    }

    [Fact]
    public void OpensTheSameItemsPanelUnderAnotherBar()
    {
        var toggle = new PanelToggle();
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, bar: firstBar, open: null, now: 1_000));
        // Copilot's panel is open under the first display's bar; on the second, nothing is.
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, bar: secondBar, open: null, now: 3_000));
        // There, it's now open, and the same item closes it.
        Assert.Equal(expected: PanelToggleAction.Close, actual: toggle.Press(target: copilot, bar: secondBar, open: copilot, now: 5_000));
    }

    [Fact]
    public void OpensUnderAnotherBarRightAfterAPressOnTheFirst()
    {
        var toggle = new PanelToggle();
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, bar: firstBar, open: null, now: 1_000));
        // The same item on the second display's bar, a moment later, is a press of its own, not the first one again.
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, bar: secondBar, open: null, now: 1_100));
        // A press there that arrives twice is still one press.
        Assert.Equal(expected: PanelToggleAction.Ignore, actual: toggle.Press(target: copilot, bar: secondBar, open: copilot, now: 1_230));
    }

    [Fact]
    public void OpensUnderAnotherBarRightAfterThePanelClosedUnderTheFirst()
    {
        var toggle = new PanelToggle();
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, bar: firstBar, open: null, now: 1_000));
        toggle.Closed(target: copilot, bar: firstBar, reason: PanelCloseReason.ClickElsewhere, now: 5_000);
        // Only a press on the first display's bar could have closed it.
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, bar: secondBar, open: null, now: 5_100));
        Assert.Equal(expected: PanelToggleAction.Ignore, actual: toggle.Press(target: copilot, bar: firstBar, open: null, now: 5_150));
    }

    [Fact]
    public void DoesntReopenAPanelThatThePressClosed()
    {
        var toggle = new PanelToggle();
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, bar: firstBar, open: null, now: 1_000));
        // The press moved focus from the panel, which closed, before it reached its item.
        toggle.Closed(target: copilot, bar: firstBar, reason: PanelCloseReason.OtherApp, now: 5_000);
        Assert.Equal(expected: PanelToggleAction.Ignore, actual: toggle.Press(target: copilot, bar: firstBar, open: null, now: 5_100));
        // Another item still opens.
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: github, bar: firstBar, open: null, now: 5_150));
        // And so does the same one, a moment later.
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, bar: firstBar, open: null, now: 5_000 + 600));
    }

    [Fact]
    public void DoesntReopenAPanelThatSeemedClickedElsewhere()
    {
        var toggle = new PanelToggle();
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, bar: firstBar, open: null, now: 1_000));
        toggle.Closed(target: copilot, bar: firstBar, reason: PanelCloseReason.ClickElsewhere, now: 5_000);
        Assert.Equal(expected: PanelToggleAction.Ignore, actual: toggle.Press(target: copilot, bar: firstBar, open: null, now: 5_100));
    }

    [Theory]
    [InlineData(PanelCloseReason.PressedAgain)]
    [InlineData(PanelCloseReason.Keyboard)]
    [InlineData(PanelCloseReason.EmptySpace)]
    [InlineData(PanelCloseReason.FullScreen)]
    [InlineData(PanelCloseReason.DisplaysChanged)]
    [InlineData(PanelCloseReason.Quitting)]
    public void ReopensAPanelThatClosedForAReasonAPressCantCause(PanelCloseReason reason)
    {
        var toggle = new PanelToggle();
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, bar: firstBar, open: null, now: 1_000));
        toggle.Closed(target: copilot, bar: firstBar, reason: reason, now: 5_000);
        Assert.Equal(expected: PanelToggleAction.Open, actual: toggle.Press(target: copilot, bar: firstBar, open: null, now: 5_100));
    }
}
