using System.Collections.ObjectModel;
using BriefBar.Core.Presentation;

namespace BriefBar.ViewModels;

/// What one display's bar shows: the Overview's item, and an item per section. Each bar has its own, so only the bar
/// whose item opened the panel marks it open.
public sealed class BarViewModel
{
    public OverviewItemViewModel Overview { get; } = new();

    public ObservableCollection<BarItemViewModel> Items { get; } = [];

    public void Update(IReadOnlyList<SectionSnapshot> snapshots, ThemePalette palette, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshots);
        Overview.Update(summary: OverviewSummary.Of(snapshots: snapshots), palette: palette);
        var contents = snapshots.Select(selector: snapshot => BarItemContent.Of(snapshot: snapshot, now: now)).ToList();
        CollectionSync.Sync(
            items: Items,
            values: contents,
            matches: (item, content) => item.Section == content.Section,
            create: content => new BarItemViewModel(content: content, palette: palette),
            update: (item, content) => item.Update(content: content, palette: palette));
    }

    /// Marks `target`'s item open, and every other closed; none for null.
    public void ShowOpen(PanelTarget? target)
    {
        Overview.IsOpen = target is { IsOverview: true };
        foreach (var item in Items)
        {
            item.IsOpen = target == item.Target;
        }
    }
}
