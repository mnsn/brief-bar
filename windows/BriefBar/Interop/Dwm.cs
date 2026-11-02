using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// dwmapi.dll: windows' corners and borders, whether a window is cloaked, and what shows through it.
internal static class Dwm
{
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(nint hWnd, int attribute, ref int value, int size);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(nint hWnd, int attribute, out int value, int size);

    [DllImport("dwmapi.dll")]
    public static extern int DwmExtendFrameIntoClientArea(nint hWnd, ref DwmMargins margins);

    [DllImport("dwmapi.dll")]
    public static extern int DwmEnableBlurBehindWindow(nint hWnd, ref DwmBlurBehind blurBehind);

    /// Sets a window's attribute to a number, such as its corners; false if Windows refused, as one older than Windows
    /// 11 would.
    public static bool TrySet(nint hWnd, int attribute, int value) =>
        DwmSetWindowAttribute(hWnd: hWnd, attribute: attribute, value: ref value, size: sizeof(int)) == 0;
}
