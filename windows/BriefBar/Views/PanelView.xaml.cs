using BriefBar.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace BriefBar.Views;

/// The panel under an item in the bar: a header, a banner when its section can't show everything, its brief, and its
/// rows in groups, in a list the keyboard and Narrator move through.
public sealed partial class PanelView : UserControl
{
    ScrollViewer? scroller;

    public PanelView(PanelViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
        GroupedRows.Source = viewModel.Groups;
    }

    public PanelViewModel ViewModel { get; }

    public event EventHandler? EscapePressed;

    public event EventHandler? QuitRequested;

    /// How tall it would be `width` device-independent pixels wide, as tall as `maxHeight` at most: its rows scroll
    /// past that. Measuring it without a limit would put every row on screen, in place of only those in view. Its
    /// bindings connect first, as they otherwise would only once it's on screen.
    public double ContentHeight(double width, double maxHeight)
    {
        if (!IsLoaded)
        {
            Bindings.Update();
        }
        Measure(availableSize: new Size(width: width, height: maxHeight));
        return DesiredSize.Height;
    }

    /// Puts the keyboard on its first row, or on More when it has none, so arrows and Esc work at once. Only once it's
    /// laid out: before that, the list has no rows to focus, and focusing it scrolls it.
    public void FocusFirst()
    {
        if (!ViewModel.IsEmpty && List.ContainerFromIndex(index: 0) is ListViewItem first && first.Focus(value: FocusState.Programmatic))
        {
            return;
        }
        MoreButton.Focus(value: FocusState.Programmatic);
    }

    /// Back to the top, at once, for a panel that opens.
    public void ScrollToTop()
    {
        scroller ??= Descendant<ScrollViewer>(root: List);
        scroller?.ChangeView(horizontalOffset: null, verticalOffset: 0, zoomFactor: null, disableAnimation: true);
    }

    /// The first `T` in `root`'s visual tree, depth first.
    static T? Descendant<T>(DependencyObject root) where T : DependencyObject
    {
        var count = VisualTreeHelper.GetChildrenCount(reference: root);
        for (var index = 0; index < count; index++)
        {
            var child = VisualTreeHelper.GetChild(reference: root, childIndex: index);
            if (child is T found)
            {
                return found;
            }
            if (Descendant<T>(root: child) is { } deeper)
            {
                return deeper;
            }
        }
        return null;
    }

    void OnEscape(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        EscapePressed?.Invoke(sender: this, e: EventArgs.Empty);
    }

    void OnQuitClick(object sender, RoutedEventArgs e) => QuitRequested?.Invoke(sender: this, e: EventArgs.Empty);
}
