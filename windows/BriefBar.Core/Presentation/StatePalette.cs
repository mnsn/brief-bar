namespace BriefBar.Core.Presentation;

/// The states' colors, as ARGB, for Windows 11's light and dark: fills for icons, dots and badges; text for words;
/// what's drawn on a fill; the bar's glyphs; and a caution color for problems. Windows' semantic colors where it has
/// them (red, blue, green, caution), and the Mac's orange for what needs you. `StatePaletteTests` checks their contrast
/// against `Background`, the color of the bar and the panel without their acrylic: 4.5 to 1 for words, 3 to 1 for the
/// rest. In High Contrast, the app uses the system's colors instead.
public static class StatePalette
{
    const uint White = 0xFFFFFFFFu;
    const uint Black = 0xFF000000u;

    /// How strong a chip's background is: 14%.
    const uint ChipAlpha = 0x24000000u;

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

    /// A source's glyph on the bar, in the color of its words, as the taskbar's icons and the Mac's menu bar are:
    /// Windows' primary text color.
    public static uint Ink(bool dark) => dark ? 0xFFFFFFFFu : 0xE4000000u;

    /// A problem, such as a sign-in a source needs.
    public static uint Caution(bool dark) => dark ? 0xFFFCE100u : 0xFF9D5D00u;

    /// The bar's and the panel's color without their acrylic, which contrast is checked against.
    public static uint Background(bool dark) => dark ? 0xFF2C2C2Cu : 0xFFF3F3F3u;

    /// Words and glyphs with nothing to count, such as a chat's preview or the heading of a group that isn't counted:
    /// quiet, but still 4.5 to 1.
    public static uint Quiet(bool dark) => dark ? 0xFF9E9E9Eu : 0xFF6B6B6Bu;

    /// A row's link chip's background: its kind's color, faint, over the panel. Work items are blue, as running things
    /// are; pull requests green, as Azure DevOps' are.
    public static uint ChipBackground(RowChipKind kind, bool dark) => (ChipTint(kind: kind, dark: dark) & 0x00FFFFFFu) | ChipAlpha;

    /// A chip's words: its kind's color, darkened in light (or lightened in dark) just enough to read 4.5 to 1 on the
    /// chip as it shows over the panel.
    public static uint ChipText(RowChipKind kind, bool dark) => Toward(
        color: ChipTint(kind: kind, dark: dark),
        target: dark ? White : Black,
        background: Over(argb: ChipBackground(kind: kind, dark: dark), background: Background(dark: dark)),
        least: Wcag.TextContrast);

    /// A source's color for its glyph on the bar or a row, mixed with white in dark (or black in light) just enough
    /// to stand out 3 to 1 from the background, so Teams' and GitHub's purples stay visible in dark.
    public static uint Glyph(uint tint, bool dark) =>
        Toward(color: tint, target: dark ? White : Black, background: Background(dark: dark), least: Wcag.GraphicsContrast);

    /// `argb`, which may be translucent, as it shows on the opaque `background`.
    public static uint Over(uint argb, uint background) =>
        Mix(from: background, to: argb | 0xFF000000u, amount: (argb >> 24) / 255.0);

    /// `color`, mixed with `target` in steps of 5% until it stands `least` to 1 apart from `background`; `target`
    /// itself if nothing short of it does.
    static uint Toward(uint color, uint target, uint background, double least)
    {
        for (var step = 0; step <= 20; step++)
        {
            var mixed = Mix(from: color, to: target, amount: step / 20.0);
            if (Wcag.Contrast(first: mixed, second: background) >= least)
            {
                return mixed;
            }
        }
        return target;
    }

    static uint ChipTint(RowChipKind kind, bool dark) =>
        Text(state: kind == RowChipKind.WorkItem ? ItemState.Running : ItemState.Done, dark: dark);

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
