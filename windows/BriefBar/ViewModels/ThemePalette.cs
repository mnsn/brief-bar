using BriefBar.Core;
using BriefBar.Core.Presentation;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace BriefBar.ViewModels;

/// The colors of states and sources as brushes, for the theme BriefBar shows: Core's `StatePalette` in light and dark,
/// and Windows' own colors in High Contrast, where states stand apart by their icons and words. A palette holds the
/// colors of one moment: when Windows' change, even from one contrast theme to another, a new palette takes its place.
public sealed class ThemePalette
{
    /// The colors of Windows' that High Contrast uses here.
    static readonly UIElementType[] systemElements =
    [
        UIElementType.Highlight,
        UIElementType.HighlightText,
        UIElementType.WindowText,
        UIElementType.GrayText,
        UIElementType.ButtonFace,
        UIElementType.ButtonText,
    ];

    readonly Dictionary<uint, SolidColorBrush> brushes = [];

    /// In High Contrast, Windows' colors as they were when it was made; otherwise none.
    readonly Dictionary<UIElementType, Color> systemColors;

    ThemePalette(bool isDark, bool isHighContrast, Dictionary<UIElementType, Color> systemColors)
    {
        IsDark = isDark;
        IsHighContrast = isHighContrast;
        this.systemColors = systemColors;
    }

    public bool IsDark { get; }

    public bool IsHighContrast { get; }

    /// Icons, dots and badges in a state.
    public Brush Fill(ItemState state) =>
        IsHighContrast ? System(element: UIElementType.Highlight) : Brush(argb: StatePalette.Fill(state: state, dark: IsDark));

    /// Words in a state.
    public Brush Text(ItemState state) =>
        IsHighContrast ? System(element: UIElementType.WindowText) : Brush(argb: StatePalette.Text(state: state, dark: IsDark));

    /// A glyph on a state's fill.
    public Brush OnFill =>
        IsHighContrast ? System(element: UIElementType.HighlightText) : Brush(argb: StatePalette.OnFill(dark: IsDark));

    /// A source's glyph on the bar, in the color of its words.
    public Brush Ink =>
        IsHighContrast ? System(element: UIElementType.WindowText) : Brush(argb: StatePalette.Ink(dark: IsDark));

    public Brush Caution =>
        IsHighContrast ? System(element: UIElementType.WindowText) : Brush(argb: StatePalette.Caution(dark: IsDark));

    public Brush Quiet =>
        IsHighContrast ? System(element: UIElementType.GrayText) : Brush(argb: StatePalette.Quiet(dark: IsDark));

    /// A source's glyph on the bar or a row.
    public Brush Glyph(uint tint) =>
        IsHighContrast ? System(element: UIElementType.WindowText) : Brush(argb: StatePalette.Glyph(tint: tint, dark: IsDark));

    /// A source's tile, or a chat's avatar, with `OnTint` drawn on it.
    public Brush Tint(uint tint) => IsHighContrast ? System(element: UIElementType.Highlight) : Brush(argb: tint);

    public Brush OnTint => IsHighContrast ? System(element: UIElementType.HighlightText) : Brush(argb: 0xFFFFFFFFu);

    /// A row's link chip: its kind's color, faint behind it, and readable on that for its words.
    public Brush ChipBackground(RowChipKind kind) =>
        IsHighContrast ? System(element: UIElementType.ButtonFace) : Brush(argb: StatePalette.ChipBackground(kind: kind, dark: IsDark));

    public Brush ChipText(RowChipKind kind) =>
        IsHighContrast ? System(element: UIElementType.ButtonText) : Brush(argb: StatePalette.ChipText(kind: kind, dark: IsDark));

    /// The palette for what Windows shows now: in High Contrast, with Windows' colors from `settings`.
    public static ThemePalette For(ElementTheme theme, bool isHighContrast, UISettings settings)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        Dictionary<UIElementType, Color> colors = isHighContrast
            ? systemElements.ToDictionary(keySelector: element => element, elementSelector: element => settings.UIElementColor(desiredElement: element))
            : [];
        return new ThemePalette(isDark: theme == ElementTheme.Dark, isHighContrast: isHighContrast, systemColors: colors);
    }

    /// Whether it shows what `other` does: the same theme and, in High Contrast, the same colors of Windows'.
    public bool Matches(ThemePalette other)
    {
        ArgumentNullException.ThrowIfNull(argument: other);
        return IsDark == other.IsDark
            && IsHighContrast == other.IsHighContrast
            && systemColors.Count == other.systemColors.Count
            && systemColors.All(predicate: pair => other.systemColors.TryGetValue(key: pair.Key, value: out var color) && color == pair.Value);
    }

    SolidColorBrush Brush(uint argb)
    {
        if (!brushes.TryGetValue(key: argb, value: out var brush))
        {
            brush = new SolidColorBrush(color: ColorOf(argb: argb));
            brushes[argb] = brush;
        }
        return brush;
    }

    SolidColorBrush System(UIElementType element) => Brush(argb: ArgbOf(color: systemColors[element]));

    static Color ColorOf(uint argb) => Color.FromArgb(
        a: (byte)(argb >> 24), r: (byte)(argb >> 16), g: (byte)(argb >> 8), b: (byte)argb);

    static uint ArgbOf(Color color) => ((uint)color.A << 24) | ((uint)color.R << 16) | ((uint)color.G << 8) | color.B;
}
