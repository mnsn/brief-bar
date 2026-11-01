using BriefBar.Core.Presentation;
using BriefBar.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.System;

namespace BriefBar.Views;

/// The panel under an item in the bar: a header, a banner when its section can't show everything, its brief, and its
/// rows in groups, in a list the keyboard and Narrator move through. Ctrl+1 to Ctrl+9, Ctrl+Tab and Ctrl+Shift+Tab ask
/// for another of the bar's items (`PanelKeys`).
public sealed partial class PanelView : UserControl
{
    ScrollViewer? scroller;

    public PanelView(PanelViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
        GroupedRows.Source = viewModel.Groups;
        AddItemKeys();
    }

    public PanelViewModel ViewModel { get; }

    public event EventHandler? EscapePressed;

    public event EventHandler? QuitRequested;

    /// Ctrl and a number from 1 to 9 was pressed, on the number row or the keypad.
    public event EventHandler<int>? NumberKeyPressed;

    /// Ctrl+Tab was pressed.
    public event EventHandler? NextKeyPressed;

    /// Ctrl+Shift+Tab was pressed.
    public event EventHandler? PreviousKeyPressed;

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

    /// The keys for the bar's other items, beside Esc, so they work wherever the keyboard is in the panel.
    void AddItemKeys()
    {
        for (var number = 1; number <= PanelKeys.LastNumber; number++)
        {
            var pressed = number;
            AddKey(key: VirtualKey.Number0 + number, modifiers: VirtualKeyModifiers.Control, invoked: () => NumberKeyPressed?.Invoke(sender: this, e: pressed));
            AddKey(key: VirtualKey.NumberPad0 + number, modifiers: VirtualKeyModifiers.Control, invoked: () => NumberKeyPressed?.Invoke(sender: this, e: pressed));
        }
        AddKey(key: VirtualKey.Tab, modifiers: VirtualKeyModifiers.Control, invoked: () => NextKeyPressed?.Invoke(sender: this, e: EventArgs.Empty));
        AddKey(
            key: VirtualKey.Tab,
            modifiers: VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift,
            invoked: () => PreviousKeyPressed?.Invoke(sender: this, e: EventArgs.Empty));
    }

    void AddKey(VirtualKey key, VirtualKeyModifiers modifiers, Action invoked)
    {
        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
        accelerator.Invoked += (_, args) =>
        {
            args.Handled = true;
            invoked();
        };
        Root.KeyboardAccelerators.Add(item: accelerator);
    }

    void OnEscape(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        EscapePressed?.Invoke(sender: this, e: EventArgs.Empty);
    }

    void OnQuitClick(object sender, RoutedEventArgs e) => QuitRequested?.Invoke(sender: this, e: EventArgs.Empty);
}
