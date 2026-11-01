using BriefBar.Core.Presentation;
using BriefBar.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace BriefBar.Views;

/// One display's bar: the Overview's item, and an item per section, as real buttons that Narrator names and UI
/// Automation can press. The bar never takes the keyboard; from a panel, Ctrl+1 to Ctrl+9 and Ctrl+Tab show each item's
/// (`PanelKeys`), as its tooltip says.
public sealed partial class BarView : UserControl
{
    public BarView(BarViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
    }

    public BarViewModel ViewModel { get; }

    /// The Overview's item, for where its panel goes.
    public FrameworkElement OverviewItem => OverviewButton;

    /// The item that shows `target`, for where its panel goes, or null while the bar has none for it on screen.
    public FrameworkElement? ItemFor(PanelTarget target)
    {
        if (target.IsOverview)
        {
            return OverviewButton;
        }
        var item = ViewModel.Items.FirstOrDefault(predicate: candidate => candidate.Target == target);
        return item is null ? null : SectionItems.ContainerFromItem(item: item) as FrameworkElement;
    }

    /// An item was pressed: the panel it opens, and the item, for where the panel goes.
    public event EventHandler<BarItemPressedEventArgs>? ItemPressed;

    /// The empty space between the items was pressed.
    public event EventHandler? EmptySpacePressed;

    public event EventHandler? QuitRequested;

    void OnOverviewClick(object sender, RoutedEventArgs e) =>
        ItemPressed?.Invoke(sender: this, e: new BarItemPressedEventArgs(target: PanelTarget.Overview, item: OverviewButton));

    void OnItemClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: BarItemViewModel item } element)
        {
            ItemPressed?.Invoke(sender: this, e: new BarItemPressedEventArgs(target: item.Target, item: element));
        }
    }

    void OnRootPressed(object sender, PointerRoutedEventArgs e)
    {
        // Items handle their own presses; what's left landed between them.
        if (e.GetCurrentPoint(relativeTo: Root).Properties.IsLeftButtonPressed)
        {
            EmptySpacePressed?.Invoke(sender: this, e: EventArgs.Empty);
        }
    }

    void OnQuitClick(object sender, RoutedEventArgs e) => QuitRequested?.Invoke(sender: this, e: EventArgs.Empty);
}
