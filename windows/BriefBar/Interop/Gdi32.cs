using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// The parts of gdi32.dll the bar needs to let the desktop show through it.
internal static class Gdi32
{
    /// `GetStockObject`'s black brush, which a window letting the desktop show through paints as see-through.
    public const int BLACK_BRUSH = 4;

    [DllImport("gdi32.dll")]
    public static extern nint CreateRectRgn(int left, int top, int right, int bottom);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DeleteObject(nint handle);

    [DllImport("gdi32.dll")]
    public static extern nint GetStockObject(int kind);
}
