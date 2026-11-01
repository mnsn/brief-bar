namespace BriefBar.Core.Presentation;

/// Where a panel opens: next to the bar, under its item (over it with the bar at the bottom), centered on the item as
/// far as the display's edges allow, and never wider or taller than the room there is. Sizes are in device-independent
/// pixels, which `scale` turns into physical ones.
public static class PanelPlacement
{
    public const double WidthDip = 420;
    public const double MaxHeightDip = 600;
    /// Between the bar and the panel.
    public const double GapDip = 6;
    /// Between the panel and the display's edges.
    public const double MarginDip = 8;
    /// The least a panel asks for, even when its content is shorter: room for its header and a few rows.
    public const double MinHeightDip = 160;

    /// The panel's rectangle, for content `contentHeightDip` tall, under an item at `anchor` on a bar at `bar`, on a
    /// display whose work area, without the bar and the taskbar, is `workArea`.
    public static PixelRect Place(
        PixelRect workArea, PixelRect bar, PixelRect anchor, BarEdge edge, double contentHeightDip, double scale)
    {
        if (scale <= 0 || double.IsNaN(scale))
        {
            throw new ArgumentOutOfRangeException(paramName: nameof(scale), actualValue: scale, message: "Scaling must be positive.");
        }
        var margin = Pixels(dip: MarginDip, scale: scale);
        var gap = Pixels(dip: GapDip, scale: scale);
        var width = Math.Min(val1: Pixels(dip: WidthDip, scale: scale), val2: Math.Max(val1: 0, val2: workArea.Width - (2 * margin)));
        var room = edge == BarEdge.Top
            ? workArea.Bottom - (bar.Bottom + gap) - margin
            : bar.Top - gap - workArea.Top - margin;
        var wantedDip = Math.Min(val1: Math.Max(val1: contentHeightDip, val2: MinHeightDip), val2: MaxHeightDip);
        var height = Math.Max(val1: 0, val2: Math.Min(val1: Pixels(dip: wantedDip, scale: scale), val2: room));
        var lowest = workArea.Left + margin;
        var left = Math.Clamp(
            value: anchor.CenterX - (width / 2),
            min: lowest,
            max: Math.Max(val1: lowest, val2: workArea.Right - margin - width));
        var top = edge == BarEdge.Top ? bar.Bottom + gap : bar.Top - gap - height;
        return new PixelRect(Left: left, Top: top, Width: width, Height: height);
    }

    static int Pixels(double dip, double scale) =>
        (int)Math.Round(value: dip * scale, mode: MidpointRounding.AwayFromZero);
}
