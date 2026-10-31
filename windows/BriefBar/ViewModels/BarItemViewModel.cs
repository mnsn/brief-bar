using System.Collections.ObjectModel;
using BriefBar.Core;
using BriefBar.Core.Presentation;
using Microsoft.UI.Xaml.Media;

namespace BriefBar.ViewModels;

/// A section's item in the bar: its glyph and name, its counts, and a badge when it doesn't show the whole story.
public sealed class BarItemViewModel : Observable
{
    public BarItemViewModel(BarItemContent content, ThemePalette palette)
    {
        ArgumentNullException.ThrowIfNull(argument: content);
        Section = content.Section;
        Update(content: content, palette: palette);
    }

    public SectionId Section { get; }

    public PanelTarget Target => PanelTarget.Of(section: Section);

    public string Label { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public IconKey Glyph { get; private set => Set(storage: ref field, value: value); }

    public Brush GlyphBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public ObservableCollection<CountChipViewModel> Chips { get; } = [];

    public bool ShowsStarting { get; private set => Set(storage: ref field, value: value); }

    public bool ShowsBadge { get; private set => Set(storage: ref field, value: value); }

    public IconKey BadgeIcon { get; private set => Set(storage: ref field, value: value); }

    public string BadgeText { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public Brush BadgeBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public string ToolTip { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public string AutomationName { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    /// Its panel is showing.
    public bool IsOpen { get; set => Set(storage: ref field, value: value); }

    public void Update(BarItemContent content, ThemePalette palette)
    {
        ArgumentNullException.ThrowIfNull(argument: content);
        ArgumentNullException.ThrowIfNull(argument: palette);
        Label = content.Label;
        Glyph = content.Glyph;
        GlyphBrush = content.IsQuiet || content.Badge == BarItemBadge.Paused ? palette.Quiet : palette.Glyph(tint: content.Tint);
        CollectionSync.Sync(
            items: Chips,
            values: content.Chips,
            matches: (item, chip) => item.State == chip.State,
            create: chip => new CountChipViewModel(chip: chip, palette: palette),
            update: (item, chip) => item.Update(chip: chip, palette: palette));
        ShowsStarting = content.Badge == BarItemBadge.Starting;
        ShowsBadge = content.Badge is BarItemBadge.Problem or BarItemBadge.Paused or BarItemBadge.Stale;
        BadgeIcon = content.Badge == BarItemBadge.Paused ? IconKey.PauseCircle : IconKey.Warning;
        BadgeText = content.BadgeText ?? string.Empty;
        BadgeBrush = content.Badge == BarItemBadge.Paused ? palette.Quiet : palette.Caution;
        ToolTip = content.ToolTip;
        AutomationName = content.AutomationName;
    }
}
