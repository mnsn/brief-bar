using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

/// Bar windows are kept, moved or hidden as displays change, never closed: closing one while a UI Automation client holds
/// on to it can crash BriefBar. And never more of them than the most displays there have been at once.
public sealed class BarArrangementTests
{
    static readonly PixelRect left = new(Left: 0, Top: 0, Width: 3840, Height: 2160);
    static readonly PixelRect right = new(Left: 3840, Top: 0, Width: 2560, Height: 1440);
    static readonly PixelRect laptop = new(Left: 0, Top: 0, Width: 1920, Height: 1200);
    static readonly PixelRect elsewhere = new(Left: -2560, Top: 0, Width: 2560, Height: 1440);

    [Fact]
    public void GivesEachDisplayANewWindowAtFirst()
    {
        var plan = BarArrangement.Plan(candidates: [], displays: [Shape(bounds: left, dpi: 144), Shape(bounds: right, dpi: 96)]);
        Assert.Equal(expected: [null, null], actual: plan.ForDisplays);
        Assert.Empty(collection: plan.SteppingAside);
    }

    [Fact]
    public void KeepsEveryBarWhereItIsWhenNothingMoved()
    {
        // Windows saying displays changed when they didn't, or a remote session reconnecting to the same monitors.
        var plan = BarArrangement.Plan(
            candidates: [Showing(bounds: left, dpi: 144), Showing(bounds: right, dpi: 96)],
            displays: [Shape(bounds: left, dpi: 144), Shape(bounds: right, dpi: 96)]);
        Assert.Equal(expected: [0, 1], actual: plan.ForDisplays);
        Assert.Empty(collection: plan.SteppingAside);
    }

    [Fact]
    public void MatchesBarsToTheirDisplaysWhateverTheirOrder()
    {
        var plan = BarArrangement.Plan(
            candidates: [Showing(bounds: right, dpi: 96), Showing(bounds: left, dpi: 144)],
            displays: [Shape(bounds: left, dpi: 144), Shape(bounds: right, dpi: 96)]);
        Assert.Equal(expected: [1, 0], actual: plan.ForDisplays);
        Assert.Empty(collection: plan.SteppingAside);
    }

    [Fact]
    public void HidesTheBarOfADisplayThatWent()
    {
        var plan = BarArrangement.Plan(
            candidates: [Showing(bounds: left, dpi: 144), Showing(bounds: right, dpi: 96)],
            displays: [Shape(bounds: left, dpi: 144)]);
        Assert.Equal(expected: [0], actual: plan.ForDisplays);
        Assert.Equal(expected: [1], actual: plan.SteppingAside);
    }

    [Fact]
    public void ShowsASpareAgainForADisplayThatCameBackAtItsScaling()
    {
        var plan = BarArrangement.Plan(
            candidates: [Showing(bounds: left, dpi: 144), Spare(dpi: 96)],
            displays: [Shape(bounds: left, dpi: 144), Shape(bounds: right, dpi: 96)]);
        Assert.Equal(expected: [0, 1], actual: plan.ForDisplays);
        Assert.Empty(collection: plan.SteppingAside);
    }

    [Fact]
    public void ShowsASpareAtAnotherScalingRatherThanMakingANewWindow()
    {
        // Windows changes a window's scaling as it moves it, hidden or not, as it does a new window's as it first shows.
        var plan = BarArrangement.Plan(
            candidates: [Showing(bounds: left, dpi: 144), Spare(dpi: 120)],
            displays: [Shape(bounds: left, dpi: 144), Shape(bounds: right, dpi: 96)]);
        Assert.Equal(expected: [0, 1], actual: plan.ForDisplays);
        Assert.Empty(collection: plan.SteppingAside);
    }

    [Fact]
    public void MovesAShowingBarToADisplayAtItsScalingBeforeShowingASpare()
    {
        // The display it showed on moved, as when displays are rearranged: the same window follows, rather than hiding
        // one and showing another.
        var plan = BarArrangement.Plan(
            candidates: [Showing(bounds: right, dpi: 96), Spare(dpi: 96)],
            displays: [Shape(bounds: elsewhere, dpi: 96)]);
        Assert.Equal(expected: [0], actual: plan.ForDisplays);
        Assert.Empty(collection: plan.SteppingAside);
    }

