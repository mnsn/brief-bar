using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// `APPBARDATA`, what `SHAppBarMessage` reads and writes.
[StructLayout(LayoutKind.Sequential)]
internal struct AppBarData
{
    public int cbSize;
    public nint hWnd;
    public uint uCallbackMessage;
    public uint uEdge;
    public Win32Rect rc;
    public nint lParam;
}
