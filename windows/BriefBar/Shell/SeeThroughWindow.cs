using BriefBar.Interop;

namespace BriefBar.Shell;

/// Lets the desktop show through a window wherever its content is see-through, without blur: Windows blurs behind it
/// only over a region outside it, which leaves per-pixel transparency on and blurs nothing. Meanwhile, the window's own
/// background has to be painted black, which Windows shows as see-through (`EraseBlack`).
internal static class SeeThroughWindow
{
    /// Lets the desktop show through `hwnd`, and has its background, which its owner paints black from before this
    /// call on (`EraseBlack`), repainted at once: until then it keeps what WinUI painted, white in light or High
    /// Contrast's window color, as nothing else repaints it before the window is resized or shown again. False if
    /// Windows refused.
    public static bool Enable(nint hwnd)
    {
        var margins = new DwmMargins();
        var extended = Dwm.DwmExtendFrameIntoClientArea(hWnd: hwnd, margins: ref margins) == 0;
        var region = Gdi32.CreateRectRgn(left: -2, top: -2, right: -1, bottom: -1);
        try
        {
            var blur = new DwmBlurBehind
            {
                Flags = DwmBlurBehind.DWM_BB_ENABLE | DwmBlurBehind.DWM_BB_BLURREGION,
                Enable = true,
                Region = region,
            };
            var enabled = Dwm.DwmEnableBlurBehindWindow(hWnd: hwnd, blurBehind: ref blur) == 0 && extended;
            return EraseNow(hwnd: hwnd) && enabled;
        }
        finally
        {
            // Windows keeps a copy of the region.
            Gdi32.DeleteObject(handle: region);
        }
    }

    /// Stops letting the desktop show through `hwnd`, and has its background repainted at once, in WinUI's color again;
    /// false if Windows refused.
    public static bool Disable(nint hwnd)
    {
        var blur = new DwmBlurBehind { Flags = DwmBlurBehind.DWM_BB_ENABLE, Enable = false };
        var disabled = Dwm.DwmEnableBlurBehindWindow(hWnd: hwnd, blurBehind: ref blur) == 0;
        return EraseNow(hwnd: hwnd) && disabled;
    }

    /// Paints `hwnd`'s background black through `hdc`, which Windows shows as see-through while it's `Enable`d; false
    /// if it couldn't.
    public static bool EraseBlack(nint hwnd, nint hdc) =>
        User32.GetClientRect(hWnd: hwnd, rect: out var rect)
        && User32.FillRect(hdc: hdc, rect: ref rect, brush: Gdi32.GetStockObject(kind: Gdi32.BLACK_BRUSH)) != 0;

    /// Has Windows erase `hwnd`'s background now, through its `WM_ERASEBKGND`; false if it couldn't.
    static bool EraseNow(nint hwnd) =>
        User32.RedrawWindow(
            hWnd: hwnd, updateRect: 0, updateRegion: 0, flags: User32.RDW_INVALIDATE | User32.RDW_ERASE | User32.RDW_ERASENOW);
}