    [Fact]
    public void MovesABarToADisplayAtAnotherScalingRatherThanMakingANewWindow()
    {
        // From two monitors to a laptop's own display at another scaling: one bar moves there, the other steps aside.
        var plan = BarArrangement.Plan(
            candidates: [Showing(bounds: left, dpi: 144), Showing(bounds: right, dpi: 96)],
            displays: [Shape(bounds: laptop, dpi: 120)]);
        Assert.Equal(expected: [0], actual: plan.ForDisplays);
        Assert.Equal(expected: [1], actual: plan.SteppingAside);
    }

    [Fact]
    public void GivesEachDisplayAWindowAtItsScalingBeforeAnyOther()
    {
        // The first display could take the only bar, but the second is at its scaling.
        var plan = BarArrangement.Plan(
            candidates: [Showing(bounds: right, dpi: 96)],
            displays: [Shape(bounds: left, dpi: 192), Shape(bounds: elsewhere, dpi: 96)]);
        Assert.Equal(expected: [null, 0], actual: plan.ForDisplays);
        Assert.Empty(collection: plan.SteppingAside);
    }

    [Fact]
    public void MakesNoNewWindowWhenADisplayComesBackAgainAndAgain()
    {
        // A 100% display unplugged and plugged in again, beside a 200% one. As it goes, Windows moves its bar onto the
        // 200% display, so the bar steps aside at 200%.
        var first = BarArrangement.Plan(candidates: [], displays: [Shape(bounds: left, dpi: 192), Shape(bounds: right, dpi: 96)]);
        Assert.Equal(expected: [null, null], actual: first.ForDisplays);
        var unplugged = BarArrangement.Plan(
            candidates: [Showing(bounds: left, dpi: 192), Showing(bounds: right, dpi: 192)],
            displays: [Shape(bounds: left, dpi: 192)]);
        Assert.Equal(expected: [0], actual: unplugged.ForDisplays);
        Assert.Equal(expected: [1], actual: unplugged.SteppingAside);
        var pluggedIn = BarArrangement.Plan(
            candidates: [Showing(bounds: left, dpi: 192), Spare(dpi: 192)],
            displays: [Shape(bounds: left, dpi: 192), Shape(bounds: right, dpi: 96)]);
        Assert.Equal(expected: [0, 1], actual: pluggedIn.ForDisplays);
        Assert.Empty(collection: pluggedIn.SteppingAside);
    }

    [Fact]
    public void ReusesSparesAtADisplaysScalingFirst()
    {
        var plan = BarArrangement.Plan(
            candidates: [Spare(dpi: 96), Spare(dpi: 144), Spare(dpi: 96)],
            displays: [Shape(bounds: left, dpi: 96), Shape(bounds: right, dpi: 96), Shape(bounds: elsewhere, dpi: 96)]);
        Assert.Equal(expected: [0, 2, 1], actual: plan.ForDisplays);
        Assert.Empty(collection: plan.SteppingAside);
    }

    [Fact]
    public void NeverGivesOneWindowTwoDisplays()
    {
        var plan = BarArrangement.Plan(
            candidates: [Showing(bounds: left, dpi: 96)],
            displays: [Shape(bounds: left, dpi: 96), Shape(bounds: right, dpi: 96), Shape(bounds: elsewhere, dpi: 96)]);
        Assert.Equal(expected: [0, null, null], actual: plan.ForDisplays);
    }

    static BarCandidate Showing(PixelRect bounds, int dpi) => new(Bounds: bounds, Dpi: dpi, IsShowing: true);

    static BarCandidate Spare(int dpi) => new(Bounds: default, Dpi: dpi, IsShowing: false);

    static DisplayShape Shape(PixelRect bounds, int dpi) => new(Bounds: bounds, Dpi: dpi);
}
