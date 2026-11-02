namespace BriefBar.Core.Presentation;

/// The bar's size: 32 device-independent pixels at Windows' default text size, as tall as a window's title bar, and
/// taller as you make text bigger in Settings › Accessibility › Text size, up to 40.
public static class BarMetrics
{
    public const double BaseHeightDip = 32;
    public const double MaxHeightDip = 40;

    /// The sizes the bar's icons are drawn at, both sizes Fluent draws its icons for.
    public const double SmallIconDip = 16;
    public const double LargeIconDip = 20;

    /// `textScale` is Windows' text size: 1 at 100%, up to 2.25.
    public static double HeightDip(double textScale)
    {
        if (double.IsNaN(textScale) || textScale <= 0)
        {
            return BaseHeightDip;
        }
        return Math.Clamp(value: BaseHeightDip * textScale, min: BaseHeightDip, max: MaxHeightDip);
    }

    /// The size of the bar's icons, in device-independent pixels: 16, as with Windows' text at 100%, and 20 once
    /// Windows' text size makes 16 nearer 20, from 112.5%, as the bar's words and height grow. Fluent draws its icons
    /// for those sizes, so they stay sharp.
    public static double IconSize(double textScale)
    {
        if (double.IsNaN(textScale) || textScale <= 0)
        {
            return SmallIconDip;
        }
        var wanted = SmallIconDip * Math.Min(val1: textScale, val2: MaxHeightDip / BaseHeightDip);
        return wanted - SmallIconDip < LargeIconDip - wanted ? SmallIconDip : LargeIconDip;
    }

    /// In physical pixels, on a display at `displayScale` (1 at 100%, 1.5 at 150%).
    public static int HeightPixels(double textScale, double displayScale) =>
        (int)Math.Round(value: HeightDip(textScale: textScale) * displayScale, mode: MidpointRounding.AwayFromZero);
}
