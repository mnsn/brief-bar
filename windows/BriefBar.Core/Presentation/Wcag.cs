namespace BriefBar.Core.Presentation;

/// Contrast between colors, as WCAG 2.2 measures it: from 1 to 1, the same color, to 21 to 1, black on white.
public static class Wcag
{
    /// The least contrast for words.
    public const double TextContrast = 4.5;

    /// The least contrast for icons, dots and the edges of controls.
    public const double GraphicsContrast = 3;

    public static double Contrast(uint first, uint second)
    {
        var firstLuminance = Luminance(argb: first);
        var secondLuminance = Luminance(argb: second);
        var lighter = Math.Max(val1: firstLuminance, val2: secondLuminance);
        var darker = Math.Min(val1: firstLuminance, val2: secondLuminance);
        return (lighter + 0.05) / (darker + 0.05);
    }

    /// Relative luminance, from 0 for black to 1 for white. Alpha is ignored.
    public static double Luminance(uint argb) =>
        (0.2126 * Linear(channel: (argb >> 16) & 0xFF))
        + (0.7152 * Linear(channel: (argb >> 8) & 0xFF))
        + (0.0722 * Linear(channel: argb & 0xFF));

    static double Linear(uint channel)
    {
        var srgb = channel / 255.0;
        return srgb <= 0.04045 ? srgb / 12.92 : Math.Pow(x: (srgb + 0.055) / 1.055, y: 2.4);
    }
}
