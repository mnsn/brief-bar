using BriefBar.Core;
using BriefBar.Core.Presentation;
using Microsoft.UI.Xaml.Media;

namespace BriefBar.ViewModels;

/// One count on an item in the bar: its state's icon, in the state's color, and the number.
public sealed class CountChipViewModel : Observable
{
    public CountChipViewModel(CountChip chip, ThemePalette palette, double iconSize)
    {
        State = chip.State;
        Update(chip: chip, palette: palette, iconSize: iconSize);
    }

    public ItemState State { get; }

    public IconKey Icon { get; private set => Set(storage: ref field, value: value); }

    public string Count { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public Brush IconBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    /// How big its icon is, as Windows' text size makes the bar (`BarMetrics.IconSize`).
    public double IconSize { get; private set => Set(storage: ref field, value: value); } = BarMetrics.SmallIconDip;

    public void Update(CountChip chip, ThemePalette palette, double iconSize)
    {
        ArgumentNullException.ThrowIfNull(argument: chip);
        ArgumentNullException.ThrowIfNull(argument: palette);
        Icon = chip.Icon;
        Count = chip.Count.ToString(provider: System.Globalization.CultureInfo.CurrentCulture);
        IconBrush = palette.Fill(state: chip.State);
        IconSize = iconSize;
    }
}
