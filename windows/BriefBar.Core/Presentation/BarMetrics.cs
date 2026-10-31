namespace BriefBar.Core.Presentation;

/// The bar's size: 32 device-independent pixels at Windows' default text size, as tall as a window's title bar, and
/// taller as you make text bigger in Settings › Accessibility › Text size, up to 40.
public static class BarMetrics
{
    public const double BaseHeightDip = 32;
    public const double MaxHeightDip = 40;

    /// `textScale` is Windows' text size: 1 at 100%, up to 2.25.
    public static double HeightDip(double textScale)
    {
        if (double.IsNaN(textScale) || textScale <= 0)
        {
            return BaseHeightDip;
        }
        return Math.Clamp(value: BaseHeightDip * textScale, min: BaseHeightDip, max: MaxHeightDip);
    }

    /// In physical pixels, on a display at `displayScale` (1 at 100%, 1.5 at 150%).
    public static int HeightPixels(double textScale, double displayScale) =>
        (int)Math.Round(value: HeightDip(textScale: textScale) * displayScale, mode: MidpointRounding.AwayFromZero);
}
