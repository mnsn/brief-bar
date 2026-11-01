using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

public sealed class PanelPlacementTests
{
    [Fact]
    public void OpensUnderItsItemAndStaysOnItsDisplay()
    {
        // A 2560 × 1440 display at 100%, right of another, with the bar at its top and a 48-pixel taskbar.
        var workArea = new PixelRect(Left: 3840, Top: 32, Width: 2560, Height: 1360);
        var bar = new PixelRect(Left: 3840, Top: 0, Width: 2560, Height: 32);
        var middle = new PixelRect(Left: 5000, Top: 0, Width: 90, Height: 32);
        var nearTheRight = new PixelRect(Left: 6300, Top: 0, Width: 90, Height: 32);

        var centered = PanelPlacement.Place(
            workArea: workArea, bar: bar, anchor: middle, edge: BarEdge.Top, contentHeightDip: 500, scale: 1);
        Assert.Equal(expected: new PixelRect(Left: 4835, Top: 38, Width: 420, Height: 500), actual: centered);

        var kept = PanelPlacement.Place(
            workArea: workArea, bar: bar, anchor: nearTheRight, edge: BarEdge.Top, contentHeightDip: 500, scale: 1);
        Assert.Equal(expected: 6400 - 8 - 420, actual: kept.Left);
    }

    [Fact]
    public void ScalesWithItsDisplay()
    {
        // A 3840 × 2160 display at 150%: a 48-pixel bar and a 72-pixel taskbar.
        var workArea = new PixelRect(Left: 0, Top: 48, Width: 3840, Height: 2040);
        var bar = new PixelRect(Left: 0, Top: 0, Width: 3840, Height: 48);
        var nearTheLeft = new PixelRect(Left: 100, Top: 0, Width: 300, Height: 48);
        var panel = PanelPlacement.Place(
            workArea: workArea, bar: bar, anchor: nearTheLeft, edge: BarEdge.Top, contentHeightDip: 900, scale: 1.5);
        // 420 × 600 device-independent pixels at most, 12 pixels in from the display's edge, 9 under the bar.
        Assert.Equal(expected: new PixelRect(Left: 12, Top: 57, Width: 630, Height: 900), actual: panel);
    }

    [Fact]
    public void IsNeverWiderThanTheDisplay()
    {
        // A narrow display, 600 pixels wide at 150%: a panel 630 pixels wide wouldn't fit.
        var workArea = new PixelRect(Left: 0, Top: 48, Width: 600, Height: 680);
        var bar = new PixelRect(Left: 0, Top: 0, Width: 600, Height: 48);
        var item = new PixelRect(Left: 500, Top: 0, Width: 100, Height: 48);
        var panel = PanelPlacement.Place(workArea: workArea, bar: bar, anchor: item, edge: BarEdge.Top, contentHeightDip: 300, scale: 1.5);
        Assert.Equal(expected: 600 - (2 * 12), actual: panel.Width);
        Assert.Equal(expected: 12, actual: panel.Left);
        Assert.True(condition: panel.Right <= workArea.Right - 12);
    }

    [Fact]
    public void IsNeverTallerThanTheRoomThereIs()
    {
        var workArea = new PixelRect(Left: 0, Top: 32, Width: 1280, Height: 300);
        var bar = new PixelRect(Left: 0, Top: 0, Width: 1280, Height: 32);
        var item = new PixelRect(Left: 600, Top: 0, Width: 80, Height: 32);
        var panel = PanelPlacement.Place(workArea: workArea, bar: bar, anchor: item, edge: BarEdge.Top, contentHeightDip: 600, scale: 1);
        Assert.Equal(expected: 332 - 38 - 8, actual: panel.Height);
        Assert.True(condition: panel.Bottom <= workArea.Bottom - 8);
    }

    [Fact]
    public void AsksForAtLeastRoomForItsHeaderAndAFewRows()
    {
        var workArea = new PixelRect(Left: 0, Top: 32, Width: 1280, Height: 1000);
        var bar = new PixelRect(Left: 0, Top: 0, Width: 1280, Height: 32);
        var item = new PixelRect(Left: 600, Top: 0, Width: 80, Height: 32);
        var panel = PanelPlacement.Place(workArea: workArea, bar: bar, anchor: item, edge: BarEdge.Top, contentHeightDip: 40, scale: 1);
        Assert.Equal(expected: (int)PanelPlacement.MinHeightDip, actual: panel.Height);
    }

    [Fact]
    public void OpensOverItsItemWithTheBarAtTheBottom()
    {
        // The bar sits on the taskbar: the work area ends where the bar starts.
        var workArea = new PixelRect(Left: 0, Top: 0, Width: 2560, Height: 1360);
        var bar = new PixelRect(Left: 0, Top: 1360, Width: 2560, Height: 32);
        var item = new PixelRect(Left: 2000, Top: 1360, Width: 100, Height: 32);
        var panel = PanelPlacement.Place(workArea: workArea, bar: bar, anchor: item, edge: BarEdge.Bottom, contentHeightDip: 300, scale: 1);
        Assert.Equal(expected: new PixelRect(Left: 1840, Top: 1360 - 6 - 300, Width: 420, Height: 300), actual: panel);
    }

    [Theory]
    [InlineData(0.0)]
    [InlineData(-1.0)]
    [InlineData(double.NaN)]
    public void RefusesScalingThatIsntPositive(double scale)
    {
        var rect = new PixelRect(Left: 0, Top: 0, Width: 100, Height: 100);
        Assert.Throws<ArgumentOutOfRangeException>(testCode: () =>
            PanelPlacement.Place(workArea: rect, bar: rect, anchor: rect, edge: BarEdge.Top, contentHeightDip: 100, scale: scale));
    }
}
