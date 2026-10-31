using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

public sealed class BarItemContentTests
{
    static readonly DateTimeOffset now = Times.At(seconds: 0);

    [Fact]
    public void ShowsItsCountsInItsSectionsOrderWithNeedsYouEmphasized()
    {
        var item = BarItemContent.Of(snapshot: Snapshots.BusyCopilot(status: SectionStatus.Live), now: now);
        Assert.Equal(expected: "Copilot", actual: item.Label);
        Assert.Equal(expected: IconKey.Pulse, actual: item.Glyph);
        // Copilot's order, as on the Mac: needs you, running, done, stopped. The idle session isn't counted.
        Assert.Equal(
            expected: [(ItemState.NeedsYou, 2), (ItemState.Running, 1), (ItemState.Done, 1), (ItemState.Failing, 1)],
            actual: item.Chips.Select(selector: chip => (chip.State, chip.Count)));
        Assert.Equal(expected: [true, false, false, false], actual: item.Chips.Select(selector: chip => chip.IsEmphasized));
        // Copilot's stopped sessions show a warning, not a cross.
        Assert.Equal(expected: IconKey.Warning, actual: item.Chips[3].Icon);
        Assert.False(condition: item.IsQuiet);
        Assert.Equal(expected: BarItemBadge.None, actual: item.Badge);
        Assert.Null(@object: item.BadgeText);
    }

    [Fact]
    public void SaysItsCountsInWordsForTheTooltipAndNarrator()
    {
        var item = BarItemContent.Of(snapshot: Snapshots.BusyCopilot(status: SectionStatus.Live), now: now);
        Assert.Equal(
            expected: "GitHub Copilot sessions\nNeeds you: 2 · Running: 1 · Done or ready: 1 · Something's wrong: 1\nLive",
            actual: item.ToolTip);
        Assert.Equal(
            expected: "GitHub Copilot sessions: 2 need you, 1 running, 1 done or ready, 1 went wrong. Live",
            actual: item.AutomationName);
    }

    [Fact]
    public void IsQuietWithNothingToCount()
    {
        var item = BarItemContent.Of(snapshot: Snapshots.Chats(unread: 0), now: now);
        Assert.True(condition: item.IsQuiet);
        Assert.Empty(collection: item.Chips);
        Assert.Equal(expected: "Teams chats\nNothing new\nLive", actual: item.ToolTip);
        Assert.Equal(expected: "Teams chats: nothing new. Live", actual: item.AutomationName);
    }

    [Fact]
    public void ShowsNoCountsUntilItHasReadOrWhileItCant()
    {
        var starting = BarItemContent.Of(snapshot: SectionSnapshot.Starting(info: Sections.GitHubPullRequests), now: now);
        Assert.Equal(expected: BarItemBadge.Starting, actual: starting.Badge);
        Assert.Empty(collection: starting.Chips);
        Assert.False(condition: starting.IsQuiet);
        Assert.Equal(expected: "GitHub pull requests\nStarting…", actual: starting.ToolTip);

        var problem = new SectionStatus(
            Condition: SectionCondition.Problem,
            Problem: "GitHub needs you to sign in with the GitHub CLI: gh auth login.",
            ShortProblem: "Sign in");
        var signedOut = BarItemContent.Of(snapshot: Snapshots.BusyCopilot(status: problem), now: now);
        Assert.Equal(expected: BarItemBadge.Problem, actual: signedOut.Badge);
        Assert.Equal(expected: "Sign in", actual: signedOut.BadgeText);
        Assert.Empty(collection: signedOut.Chips);
        Assert.Equal(
            expected: "GitHub Copilot sessions. GitHub needs you to sign in with the GitHub CLI: gh auth login.",
            actual: signedOut.AutomationName);

        var paused = BarItemContent.Of(
            snapshot: Snapshots.BusyCopilot(status: new SectionStatus(Condition: SectionCondition.Paused)), now: now);
        Assert.Equal(expected: BarItemBadge.Paused, actual: paused.Badge);
        Assert.Equal(expected: "Review", actual: paused.BadgeText);
        Assert.Empty(collection: paused.Chips);
    }

    [Fact]
    public void KeepsItsLastCountsWhenARefreshFails()
    {
        var stale = new SectionStatus(Condition: SectionCondition.Stale, Problem: "Couldn't refresh: showing what was there at 9:39 AM.");
        var item = BarItemContent.Of(snapshot: Snapshots.BusyCopilot(status: stale), now: now);
        Assert.Equal(expected: BarItemBadge.Stale, actual: item.Badge);
        Assert.Equal(expected: 4, actual: item.Chips.Count);
        Assert.EndsWith(
            expectedEndString: "Couldn't refresh: showing what was there at 9:39 AM.",
            actualString: item.ToolTip,
            comparisonType: StringComparison.Ordinal);
    }

    [Fact]
    public void SaysWhenItLastRead()
    {
        var updated = Snapshots.Chats(unread: 2) with { Status = SectionStatus.Updated(time: now.AddSeconds(seconds: -20)) };
        var item = BarItemContent.Of(snapshot: updated, now: now);
        Assert.Equal(expected: "Teams chats\nNeeds you: 2\nUpdated 20 s ago", actual: item.ToolTip);
    }
}
