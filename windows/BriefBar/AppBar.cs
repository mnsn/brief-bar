using System.Runtime.InteropServices;

namespace BriefBar;

/// A display, in physical pixels, with its scaling.
internal sealed record Display(IntPtr Handle, Native.RECT Bounds, Native.RECT Work, double Scale, bool IsPrimary)
{
    public static List<Display> All()
    {
        var monitors = new List<IntPtr>();
        Native.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
            (IntPtr monitor, IntPtr hdc, ref Native.RECT rect, IntPtr data) => { monitors.Add(monitor); return true; }, IntPtr.Zero);
        return monitors.Select(Of).OfType<Display>().OrderByDescending(display => display.IsPrimary).ToList();
    }

    /// The display as it is now, or nil once it's gone.
    public static Display? Of(IntPtr monitor)
    {
        var info = new Native.MONITORINFOEX { cbSize = Marshal.SizeOf<Native.MONITORINFOEX>() };
        if (!Native.GetMonitorInfo(monitor, ref info)) return null;
        uint dpi = Native.GetDpiForMonitor(monitor, 0, out var x, out _) == 0 ? x : 96;
        return new Display(monitor, info.rcMonitor, info.rcWork, dpi / 96.0, (info.dwFlags & 1) != 0);
    }
}

/// Reserves a strip at the top of a display for a window, as the taskbar reserves its own, so maximized windows stay
/// below it: https://learn.microsoft.com/windows/win32/shell/application-desktop-toolbars
internal sealed class AppBar(IntPtr hwnd)
{
    /// What Windows sends the window about its bar, such as a full-screen app opening.
    public const uint CallbackMessage = Native.WM_APP + 1;

    bool registered;

    Native.APPBARDATA Data(Native.RECT rect = default) => new()
    {
        cbSize = Marshal.SizeOf<Native.APPBARDATA>(),
        hWnd = hwnd,
        uCallbackMessage = CallbackMessage,
        uEdge = Native.ABE_TOP,
        rc = rect,
    };

    public void Register()
    {
        if (registered) return;
        var data = Data();
        Native.SHAppBarMessage(Native.ABM_NEW, ref data);
        registered = true;
    }

    /// Where a bar `height` pixels tall can go at the top of `display`: below any bar already there.
    public Native.RECT Query(Native.RECT display, int height)
    {
        var data = Data(new Native.RECT { Left = display.Left, Top = display.Top, Right = display.Right, Bottom = display.Top + height });
        Native.SHAppBarMessage(Native.ABM_QUERYPOS, ref data);
        data.rc.Bottom = data.rc.Top + height;
        return data.rc;
    }

    /// Reserves `rect`, and returns what Windows reserved.
    public Native.RECT Reserve(Native.RECT rect)
    {
        var data = Data(rect);
        Native.SHAppBarMessage(Native.ABM_SETPOS, ref data);
        return data.rc;
    }

    public void Activated()
    {
        var data = Data();
        Native.SHAppBarMessage(Native.ABM_ACTIVATE, ref data);
    }

    public void Moved()
    {
        var data = Data();
        Native.SHAppBarMessage(Native.ABM_WINDOWPOSCHANGED, ref data);
    }

    /// Gives the space back.
    public void Remove()
    {
        if (!registered) return;
        var data = Data();
        Native.SHAppBarMessage(Native.ABM_REMOVE, ref data);
        registered = false;
    }

    /// Explorer restarted, and forgot every bar.
    public void Forget() => registered = false;
}
