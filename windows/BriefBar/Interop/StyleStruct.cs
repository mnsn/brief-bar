using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// `STYLESTRUCT`, a window's styles as `WM_STYLECHANGING` is about to change them.
[StructLayout(LayoutKind.Sequential)]
internal struct StyleStruct
{
    public uint styleOld;
    public uint styleNew;
}
