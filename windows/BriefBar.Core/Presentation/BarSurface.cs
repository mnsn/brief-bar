namespace BriefBar.Core.Presentation;

/// What the bar shows behind its words, and how its words read on it.
/// - `Material`: Windows' acrylic, which shows its flat color by itself where Windows draws no acrylic, or a color
///   over the desktop.
/// - `Color`: the acrylic's tint, or null for Windows' own; or the see-through color, ARGB.
/// - `IsDark`: whether its words are light, as in dark.
/// - `WorkedOutAgainst`: what its colors are worked out against, so they read wherever they show
///   (`StatePalette.Readable`).
public sealed record BarSurface(BarMaterial Material, uint? Color, bool IsDark, uint WorkedOutAgainst)
{
    /// The bar's surface for `background`, as chosen in Settings, with `customColor` when it's a color of your own: in
    /// Windows' colors (`look`, and the taskbar's `accent` shade while the taskbar shows the accent color), where Windows
    /// draws acrylic or not, as over Remote Desktop, and with Transparency effects on or off. High Contrast shows Windows'
    /// own colors, on acrylic, whatever was chosen. A custom color not chosen yet shows as Automatic.
    public static BarSurface For(
        BarBackground background, uint? customColor, ShellLook look, uint accent, bool drawsAcrylic, bool transparencyEffects, bool highContrast)
    {
        ArgumentNullException.ThrowIfNull(argument: look);
        uint? tint = look.UsesAccent && !highContrast ? accent | 0xFF000000u : null;
        if (!highContrast && background == BarBackground.CustomColor && customColor is { } color)
        {
            return SeeThrough(tint: ReadableTint.Of(chosen: color, dark: null, transparencyEffects: transparencyEffects));
        }
        if (!highContrast && background != BarBackground.LikeTheTaskbar && !drawsAcrylic && transparencyEffects)
        {
            var seeThrough = ((tint ?? StatePalette.Flat(dark: look.IsDark)) & 0x00FFFFFFu) | StatePalette.SeeThroughAlpha;
            return SeeThrough(tint: ReadableTint.Of(chosen: seeThrough, dark: look.IsDark, transparencyEffects: true));
        }
        return new BarSurface(
            Material: BarMaterial.Acrylic,
            Color: tint,
            IsDark: look.IsDark,
            WorkedOutAgainst: StatePalette.BarBackground(accent: tint, dark: look.IsDark));
    }

    static BarSurface SeeThrough(ReadableTint tint) =>
        new(Material: BarMaterial.SeeThrough, Color: tint.Color, IsDark: tint.IsDark, WorkedOutAgainst: tint.WorkedOutAgainst);
}
