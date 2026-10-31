using BriefBar.Core.Presentation;

namespace BriefBar.Shell;

/// A display, in physical pixels: all of it (`Bounds`), what windows may use (`Work`), and its scaling (1 at 100%).
internal sealed record Display(nint Handle, PixelRect Bounds, PixelRect Work, double Scale, bool IsPrimary);
