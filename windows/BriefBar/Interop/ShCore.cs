using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// shcore.dll: each display's scaling.
internal static class ShCore
{
    /// `GetDpiForMonitor`'s kind for the scaling Windows applies, which the bar follows.
    public const int MDT_EFFECTIVE_DPI = 0;

    [DllImport("shcore.dll")]
    public static extern int GetDpiForMonitor(nint monitor, int kind, out uint dpiX, out uint dpiY);
}
