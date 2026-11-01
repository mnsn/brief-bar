using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// `MONITORINFOEX`: a display's bounds, its work area and whether it's the main one.
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
internal struct MonitorInfoEx
{
    public int cbSize;
    public Win32Rect rcMonitor;
    public Win32Rect rcWork;
    public uint dwFlags;

    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
    public string szDevice;

    /// `dwFlags`' bit for the main display.
    public const uint MONITORINFOF_PRIMARY = 1;
}
