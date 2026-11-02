using BriefBar.Core;
using BriefBar.Core.Presentation;
using BriefBar.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.System;

namespace BriefBar.Views;

/// The panel under an item in the bar: a header, with a menu that sorts its list where it can be sorted, a banner when its
/// section can't show everything, its brief, and its rows in groups, in a list the keyboard and Narrator move through.
/// Pressing a row does what it offers first; its menu, from a right-click, the menu key or Shift+F10, offers everything it
/// can do. Ctrl+1 to Ctrl+9, Ctrl+Tab and Ctrl+Shift+Tab ask for another of the bar's items (`PanelKeys`).
public sealed partial class PanelView : UserControl
{
    ScrollViewer? scroller;

    public PanelView(PanelViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
        GroupedRows.Source = viewModel.Groups;
        viewModel.Resorted += OnResorted;
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

    /// Something in it asked its source to do something.
    public event EventHandler<PanelCommandEventArgs>? CommandRequested;

    public event EventHandler? SettingsRequested;

    /// It shows more or less than it did, as a group folds, so it may need to be another height.
    public event EventHandler? ContentResized;

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

    /// Puts the keyboard on its first row, or on what comes first in its list when it has none, such as a group's
    /// heading, or on More, so arrows and Esc work at once. Only once it's laid out: before that, the list has no rows to
    /// focus, and focusing it scrolls it.
    public void FocusFirst()
    {
        if (List.ContainerFromIndex(index: 0) is null && List.Items.Count > 0)
        {
            // Just scrolled back to the top: its first row may not be on screen yet.
            List.UpdateLayout();
        }
        if (List.ContainerFromIndex(index: 0) is ListViewItem first && first.Focus(value: FocusState.Programmatic))
        {
            return;
        }
        if (FocusManager.FindFirstFocusableElement(searchScope: List) is Control control && control.Focus(value: FocusState.Programmatic))
        {
            return;
        }
        if (ViewModel.OffersSettings && EmptySettingsButton.Focus(value: FocusState.Programmatic))
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

    /// The list item `element` is in, or null for one outside every item, such as a group's heading.
    static ListViewItem? ItemOf(DependencyObject? element)
    {
        for (var current = element; current is not null; current = VisualTreeHelper.GetParent(reference: current))
        {
            if (current is ListViewItem item)
            {
                return item;
            }
            if (current is ListViewBase)
            {
                return null;
            }
        }
        return null;
    }

    void Request(RowViewModel row, PanelCommand command) =>
        CommandRequested?.Invoke(sender: this, e: new PanelCommandEventArgs(
            request: new CommandRequest(Section: row.Section, Command: command.Key, RowId: row.Id), opens: command.Opens));

    void OnRowClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is RowViewModel { Commands.Count: > 0 } row)
        {
            Request(row: row, command: row.Commands[0]);
        }
    }

    /// A row's menu: everything it can do, the first being what pressing it does.
    void OnListContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        if (ItemOf(element: args.OriginalSource as DependencyObject) is not { Content: RowViewModel { Commands.Count: > 0 } row } item)
        {
            return;
        }
        args.Handled = true;
        var menu = new MenuFlyout();
        foreach (var command in row.Commands)
        {
            var entry = new MenuFlyoutItem { Text = command.Title };
            if (command.Help is { } help)
            {
                ToolTipService.SetToolTip(element: entry, value: help);
            }
            entry.Click += (_, _) => Request(row: row, command: command);
            menu.Items.Add(item: entry);
        }
        var options = new FlyoutShowOptions();
        if (args.TryGetPosition(relativeTo: item, point: out var point))
        {
            options.Position = point;
        }
        menu.ShowAt(placementTarget: item, showOptions: options);
    }

    void OnTagClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: RowViewModel row } && row.TagPanelCommand is { } command)
        {
            Request(row: row, command: command);
        }
    }

    void OnFoldClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: RowGroupViewModel group })
        {
            ViewModel.ToggleFold(group: group);
            ContentResized?.Invoke(sender: this, e: EventArgs.Empty);
        }
    }

    void OnGroupCommandClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: RowGroupViewModel { Section: { } section, Command: { } command } group })
        {
            CommandRequested?.Invoke(sender: this, e: new PanelCommandEventArgs(
                request: new CommandRequest(Section: section, Command: command.Key, GroupKey: group.Key), opens: command.Opens));
        }
    }

    void OnSectionCommandClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: PanelCommand command } && ViewModel.Target.Section is { } section)
        {
            RequestOf(section: section, command: command);
        }
    }

    /// The banner's button, about its section: the Overview's banner is about one of the sections it mixes.
    void OnProblemCommandClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel.ProblemCommand is { } command && ViewModel.ProblemSection is { } section)
        {
            RequestOf(section: section, command: command);
        }
    }

    /// A notice's button, about the panel's section.
    void OnNoticeCommandClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: NoticeViewModel { Command: { } command } } && ViewModel.Target.Section is { } section)
        {
            RequestOf(section: section, command: command);
        }
    }

    /// The sort menu: each order its section offers, the one in use checked.
    void OnSortClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Sort is not { } sort || ViewModel.Target.Section is not { } section)
        {
            return;
        }
        var menu = new MenuFlyout();
        foreach (var choice in sort.Choices)
        {
            var entry = new RadioMenuFlyoutItem { Text = choice.Title, GroupName = "Sort", IsChecked = choice.Key == sort.Chosen };
            entry.Click += (_, _) => RequestOf(section: section, command: choice);
            menu.Items.Add(item: entry);
        }
        menu.ShowAt(placementTarget: SortButton, showOptions: new FlyoutShowOptions { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight });
    }

    /// Sorted another way, the list starts at its top again, as it does as it opens, once it's laid out: otherwise it would
    /// keep a row it still has in view, such as one of Done's, and open far down the list.
    void OnResorted(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(priority: Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, callback: () =>
    {
        List.UpdateLayout();
        ScrollToTop();
    });

    void RequestOf(SectionId section, PanelCommand command) =>
        CommandRequested?.Invoke(sender: this, e: new PanelCommandEventArgs(
            request: new CommandRequest(Section: section, Command: command.Key), opens: command.Opens));

    void OnSettingsClick(object sender, RoutedEventArgs e) => SettingsRequested?.Invoke(sender: this, e: EventArgs.Empty);

    void OnEscape(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        EscapePressed?.Invoke(sender: this, e: EventArgs.Empty);
    }

    void OnQuitClick(object sender, RoutedEventArgs e) => QuitRequested?.Invoke(sender: this, e: EventArgs.Empty);
}
