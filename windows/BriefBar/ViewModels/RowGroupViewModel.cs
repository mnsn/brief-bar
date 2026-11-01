using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using BriefBar.Core;
using BriefBar.Core.Presentation;
using Microsoft.UI.Xaml.Media;

namespace BriefBar.ViewModels;

/// A group of rows in a panel, with its heading: its title in its state's color, and how many it holds.
public sealed class RowGroupViewModel : ObservableCollection<RowViewModel>
{
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

    public void Update(PanelGroup group, SectionId? section, ThemePalette palette, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: group);
        ArgumentNullException.ThrowIfNull(argument: palette);
        var showsSource = section is null;
        CollectionSync.Sync(
            items: this,
            values: group.Rows,
            matches: (item, row) => item.Section == row.Section && item.Id == row.Id,
            create: row => new RowViewModel(row: row, showsSource: showsSource, palette: palette, now: now),
            update: (item, row) => item.Update(row: row, showsSource: showsSource, palette: palette, now: now));
        Title = group.Title;
        CountText = group.Rows.Count.ToString(provider: CultureInfo.CurrentCulture);
        HasIcon = group.State is not null;
        Icon = group.State is { } state ? StateWords.Icon(state: state, section: section ?? default) : IconKey.Stack;
        TitleBrush = group.State is { } titleState ? palette.Text(state: titleState) : palette.Quiet;
        IconBrush = group.State is { } iconState ? palette.Fill(state: iconState) : palette.Quiet;
        OnPropertyChanged(e: new PropertyChangedEventArgs(propertyName: string.Empty));
    }

    /// What Narrator calls the group, as on the Mac: "Needs you: 3". A list names a group by its item's text.
    public override string ToString() => Title + ": " + CountText;
}
