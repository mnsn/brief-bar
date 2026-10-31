namespace BriefBar.Core.Presentation;

/// The states' colors, as ARGB, for Windows 11's light and dark: fills for icons, dots and badges; text for words;
/// what's drawn on a fill; Needs You's pill; and a caution color for problems. Windows' semantic colors where it has
/// them (red, blue, green, caution), and the Mac's orange for what needs you. `StatePaletteTests` checks their contrast
/// against `Background`, the color of the bar and the panel without their acrylic: 4.5 to 1 for words, 3 to 1 for the
/// rest. In High Contrast, the app uses the system's colors instead.
public static class StatePalette
{
    public static uint Fill(ItemState state, bool dark) => state switch
    {
        ItemState.NeedsYou => dark ? 0xFFFF8C3Au : 0xFFE3640Cu,
        ItemState.Failing => dark ? 0xFFFF6B70u : 0xFFC42B1Cu,
        ItemState.Running => dark ? 0xFF479EF5u : 0xFF0F6CBDu,
        ItemState.Done => dark ? 0xFF6CCB5Fu : 0xFF0F7B0Fu,
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(state), actualValue: state, message: "Not a state."),
    };

    public static uint Text(ItemState state, bool dark) => state switch
    {
        ItemState.NeedsYou => dark ? 0xFFFFA05Cu : 0xFFB54708u,
        ItemState.Failing => dark ? 0xFFFF99A4u : 0xFFC42B1Cu,
        ItemState.Running => dark ? 0xFF60CDFFu : 0xFF005FB8u,
        ItemState.Done => dark ? 0xFF6CCB5Fu : 0xFF0F7B0Fu,
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(state), actualValue: state, message: "Not a state."),
    };

    /// A glyph drawn on a state's fill, such as a row's badge.
    public static uint OnFill(bool dark) => dark ? 0xFF1A1A1Au : 0xFFFFFFFFu;

    public static uint PillFill(bool dark) => dark ? 0xFFFF8C3Au : 0xFFC24E0Cu;

    public static uint PillText(bool dark) => dark ? 0xFF1A1A1Au : 0xFFFFFFFFu;

    /// A problem, such as a sign-in a source needs.
    public static uint Caution(bool dark) => dark ? 0xFFFCE100u : 0xFF9D5D00u;

    /// The bar's and the panel's color without their acrylic, which contrast is checked against.
    public static uint Background(bool dark) => dark ? 0xFF2C2C2Cu : 0xFFF3F3F3u;

    /// A glyph with nothing to count: quiet, but still 3 to 1.
    public static uint Quiet(bool dark) => dark ? 0xFF9E9E9Eu : 0xFF767676u;

    /// A source's color for its glyph on the bar or a row, mixed with white in dark (or black in light) just enough
    /// to stand out 3 to 1 from the background, so Teams' and GitHub's purples stay visible in dark.
    public static uint Glyph(uint tint, bool dark)
    {
        var background = Background(dark: dark);
        var toward = dark ? 0xFFFFFFFFu : 0xFF000000u;
        for (var step = 0; step <= 20; step++)
        {
            var mixed = Mix(from: tint, to: toward, amount: step / 20.0);
            if (Wcag.Contrast(first: mixed, second: background) >= Wcag.GraphicsContrast)
            {
                return mixed;
            }
        }
        return toward;
    }

    static uint Mix(uint from, uint to, double amount)
    {
        static uint Channel(uint from, uint to, int shift, double amount)
        {
            var start = (from >> shift) & 0xFF;
            var end = (to >> shift) & 0xFF;
            return (uint)Math.Round(value: start + ((end - (double)start) * amount), mode: MidpointRounding.AwayFromZero) << shift;
        }
        return 0xFF000000u
            | Channel(from: from, to: to, shift: 16, amount: amount)
            | Channel(from: from, to: to, shift: 8, amount: amount)
            | Channel(from: from, to: to, shift: 0, amount: amount);
    }
}
