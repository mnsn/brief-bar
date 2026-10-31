using BriefBar.Core;
using BriefBar.Core.Presentation;
using Microsoft.UI.Xaml.Media;

namespace BriefBar.ViewModels;

/// One thing in a panel: a badge in its state's color (or a chat's initials), its title, where it stands, what it's
/// about, and when.
public sealed class RowViewModel : Observable
{
    public RowViewModel(ItemRow row, bool showsSource, ThemePalette palette, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: row);
        Section = row.Section;
        Id = row.Id;
        Update(row: row, showsSource: showsSource, palette: palette, now: now);
    }

    public SectionId Section { get; }

    public string Id { get; }

    public string Title { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public string Status { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public Brush StatusBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public string Detail { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public bool HasDetail { get; private set => Set(storage: ref field, value: value); }

    public string Age { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public IconKey Icon { get; private set => Set(storage: ref field, value: value); }

    public Brush BadgeBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public Brush BadgeGlyphBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public string Initials { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public bool HasInitials { get; private set => Set(storage: ref field, value: value); }

    public bool HasIcon => !HasInitials;

    public string Unread { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public bool HasUnread { get; private set => Set(storage: ref field, value: value); }

    public Brush UnreadBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    /// Words and initials on the source's color, as on an avatar or an unread count.
    public Brush OnTintBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public bool IsNew { get; private set => Set(storage: ref field, value: value); }

    public IReadOnlyList<RowChipViewModel> Chips { get; private set => Set(storage: ref field, value: value); } = [];

    public bool HasChips { get; private set => Set(storage: ref field, value: value); }

    /// In the Overview, which mixes sources, a row shows its source's glyph.
    public bool ShowsSource { get; private set => Set(storage: ref field, value: value); }

    public IconKey SourceGlyph { get; private set => Set(storage: ref field, value: value); }

    public Brush SourceBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public string AutomationName { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public void Update(ItemRow row, bool showsSource, ThemePalette palette, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: row);
        ArgumentNullException.ThrowIfNull(argument: palette);
        var info = Sections.InBarOrder.FirstOrDefault(predicate: section => section.Id == row.Section);
        Title = row.Title;
        Status = row.Status;
        StatusBrush = row.StatusTone == StatusTone.State && row.State is { } state ? palette.Text(state: state) : palette.Quiet;
        Detail = row.Detail ?? string.Empty;
        HasDetail = !string.IsNullOrEmpty(value: row.Detail);
        Age = Elapsed.Compact(since: row.Date, now: now);
        Icon = row.Icon;
        BadgeBrush = row.State is { } badgeState ? palette.Fill(state: badgeState) : palette.Quiet;
        BadgeGlyphBrush = palette.OnFill;
        Initials = row.Initials ?? string.Empty;
        HasInitials = !string.IsNullOrEmpty(value: row.Initials);
        Unread = row.Unread > 0 ? row.Unread.ToString(provider: System.Globalization.CultureInfo.CurrentCulture) : string.Empty;
        HasUnread = row.Unread > 0;
        UnreadBrush = info is null ? palette.Quiet : palette.Tint(tint: info.Tint);
        OnTintBrush = palette.OnTint;
        IsNew = row.IsNew;
        var chips = row.Chips.Select(selector: chip => new RowChipViewModel(
            Text: chip.Text,
            Icon: chip.Kind == RowChipKind.WorkItem ? IconKey.ClipboardTaskList : IconKey.BranchRequest,
            Background: palette.ChipBackground(kind: chip.Kind),
            Foreground: palette.ChipText(kind: chip.Kind))).ToList();
        // Only new chips are put on screen again, not the same ones at every refresh.
        if (!chips.SequenceEqual(second: Chips))
        {
            Chips = chips;
        }
        HasChips = row.Chips.Count > 0;
        ShowsSource = showsSource;
        SourceGlyph = info?.Glyph ?? IconKey.Stack;
        SourceBrush = info is null ? palette.Quiet : palette.Glyph(tint: info.Tint);
        AutomationName = RowWords.SpokenName(row: row, sourceName: showsSource ? info?.FullName : null, now: now);
    }
}
