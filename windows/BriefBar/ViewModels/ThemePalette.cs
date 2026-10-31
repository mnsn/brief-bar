using BriefBar.Core;
using BriefBar.Core.Presentation;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace BriefBar.ViewModels;

/// The colors of states and sources as brushes, for the theme BriefBar shows: Core's `StatePalette` in light and dark,
/// and Windows' own colors in High Contrast, where states stand apart by their icons and words.
public sealed class ThemePalette
{
    readonly Dictionary<uint, SolidColorBrush> brushes = [];
    readonly Dictionary<string, SolidColorBrush> systemBrushes = new(comparer: StringComparer.Ordinal);

    public ThemePalette(bool isDark, bool isHighContrast)
    {
        IsDark = isDark;
        IsHighContrast = isHighContrast;
    }

    public bool IsDark { get; }

    public bool IsHighContrast { get; }

    /// Icons, dots and badges in a state.
    public Brush Fill(ItemState state) =>
        IsHighContrast ? System(key: "SystemColorHighlightColor") : Brush(argb: StatePalette.Fill(state: state, dark: IsDark));

    /// Words in a state.
    public Brush Text(ItemState state) =>
        IsHighContrast ? System(key: "SystemColorWindowTextColor") : Brush(argb: StatePalette.Text(state: state, dark: IsDark));

    /// A glyph on a state's fill.
    public Brush OnFill =>
        IsHighContrast ? System(key: "SystemColorHighlightTextColor") : Brush(argb: StatePalette.OnFill(dark: IsDark));

    public Brush PillFill =>
        IsHighContrast ? System(key: "SystemColorHighlightColor") : Brush(argb: StatePalette.PillFill(dark: IsDark));

    public Brush PillText =>
        IsHighContrast ? System(key: "SystemColorHighlightTextColor") : Brush(argb: StatePalette.PillText(dark: IsDark));

    public Brush Caution =>
        IsHighContrast ? System(key: "SystemColorWindowTextColor") : Brush(argb: StatePalette.Caution(dark: IsDark));

    public Brush Quiet =>
        IsHighContrast ? System(key: "SystemColorGrayTextColor") : Brush(argb: StatePalette.Quiet(dark: IsDark));

    /// A source's glyph on the bar or a row.
    public Brush Glyph(uint tint) =>
        IsHighContrast ? System(key: "SystemColorWindowTextColor") : Brush(argb: StatePalette.Glyph(tint: tint, dark: IsDark));

    /// A source's tile, or a chat's avatar, with `OnTint` drawn on it.
    public Brush Tint(uint tint) => IsHighContrast ? System(key: "SystemColorHighlightColor") : Brush(argb: tint);

    public Brush OnTint => IsHighContrast ? System(key: "SystemColorHighlightTextColor") : Brush(argb: 0xFFFFFFFFu);

    /// A row's link chip: its kind's color, faint behind it, and strong for its words. Work items are blue, as running
    /// things are; pull requests green, as Azure DevOps' are.
    public Brush ChipBackground(RowChipKind kind) =>
        IsHighContrast ? System(key: "SystemColorButtonFaceColor") : Brush(argb: Faint(argb: ChipColor(kind: kind)));

    public Brush ChipText(RowChipKind kind) =>
        IsHighContrast ? System(key: "SystemColorButtonTextColor") : Brush(argb: ChipColor(kind: kind));

    /// The palette for what Windows shows now.
    public static ThemePalette For(ElementTheme theme, bool isHighContrast) =>
        new(isDark: theme == ElementTheme.Dark, isHighContrast: isHighContrast);

    uint ChipColor(RowChipKind kind) =>
        StatePalette.Text(state: kind == RowChipKind.WorkItem ? ItemState.Running : ItemState.Done, dark: IsDark);

    /// `argb` at 14% opacity.
    static uint Faint(uint argb) => (argb & 0x00FFFFFFu) | 0x24000000u;

    SolidColorBrush Brush(uint argb)
    {
        if (!brushes.TryGetValue(key: argb, value: out var brush))
        {
            brush = new SolidColorBrush(color: ColorOf(argb: argb));
            brushes[argb] = brush;
        }
        return brush;
    }

    SolidColorBrush System(string key)
    {
        if (!systemBrushes.TryGetValue(key: key, value: out var brush))
        {
            var color = Application.Current.Resources.TryGetValue(key: key, value: out var value) && value is Color systemColor
                ? systemColor
                : Colors.Gray;
            brush = new SolidColorBrush(color: color);
            systemBrushes[key] = brush;
        }
        return brush;
    }

    static Color ColorOf(uint argb) => Color.FromArgb(
        a: (byte)(argb >> 24), r: (byte)(argb >> 16), g: (byte)(argb >> 8), b: (byte)argb);
}
