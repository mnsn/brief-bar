namespace BriefBar.Core.Presentation;

/// A display, as far as which bar window can take it: where it is, in physical pixels, and its scaling, in dots per
/// inch (96 at 100%).
public readonly record struct DisplayShape(PixelRect Bounds, int Dpi);
