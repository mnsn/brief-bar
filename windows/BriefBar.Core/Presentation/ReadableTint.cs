using System.Globalization;

namespace BriefBar.Core.Presentation;

/// A see-through color for the bar as it shows, so that its words read on any wallpaper behind it. The bar's words,
/// labels and state colors move toward white in dark (black in light) as far as they need (`StatePalette.ReadableWords`,
/// `StatePalette.Readable`), which reads 4.5 to 1 so long as white (or black) words would. Where they wouldn't, the
/// color shows more opaque, and where even opaque isn't enough, a shade darker (or lighter).
/// - `Color`: as it shows, ARGB.
/// - `IsDark`: whether its words are light, as in dark.
/// - `Chosen`: as it was asked for.
/// - `IsShaded`: it shows darker, or lighter, than chosen.
/// - `IsOpaqueForWindows`: it shows opaque because Transparency effects is off in Windows.
public sealed record ReadableTint(uint Color, bool IsDark, uint Chosen, bool IsShaded, bool IsOpaqueForWindows)
{
    const uint White = 0xFFFFFFFFu;
    const uint Black = 0xFF000000u;
    const uint Opaque = 0xFF000000u;

    /// It shows more opaque than chosen, so that its words read.
    public bool IsMoreOpaque => !IsOpaqueForWindows && (Color >> 24) > (Chosen >> 24);

    /// What the bar's colors are worked out against on it (`StatePalette.UnderSeeThrough`).
    public uint WorkedOutAgainst => StatePalette.UnderSeeThrough(tint: Color, dark: IsDark);

    /// What Settings says under the color when it doesn't show as chosen, or null when it does.
    public string? Note
    {
        get
        {
            var shade = IsDark ? "darker" : "lighter";
            if (IsOpaqueForWindows)
            {
                return IsShaded
                    ? $"Shown opaque, as Transparency effects is off in Windows, and a shade {shade}, so the bar's words stay readable."
                    : "Shown opaque, as Transparency effects is off in Windows.";
            }
            if (IsShaded)
            {
                return (Chosen >> 24) < 0xFF
                    ? $"Shown opaque and a shade {shade}, so the bar's words stay readable on any wallpaper."
                    : $"Shown a shade {shade}, so the bar's words stay readable.";
            }
            if (IsMoreOpaque)
            {
                var percent = Math.Round(value: (Color >> 24) * 100 / 255.0, mode: MidpointRounding.AwayFromZero);
                return string.Create(
                    provider: CultureInfo.InvariantCulture,
                    handler: $"Shown {percent}% opaque, so the bar's words stay readable on any wallpaper.");
            }
            return null;
        }
    }

    /// `chosen` as the bar can show it: with light words if `dark`, dark ones if not, or with whichever read better
    /// for null; opaque while `transparencyEffects` is off.
    public static ReadableTint Of(uint chosen, bool? dark, bool transparencyEffects)
    {
        var asked = transparencyEffects ? chosen : chosen | Opaque;
        var opaqueForWindows = !transparencyEffects && (chosen >> 24) < 0xFF;
        bool[] words = dark is { } fixedDark ? [fixedDark] : [true, false];
        for (var alpha = asked >> 24; alpha <= 0xFF; alpha++)
        {
            var color = (alpha << 24) | (asked & 0x00FFFFFFu);
            if (Best(color: color, words: words) is { } isDark)
            {
                return new ReadableTint(Color: color, IsDark: isDark, Chosen: chosen, IsShaded: false, IsOpaqueForWindows: opaqueForWindows);
            }
        }
        var opaque = asked | Opaque;
        var byContrast = words.OrderByDescending(keySelector: isDark => Contrast(color: opaque, dark: isDark)).ToList();
        for (var step = 1; step <= 20; step++)
        {
            foreach (var isDark in byContrast)
            {
                var shaded = StatePalette.Mix(from: opaque, to: isDark ? Black : White, amount: step / 20.0);
                if (Reads(color: shaded, dark: isDark))
                {
                    return new ReadableTint(Color: shaded, IsDark: isDark, Chosen: chosen, IsShaded: true, IsOpaqueForWindows: opaqueForWindows);
                }
            }
        }
        throw new InvalidOperationException(message: "White words read on black, and black words on white.");
    }

    /// Of `words`, whether its words are light, those that read on `color`, the better of two; null if neither does.
    static bool? Best(uint color, bool[] words)
    {
        bool? best = null;
        foreach (var isDark in words)
        {
            if (Reads(color: color, dark: isDark) && (best is not { } other || Contrast(color: color, dark: isDark) > Contrast(color: color, dark: other)))
            {
                best = isDark;
            }
        }
        return best;
    }

    static bool Reads(uint color, bool dark) => Contrast(color: color, dark: dark) >= Wcag.TextContrast;

    /// How far white words (in dark) or black ones stand apart from `color` over the wallpaper they stand out least on.
    static double Contrast(uint color, bool dark) =>
        Wcag.Contrast(first: dark ? White : Black, second: StatePalette.UnderSeeThrough(tint: color, dark: dark));
}
