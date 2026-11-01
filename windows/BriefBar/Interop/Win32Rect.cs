using System.Runtime.InteropServices;
using BriefBar.Core.Presentation;

namespace BriefBar.Interop;

/// Win32's `RECT`: edges in physical pixels.
[StructLayout(LayoutKind.Sequential)]
internal struct Win32Rect
{
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;

    public static Win32Rect From(PixelRect rect) => new() { Left = rect.Left, Top = rect.Top, Right = rect.Right, Bottom = rect.Bottom };

    public readonly PixelRect ToPixelRect() => PixelRect.FromEdges(left: Left, top: Top, right: Right, bottom: Bottom);
}
