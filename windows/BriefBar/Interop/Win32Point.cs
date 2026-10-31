using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// Win32's `POINT`, in physical pixels.
[StructLayout(LayoutKind.Sequential)]
internal struct Win32Point
{
    public int X;
    public int Y;
}
