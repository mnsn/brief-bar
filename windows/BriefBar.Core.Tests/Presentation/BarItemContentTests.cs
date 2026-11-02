using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

public sealed class BarItemContentTests
{
    static readonly DateTimeOffset now = Times.At(seconds: 0);

    [Fact]
    public void ShowsItsCountsInItsSectionsOrderWithEachStatesIcon()
    {
        var item = BarItemContent.Of(snapshot: Snapshots.BusyCopilot(status: SectionStatus.Live), position: 1, now: now);
        Assert.Equal(expected: "Copilot", actual: item.Label);
        Assert.Equal(expected: IconKey.Pulse, actual: item.Glyph);
        // Copilot's order, as on the Mac: needs you, running, done, stopped. The idle session isn't counted.
        Assert.Equal(
            expected: [(ItemState.NeedsYou, 2), (ItemState.Running, 1), (ItemState.Done, 1), (ItemState.Failing, 1)],
            actual: item.Chips.Select(selector: chip => (chip.State, chip.Count)));
        // Needs you is a raised hand, as on the Mac, and Copilot's stopped sessions show a warning, not a cross.
        Assert.Equal(
            expected: [IconKey.HandRaise, IconKey.Flash, IconKey.CheckmarkCircle, IconKey.Warning],
            actual: item.Chips.Select(selector: chip => chip.Icon));
        Assert.False(condition: item.IsQuiet);
        Assert.Equal(expected: BarItemBadge.None, actual: item.Badge);
        Assert.Null(@object: item.BadgeText);
    }

    [Fact]
    public void SaysItsCountsInWordsForTheTooltipAndNarrator()
    {
        var item = BarItemContent.Of(snapshot: Snapshots.BusyCopilot(status: SectionStatus.Live), position: 1, now: now);
        Assert.Equal(
            expected: "GitHub Copilot sessions (Ctrl+2)\nNeeds you: 2 · Running: 1 · Done or ready: 1 · Something's wrong: 1\nLive",
            actual: item.ToolTip);
        Assert.Equal(
            expected: "GitHub Copilot sessions: 2 need you, 1 running, 1 done or ready, 1 went wrong. Live",
            actual: item.AutomationName);
    }

    [Fact]
    public void IsQuietWithNothingToCount()
    {
        var item = BarItemContent.Of(snapshot: Snapshots.Chats(unread: 0), position: 1, now: now);
        Assert.True(condition: item.IsQuiet);
        Assert.Empty(collection: item.Chips);
        Assert.Equal(expected: "Teams chats (Ctrl+2)\nNothing new\nLive", actual: item.ToolTip);
        Assert.Equal(expected: "Teams chats: nothing new. Live", actual: item.AutomationName);
    }

    [Fact]
    public void ShowsNoCountsUntilItHasReadOrWhileItCant()
    {
        var starting = BarItemContent.Of(snapshot: SectionSnapshot.Starting(info: Sections.GitHubPullRequests), position: 1, now: now);
        Assert.Equal(expected: BarItemBadge.Starting, actual: starting.Badge);
        Assert.Empty(collection: starting.Chips);
        Assert.False(condition: starting.IsQuiet);
        Assert.Equal(expected: "GitHub pull requests (Ctrl+2)\nStarting…", actual: starting.ToolTip);

        var problem = new SectionStatus(
            Condition: SectionCondition.Problem,
            Problem: "GitHub needs you to sign in with the GitHub CLI: gh auth login.",
            ShortProblem: "Sign in");
        var signedOut = BarItemContent.Of(snapshot: Snapshots.BusyCopilot(status: problem), position: 1, now: now);
        Assert.Equal(expected: BarItemBadge.Problem, actual: signedOut.Badge);
        Assert.Equal(expected: "Sign in", actual: signedOut.BadgeText);
        Assert.Empty(collection: signedOut.Chips);
        Assert.Equal(
            expected: "GitHub Copilot sessions. GitHub needs you to sign in with the GitHub CLI: gh auth login.",
            actual: signedOut.AutomationName);

        var paused = BarItemContent.Of(
            snapshot: Snapshots.BusyCopilot(status: new SectionStatus(Condition: SectionCondition.Paused)), position: 1, now: now);
        Assert.Equal(expected: BarItemBadge.Paused, actual: paused.Badge);
        Assert.Equal(expected: "Review", actual: paused.BadgeText);
        Assert.Empty(collection: paused.Chips);
    }

    [Fact]
    public void KeepsItsLastCountsWhenARefreshFails()
    {
        var stale = new SectionStatus(Condition: SectionCondition.Stale, Problem: "Couldn't refresh: showing what was there at 9:39 AM.");
        var item = BarItemContent.Of(snapshot: Snapshots.BusyCopilot(status: stale), position: 1, now: now);
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
        var item = BarItemContent.Of(snapshot: updated, position: 1, now: now);
        Assert.Equal(expected: "Teams chats (Ctrl+2)\nNeeds you: 2\nUpdated 20 s ago", actual: item.ToolTip);
    }

    [Fact]
    public void SaysTheKeyThatShowsItsPanelByItsPlaceInTheBar()
    {
        var snapshot = Snapshots.Chats(unread: 0);
        // The Overview's item is first, with Ctrl+1; the first section's is second.
        var first = BarItemContent.Of(snapshot: snapshot, position: 1, now: now);
        Assert.Equal(expected: "Ctrl+2", actual: first.Key);
        var ninth = BarItemContent.Of(snapshot: snapshot, position: 8, now: now);
        Assert.Equal(expected: "Ctrl+9", actual: ninth.Key);
        Assert.StartsWith(expectedStartString: "Teams chats (Ctrl+9)\n", actualString: ninth.ToolTip, comparisonType: StringComparison.Ordinal);
        // Past the ninth, an item has no key, and its tooltip says none.
        var tenth = BarItemContent.Of(snapshot: snapshot, position: 9, now: now);
        Assert.Null(@object: tenth.Key);
        Assert.Equal(expected: "Teams chats\nNothing new\nLive", actual: tenth.ToolTip);
        // Narrator hears no key: it says what the item shows.
        Assert.Equal(expected: first.AutomationName, actual: tenth.AutomationName);
    }
}
