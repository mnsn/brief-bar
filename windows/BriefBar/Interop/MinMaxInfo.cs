using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// `MINMAXINFO`, a window's smallest and largest sizes, from `WM_GETMINMAXINFO`.
[StructLayout(LayoutKind.Sequential)]
internal struct MinMaxInfo
{
    public Win32Point ptReserved;
    public Win32Point ptMaxSize;
    public Win32Point ptMaxPosition;
    public Win32Point ptMinTrackSize;
    public Win32Point ptMaxTrackSize;
}
