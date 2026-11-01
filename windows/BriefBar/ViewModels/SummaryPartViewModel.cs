using System.Globalization;
using BriefBar.Core;
using BriefBar.Core.Presentation;
using Microsoft.UI.Xaml.Media;

namespace BriefBar.ViewModels;

/// One part of the Overview's words in the bar: "8 need you", its number in its state's color, after a "·" unless
/// it's first.
public sealed class SummaryPartViewModel : Observable
{
    public SummaryPartViewModel(SummaryPart part, bool isFirst, ThemePalette palette)
    {
        ArgumentNullException.ThrowIfNull(argument: part);
        State = part.State;
        Update(part: part, isFirst: isFirst, palette: palette);
    }

    public ItemState State { get; }

    public string Count { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public string Words { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public Brush CountBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public bool ShowsSeparator { get; private set => Set(storage: ref field, value: value); }

    public void Update(SummaryPart part, bool isFirst, ThemePalette palette)
    {
        ArgumentNullException.ThrowIfNull(argument: part);
        ArgumentNullException.ThrowIfNull(argument: palette);
        Count = part.Count.ToString(provider: CultureInfo.CurrentCulture);
        Words = part.Words;
        CountBrush = palette.Text(state: part.State);
        ShowsSeparator = !isFirst;
    }
}
