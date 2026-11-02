using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// `MARGINS`: how far the window's frame reaches into it, from each edge.
[StructLayout(LayoutKind.Sequential)]
internal struct DwmMargins
{
    public int Left;
    public int Right;
    public int Top;
    public int Bottom;
}
