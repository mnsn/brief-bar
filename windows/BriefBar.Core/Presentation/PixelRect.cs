using System.Globalization;
using BriefBar.Core.Logging;

namespace BriefBar.Core.Presentation;

/// A rectangle on the screen, in physical pixels.
public readonly record struct PixelRect(int Left, int Top, int Width, int Height) : ILoggable
{
    public int Right => Left + Width;

    public int Bottom => Top + Height;

    public int CenterX => Left + (Width / 2);

    public static PixelRect FromEdges(int left, int top, int right, int bottom) =>
        new(Left: left, Top: top, Width: right - left, Height: bottom - top);

    /// Whether it covers all of `other`, as a full-screen window covers its display.
    public bool Covers(PixelRect other) =>
        Left <= other.Left && Top <= other.Top && Right >= other.Right && Bottom >= other.Bottom;

    public bool Contains(int x, int y) => x >= Left && x < Right && y >= Top && y < Bottom;

    public override string ToString() =>
        string.Create(provider: CultureInfo.InvariantCulture, handler: $"{Left},{Top} {Width}x{Height}");
}
