using BriefBar.Core;
using BriefBar.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace BriefBar.Views;

/// Settings: General, then a page for each source, with an attention badge on one that's paused.
public sealed partial class SettingsView : UserControl
{
    readonly GeneralSettingsPage general;
    readonly NavigationViewItem generalItem;
    readonly Dictionary<SourceId, (NavigationViewItem Item, SourceSettingsPage Page)> sources = [];

    public SettingsView(SettingsViewModel viewModel, ThemePalette palette)
    {
        ArgumentNullException.ThrowIfNull(argument: viewModel);
        ViewModel = viewModel;
        InitializeComponent();
        UsePalette(palette: palette);
        general = new GeneralSettingsPage(viewModel: viewModel);
        general.SourceRequested += (_, source) => Show(source: source.Entry.Id);
        general.QuitRequested += (_, _) => QuitRequested?.Invoke(sender: this, e: EventArgs.Empty);
        generalItem = new NavigationViewItem { Content = "General", Icon = FluentIconElement.Make(icon: IconKey.Settings) };
        Navigation.MenuItems.Add(item: generalItem);
        Navigation.MenuItems.Add(item: new NavigationViewItemHeader { Content = "Sources" });
        foreach (var source in viewModel.Sources)
        {
            UIElement? settings = source.Entry.Id switch
            {
                SourceId.AzureDevOps => new AzureDevOpsSettingsView(viewModel: viewModel.AzureDevOps),
                SourceId.Copilot => new CopilotSettingsView(viewModel: viewModel.Copilot),
                SourceId.GitHub => new GitHubSettingsView(viewModel: viewModel.GitHub),
                _ => null,
            };
            var page = new SourceSettingsPage(viewModel: source, settings: settings);
            page.TurnOnRequested += (_, _) => TurnOnRequested?.Invoke(sender: this, e: source);
            page.TurnOffRequested += (_, _) => TurnOffRequested?.Invoke(sender: this, e: source);
            var item = new NavigationViewItem { Content = source.Name, Icon = FluentIconElement.Make(icon: source.Glyph) };
            Navigation.MenuItems.Add(item: item);
            sources[source.Entry.Id] = (item, page);
        }
        ShowBadges();
    }

    public SettingsViewModel ViewModel { get; }

    /// Where the window can be dragged.
    public UIElement TitleBarElement => TitleBar;

    /// You turned a source on, or kept it on after an update.
    public event EventHandler<SourceSettingsViewModel>? TurnOnRequested;

    public event EventHandler<SourceSettingsViewModel>? TurnOffRequested;

    public event EventHandler? QuitRequested;

    /// Shows `source`'s page, or General.
    public void Show(SourceId? source)
    {
        var item = source is { } id && sources.TryGetValue(key: id, value: out var shown) ? shown.Item : generalItem;
        if (ReferenceEquals(objA: Navigation.SelectedItem, objB: item))
        {
            ShowPage(item: item);
            return;
        }
        Navigation.SelectedItem = item;
    }

    /// Whether each source is on, as it stands now.
    public void Refresh()
    {
        ViewModel.Refresh();
        ShowBadges();
    }

    /// Its colors in `palette`, as the theme or the contrast changes: the title bar's tile, set here as it has no
    /// binding that follows, and each source's.
    public void UsePalette(ThemePalette palette)
    {
        ArgumentNullException.ThrowIfNull(argument: palette);
        TitleTile.Background = palette.Tint(tint: 0xFF0067C0u);
        TitleTileIcon.Fill = palette.OnTint;
        ViewModel.UsePalette(palette: palette);
    }

    /// A paused source's page has a badge, as it waits for you.
    void ShowBadges()
    {
        foreach (var source in ViewModel.Sources)
        {
            var item = sources[source.Entry.Id].Item;
            item.InfoBadge = source.IsPaused
                && Application.Current.Resources.TryGetValue(key: "CautionIconInfoBadgeStyle", value: out var style)
                && style is Style badgeStyle
                    ? new InfoBadge { Style = badgeStyle }
                    : null;
        }
    }

    /// Its pages' pane opens and closes by a button only once the window is too narrow to keep it open, as in Windows'
    /// own Settings.
    void OnDisplayModeChanged(NavigationView sender, NavigationViewDisplayModeChangedEventArgs args) =>
        Navigation.IsPaneToggleButtonVisible = args.DisplayMode != NavigationViewDisplayMode.Expanded;

    void OnSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem item)
        {
            ShowPage(item: item);
        }
    }

    void ShowPage(NavigationViewItem item)
    {
        var source = sources.Values.FirstOrDefault(predicate: candidate => candidate.Item == item);
        if (source.Page is { } page)
        {
            Page.Content = page;
            PageTitle.Text = page.ViewModel.Name;
            DispatcherQueue.TryEnqueue(callback: page.FocusFirst);
        }
        else
        {
            Page.Content = general;
            PageTitle.Text = "General";
        }
        Scroller.ChangeView(horizontalOffset: null, verticalOffset: 0, zoomFactor: null, disableAnimation: true);
    }
}
