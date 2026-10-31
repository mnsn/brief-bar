using System.Collections.ObjectModel;
using BriefBar.Core;
using BriefBar.Core.Presentation;
using Microsoft.UI.Xaml.Media;

namespace BriefBar.ViewModels;

/// The Overview's item, on the left of the bar: what needs you, in words, across every section.
public sealed class OverviewItemViewModel : Observable
{
    public ObservableCollection<SummaryPartViewModel> Parts { get; } = [];

    public string EmptyText { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public bool ShowsEmptyText { get; private set => Set(storage: ref field, value: value); }

    public string ToolTip { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public string AutomationName { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    /// Its panel is showing.
    public bool IsOpen { get; set => Set(storage: ref field, value: value); }

    /// BriefBar's mark: three lines of a brief, with the colors of what needs you, what's running and what's done.
    public Brush MarkNeedsYouBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public Brush MarkRunningBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public Brush MarkDoneBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public void Update(OverviewSummary summary, ThemePalette palette)
    {
        ArgumentNullException.ThrowIfNull(argument: summary);
        ArgumentNullException.ThrowIfNull(argument: palette);
        MarkNeedsYouBrush = palette.Fill(state: ItemState.NeedsYou);
        MarkRunningBrush = palette.Fill(state: ItemState.Running);
        MarkDoneBrush = palette.Fill(state: ItemState.Done);
        var parts = summary.Parts;
        CollectionSync.Sync(
            items: Parts,
            values: parts,
            matches: (item, part) => item.State == part.State,
            create: part => new SummaryPartViewModel(part: part, isFirst: ReferenceEquals(objA: part, objB: parts[0]), palette: palette),
            update: (item, part) => item.Update(part: part, isFirst: ReferenceEquals(objA: part, objB: parts[0]), palette: palette));
        EmptyText = summary.EmptyText;
        ShowsEmptyText = parts.Count == 0;
        ToolTip = summary.ToolTip;
        AutomationName = summary.AutomationName;
    }
}
