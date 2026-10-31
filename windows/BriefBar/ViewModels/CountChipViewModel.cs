using BriefBar.Core;
using BriefBar.Core.Presentation;
using Microsoft.UI.Xaml.Media;

namespace BriefBar.ViewModels;

/// One count on an item in the bar: Needs You as a filled pill, the other states as an icon and a number.
public sealed class CountChipViewModel : Observable
{
    public CountChipViewModel(CountChip chip, ThemePalette palette)
    {
        State = chip.State;
        Update(chip: chip, palette: palette);
    }

    public ItemState State { get; }

    public IconKey Icon { get; private set => Set(storage: ref field, value: value); }

    public string Count { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public bool IsPill { get; private set => Set(storage: ref field, value: value); }

    public bool IsPlain => !IsPill;

    public Brush IconBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public Brush PillBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public Brush PillTextBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public void Update(CountChip chip, ThemePalette palette)
    {
        ArgumentNullException.ThrowIfNull(argument: chip);
        ArgumentNullException.ThrowIfNull(argument: palette);
        Icon = chip.Icon;
        Count = chip.Count.ToString(provider: System.Globalization.CultureInfo.CurrentCulture);
        IsPill = chip.IsEmphasized;
        IconBrush = palette.Fill(state: chip.State);
        PillBrush = palette.PillFill;
        PillTextBrush = palette.PillText;
    }
}
