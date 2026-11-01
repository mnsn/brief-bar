namespace BriefBar.Core.Presentation;

/// A bar window that can take a display: one showing on `Bounds` now, or, when it isn't `IsShowing`, a spare, hidden
/// and holding no space. `Dpi` is the window's scaling now, which Windows changes as it moves a window, hidden or not.
public readonly record struct BarCandidate(PixelRect Bounds, int Dpi, bool IsShowing);
