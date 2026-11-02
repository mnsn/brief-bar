using BriefBar.Core;
using BriefBar.Core.Presentation;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace BriefBar.ViewModels;

/// One thing in a panel: a badge in its state's color (or a chat's initials), its title, where it stands, what it's
/// about, and when; what pressing it does, and what its menu offers; how far it's indented, the tag that names what it
/// belongs to, and how full it is.
public sealed class RowViewModel : Observable
{
    /// How far each level of nesting indents a row, as on the Mac.
    const double IndentStep = 16;

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

    /// It's in no state, as an idle session: its title is quieter.
    public bool IsQuiet { get; private set => Set(storage: ref field, value: value); }

    public bool IsNotQuiet { get; private set => Set(storage: ref field, value: value); }

    public string Status { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public Brush StatusBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public string Detail { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public bool HasDetail { get; private set => Set(storage: ref field, value: value); }

    /// What needs you shows a line more of what it's about, as on the Mac.
    public int DetailLines { get; private set => Set(storage: ref field, value: value); } = 2;

    public string Age { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public IconKey Icon { get; private set => Set(storage: ref field, value: value); }

    public Brush BadgeBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public Brush BadgeGlyphBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public string Initials { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public bool HasInitials { get; private set => Set(storage: ref field, value: value); }

    /// Its state's icon shows in its badge, without initials.
    public bool HasIcon { get; private set => Set(storage: ref field, value: value); }

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

    /// What its menu offers; the first is what pressing it does.
    public IReadOnlyList<PanelCommand> Commands { get; private set => Set(storage: ref field, value: value); } = [];

    public string? ToolTip { get; private set => Set(storage: ref field, value: value); }

    /// Indented under the row it belongs with, in its section's own panel.
    public Thickness Indent { get; private set => Set(storage: ref field, value: value); }

    /// Its tag, where the list doesn't show the row under what it names: a button when it opens that, words when not.
    public bool ShowsTagButton { get; private set => Set(storage: ref field, value: value); }

    public bool ShowsTagText { get; private set => Set(storage: ref field, value: value); }

    public string TagText { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public string TagToolTip { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    /// What Narrator calls its tag: "Started by “Release 2.5”".
    public string TagSpoken { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public string? TagCommand { get; private set; }

    /// What its tag's command does, as its menu offers it.
    public PanelCommand? TagPanelCommand =>
        TagCommand is { } key ? Commands.FirstOrDefault(predicate: command => command.Key == key) : null;

    public bool HasMeter { get; private set => Set(storage: ref field, value: value); }

    public string MeterText { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public Brush MeterBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public Brush MeterTrackBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    /// How much of the ring is filled, from 0 to 1.
    public double MeterFraction { get; private set => Set(storage: ref field, value: value); }

    public void Update(ItemRow row, bool showsSource, ThemePalette palette, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: row);
        ArgumentNullException.ThrowIfNull(argument: palette);
        var info = Sections.InBarOrder.FirstOrDefault(predicate: section => section.Id == row.Section);
        Title = row.Title;
        IsQuiet = row.State is null;
        IsNotQuiet = row.State is not null;
        Status = row.Status;
        StatusBrush = row.StatusTone == StatusTone.State && row.State is { } state ? palette.Text(state: state) : palette.Quiet;
        Detail = row.Detail ?? string.Empty;
        HasDetail = !string.IsNullOrEmpty(value: row.Detail);
        DetailLines = row.State == ItemState.NeedsYou ? 3 : 2;
        Age = Elapsed.Compact(since: row.Date, now: now);
        Icon = row.Icon;
        BadgeBrush = row.State is { } badgeState ? palette.Fill(state: badgeState) : palette.Quiet;
        BadgeGlyphBrush = palette.OnFill;
        Initials = row.Initials ?? string.Empty;
        HasInitials = !string.IsNullOrEmpty(value: row.Initials);
        HasIcon = !HasInitials;
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
        if (!row.Commands.SequenceEqual(second: Commands))
        {
            Commands = row.Commands;
        }
        ToolTip = row.ToolTip;
        // A list that mixes sources doesn't nest rows; there, the tag names what a row belongs with.
        var nests = !showsSource;
        Indent = new Thickness(left: nests ? row.Depth * IndentStep : 0, top: 0, right: 0, bottom: 0);
        var showsTag = row.Tag is not null && (!nests || row.Depth == 0);
        ShowsTagButton = showsTag && row.Tag!.Command is not null;
        ShowsTagText = showsTag && row.Tag!.Command is null;
        TagText = row.Tag?.Text ?? string.Empty;
        TagToolTip = row.Tag?.ToolTip ?? string.Empty;
        TagSpoken = row.Tag?.Spoken ?? string.Empty;
        TagCommand = row.Tag?.Command;
        UpdateMeter(meter: row.Meter, palette: palette);
    }

    void UpdateMeter(RowMeter? meter, ThemePalette palette)
    {
        HasMeter = meter is not null;
        MeterText = meter?.Text ?? string.Empty;
        MeterBrush = meter is { IsHigh: true } ? palette.Caution : palette.Quiet;
        MeterTrackBrush = palette.Quiet;
        MeterFraction = meter?.Fraction ?? 0;
    }
}
