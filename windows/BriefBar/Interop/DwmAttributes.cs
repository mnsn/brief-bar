namespace BriefBar.Interop;

/// The Desktop Window Manager's attributes BriefBar reads and sets.
internal static class DwmAttributes
{
    public const int DWMWA_CLOAKED = 14;
    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    public const int DWMWA_BORDER_COLOR = 34;

    public const int DWMWCP_DONOTROUND = 1;
    public const int DWMWCP_ROUND = 2;

    /// `DWMWA_BORDER_COLOR`'s value for no border at all.
    public const int DWMWA_COLOR_NONE = unchecked((int)0xFFFFFFFE);
}
