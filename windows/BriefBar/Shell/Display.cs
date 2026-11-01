using BriefBar.Core.Presentation;

namespace BriefBar.Shell;

/// A display, in physical pixels: all of it (`Bounds`), what windows may use (`Work`), and its scaling (1 at 100%).
internal sealed record Display(nint Handle, PixelRect Bounds, PixelRect Work, double Scale, bool IsPrimary)
{
    /// Its scaling in dots per inch: 96 at 100%.
    public int Dpi => (int)Math.Round(value: Scale * 96, mode: MidpointRounding.AwayFromZero);

    /// What decides which bar window can take it (`BarArrangement`).
    public DisplayShape Shape => new(Bounds: Bounds, Dpi: Dpi);
}
