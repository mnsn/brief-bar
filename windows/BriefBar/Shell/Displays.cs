using System.Runtime.InteropServices;
using BriefBar.Interop;

namespace BriefBar.Shell;

/// The displays as they are now.
internal static class Displays
{
    /// Every display, the main one first.
    public static IReadOnlyList<Display> All()
    {
        var monitors = new List<nint>();
        User32.EnumDisplayMonitors(
            hdc: 0,
            clip: 0,
            callback: (nint monitor, nint hdc, ref Win32Rect rect, nint data) =>
            {
                monitors.Add(item: monitor);
                return true;
            },
            data: 0);
        return monitors.Select(selector: monitor => Of(monitor: monitor))
            .OfType<Display>()
            .OrderByDescending(keySelector: display => display.IsPrimary)
            .ToList();
    }

    /// `monitor` as it is now, or null once it's gone.
    public static Display? Of(nint monitor)
    {
        var info = new MonitorInfoEx { cbSize = Marshal.SizeOf<MonitorInfoEx>(), szDevice = string.Empty };
        if (!User32.GetMonitorInfo(monitor: monitor, info: ref info))
        {
            return null;
        }
        var dpi = ShCore.GetDpiForMonitor(monitor: monitor, kind: ShCore.MDT_EFFECTIVE_DPI, dpiX: out var x, dpiY: out _) == 0 ? x : 96u;
        return new Display(
            Handle: monitor,
            Bounds: info.rcMonitor.ToPixelRect(),
            Work: info.rcWork.ToPixelRect(),
            Scale: dpi / 96.0,
            IsPrimary: (info.dwFlags & MonitorInfoEx.MONITORINFOF_PRIMARY) != 0);
    }
}
