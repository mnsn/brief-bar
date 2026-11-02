using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using BriefBar.Core;
using BriefBar.Core.Presentation;
using Microsoft.UI.Xaml.Media;

namespace BriefBar.ViewModels;

/// A group of rows in a panel, with its heading: its title in its state's color, how many it holds, and what it can do,
/// such as Clear. A group that folds, as Copilot's idle sessions do, lists its rows only once you unfold it.
public sealed class RowGroupViewModel : ObservableCollection<RowViewModel>
{
    PanelGroup? group;
    SectionId? section;

    public RowGroupViewModel(string key)
    {
        Key = key;
    }

    public string Key { get; }

    public string Title { get; private set; } = string.Empty;

    public string CountText { get; private set; } = string.Empty;

    public bool HasIcon { get; private set; }

    public IconKey Icon { get; private set; }

    public Brush TitleBrush { get; private set; } = null!;

    public Brush IconBrush { get; private set; } = null!;

    /// It can fold: its heading is a button that shows or hides its rows.
    public bool IsFoldable { get; private set; }

    public bool IsNotFoldable => !IsFoldable;

    public bool IsFolded { get; private set; }

    /// The chevron's turn: right while folded, down while not.
    public double ChevronAngle => IsFolded ? 0 : 90;

    public string FoldName { get; private set; } = string.Empty;

    /// What its heading's button does to the whole group, such as Clear.
    public PanelCommand? Command { get; private set; }

    public bool HasCommand => Command is not null;

    public string CommandTitle => Command?.Title ?? string.Empty;

    public string? CommandHelp => Command?.Help;

    /// The section whose group it is, for its commands; none in the Overview.
    public SectionId? Section => section;

    public void Update(PanelGroup group, SectionId? section, ThemePalette palette, DateTimeOffset now, bool isFolded)
    {
        ArgumentNullException.ThrowIfNull(argument: group);
        ArgumentNullException.ThrowIfNull(argument: palette);
        this.group = group;
        this.section = section;
        var showsSource = section is null;
        IsFoldable = group.IsFolded;
        IsFolded = group.IsFolded && isFolded;
        IReadOnlyList<ItemRow> shown = IsFolded ? [] : group.Rows;
        CollectionSync.Sync(
            items: this,
            values: shown,
            matches: (item, row) => item.Section == row.Section && item.Id == row.Id,
            create: row => new RowViewModel(row: row, showsSource: showsSource, palette: palette, now: now),
            update: (item, row) => item.Update(row: row, showsSource: showsSource, palette: palette, now: now));
        Title = group.Title;
        CountText = group.Rows.Count.ToString(provider: CultureInfo.CurrentCulture);
        FoldName = (IsFolded ? "Show " : "Hide ") + group.Title.ToLower(culture: CultureInfo.CurrentCulture) + ", " + CountText;
        HasIcon = group.State is not null;
        Icon = group.State is { } state ? StateWords.Icon(state: state, section: section ?? default) : IconKey.Stack;
        TitleBrush = group.State is { } titleState ? palette.Text(state: titleState) : palette.Quiet;
        IconBrush = group.State is { } iconState ? palette.Fill(state: iconState) : palette.Quiet;
        Command = section is null || group.Commands.Count == 0 ? null : group.Commands[0];
        OnPropertyChanged(e: new PropertyChangedEventArgs(propertyName: string.Empty));
    }

    /// Folds or unfolds it, as it stands now.
    public void Fold(bool folded, ThemePalette palette, DateTimeOffset now)
    {
        if (group is not null)
        {
            Update(group: group, section: section, palette: palette, now: now, isFolded: folded);
        }
    }

    /// What Narrator calls the group, as on the Mac: "Needs you: 3". A list names a group by its item's text.
    public override string ToString() => Title + ": " + CountText;
}
