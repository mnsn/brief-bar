namespace BriefBar.Core.Presentation;

/// The states' colors, as ARGB, for Windows 11's light and dark: fills for icons, dots and badges; text for words;
/// what's drawn on a fill; words in Windows' colors, which the bar's glyphs are in too; and a caution color for
/// problems. Windows' semantic colors where it has them (red, blue, green, caution), and the Mac's orange for what
/// needs you. `StatePaletteTests` checks their contrast against `Backgrounds`, the colors the bar and the panel can
/// have: 4.5 to 1 for words, 3 to 1 for the rest. In High Contrast, the app uses the system's colors instead.
public static class StatePalette
{
    const uint White = 0xFFFFFFFFu;
    const uint Black = 0xFF000000u;

    /// How strong a chip's background is: 14%.
    const uint ChipAlpha = 0x24000000u;

    /// The bar's and the panel's acrylic, by its usual color, and the flat color Windows shows in its place where it
    /// draws no acrylic: with Transparency effects off, with energy saver, or over Remote Desktop, as the taskbar does.
    const uint LightAcrylic = 0xFFF3F3F3u;
    const uint LightFlat = 0xFFEEEEEEu;
    const uint DarkAcrylic = 0xFF2C2C2Cu;
    const uint DarkFlat = 0xFF1C1C1Cu;

    /// What Windows draws behind a bar item that's open, and again behind one that's pointed at:
    /// `SubtleFillColorSecondary`.
    const uint LightHighlight = 0x09000000u;
    const uint DarkHighlight = 0x0FFFFFFFu;

    /// How opaque the bar's see-through tint is: 80%, the taskbar's acrylic's tint.
    public const uint SeeThroughAlpha = 0xCC000000u;

    public static uint Fill(ItemState state, bool dark) => state switch
    {
        ItemState.NeedsYou => dark ? 0xFFFF8C3Au : 0xFFD85F0Bu,
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


    /// A problem, such as a sign-in a source needs.
    public static uint Caution(bool dark) => dark ? 0xFFFCE100u : 0xFF9D5D00u;

    /// Of the colors the bar and the panel can have (`Backgrounds`), the one colors stand out least against, which
    /// colors are worked out against: the flat one in light, the darker; the acrylic in dark, the lighter.
    public static uint Background(bool dark) => dark ? DarkAcrylic : LightFlat;

    /// The colors the bar and the panel can have: their acrylic's usual color, and the flat one Windows shows in its
    /// place.
    public static IReadOnlyList<uint> Backgrounds(bool dark) => dark ? [DarkAcrylic, DarkFlat] : [LightAcrylic, LightFlat];

    /// The flat color Windows shows in place of the bar's acrylic, as under the taskbar.
    public static uint Flat(bool dark) => dark ? DarkFlat : LightFlat;

    /// `words` on a see-through bar, worked out against `background`, its tint over the wallpaper they stand out least
    /// on: opaque, as translucent words darken with a darker wallpaper behind them, or lighten with a lighter one, and
    /// would read less there; and as little lighter in dark (darker in light) as it takes to stand `least` to 1 apart.
    public static uint WordsOver(uint words, uint background, bool dark, double least) =>
        Readable(color: Over(argb: words, background: background), background: background, dark: dark, least: least);

    /// A see-through `tint` as it shows over the wallpaper its words stand out least on: white behind light words (in
    /// dark), black behind dark ones; and behind a bar item that's open and pointed at.
    public static uint UnderSeeThrough(uint tint, bool dark) =>
        UnderBarItem(background: Over(argb: tint, background: dark ? White : Black), dark: dark);

    /// Words in Windows' colors, as WinUI's `TextFillColorPrimary`: counts and other words that matter most.
    public static uint Words(bool dark) => dark ? White : 0xE4000000u;

    /// Words a step quieter, as WinUI's `TextFillColorSecondary`: the bar's labels.
    public static uint SecondaryWords(bool dark) => dark ? 0xC5FFFFFFu : 0x9E000000u;

    /// The quietest, as WinUI's `TextFillColorTertiary`: what only sets words apart, such as the dots between them.
    public static uint TertiaryWords(bool dark) => dark ? 0x87FFFFFFu : 0x72000000u;

    /// `words`, which may be translucent, as they are while they stand `least` to 1 apart from `background`; else
    /// opaque, and as little lighter in dark (darker in light) as it takes.
    public static uint ReadableWords(uint words, uint background, bool dark, double least)
    {
        var shown = Over(argb: words, background: background);
        return Wcag.Contrast(first: shown, second: background) >= least ? words : Readable(color: shown, background: background, dark: dark, least: least);
    }

    /// What the bar's colors are worked out against (`Readable`): the taskbar's `accent` color while the bar shows it,
    /// or else the bar's own background they stand out least on, behind an item that's open and pointed at.
    public static uint BarBackground(uint? accent, bool dark) => UnderBarItem(background: accent ?? Background(dark: dark), dark: dark);

    /// `background` behind a bar item that's open and pointed at, under both of Windows' highlights: the most of them a
    /// bar item has, which its colors stand out least against.
    public static uint UnderBarItem(uint background, bool dark)
    {
        var highlight = dark ? DarkHighlight : LightHighlight;
        return Over(argb: highlight, background: Over(argb: highlight, background: background));
    }

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

    /// `color`, or as little lighter in dark (darker in light) as it takes to stand `least` to 1 apart from
    /// `background`, which isn't one of `Backgrounds`, such as the taskbar's accent color behind the bar.
    public static uint Readable(uint color, uint background, bool dark, double least) =>
        Toward(color: color, target: dark ? White : Black, background: background, least: least);

    /// `from`, opaque, `amount` of the way to `to`.
    internal static uint Mix(uint from, uint to, double amount)
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
}
