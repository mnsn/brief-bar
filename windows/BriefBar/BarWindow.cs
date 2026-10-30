using System.Runtime.InteropServices;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;
using WinRT.Interop;

namespace BriefBar;

/// The bar at the top of one display: the brief on the left, and each source's counts on the right, as BriefBar's
/// menu-bar items show them on a Mac. Clicking either opens a panel under it.
internal sealed class BarWindow : Window
{
    public const double HeightDip = 32;

    public IntPtr Hwnd { get; }
    public Display Display { get; private set; }
    /// Where the bar is, in physical pixels.
    public Native.RECT Rect { get; private set; }

    readonly AppBar appBar;
    readonly Native.SubclassProc subclass;
    PanelWindow? panel;
    Border? openItem;
    bool placed, hiddenForFullScreen, closed;
    string? lastPressKey;
    long lastPressAt;

    public BarWindow(Display display)
    {
        Display = display;
        Hwnd = WindowNative.GetWindowHandle(this);
        Title = "BriefBar";
        var presenter = OverlappedPresenter.Create();
        presenter.SetBorderAndTitleBar(false, false);
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        AppWindow.SetPresenter(presenter);
        // Clicking the bar leaves your window active, and keeps the bar off the taskbar and out of Alt+Tab. Not a tool
        // window: on Windows 11, tool windows don't hear when scaling changes.
        long style = Native.GetWindowLongPtr(Hwnd, Native.GWL_EXSTYLE).ToInt64();
        Native.SetWindowLongPtr(Hwnd, Native.GWL_EXSTYLE, new IntPtr((style | Native.WS_EX_NOACTIVATE) & ~Native.WS_EX_APPWINDOW));
        int corners = Native.DWMWCP_DONOTROUND;
        Native.DwmSetWindowAttribute(Hwnd, Native.DWMWA_WINDOW_CORNER_PREFERENCE, ref corners, sizeof(int));
        int noBorder = Native.DWMWA_COLOR_NONE;
        Native.DwmSetWindowAttribute(Hwnd, Native.DWMWA_BORDER_COLOR, ref noBorder, sizeof(int));
        subclass = WindowProc;
        Native.SetWindowSubclass(Hwnd, subclass, 1, 0);
        appBar = new AppBar(Hwnd);
        Content = Build();
        SystemBackdrop = new ActiveAcrylic(DesktopAcrylicKind.Base);
        Closed += (_, _) => closed = true;
    }

    /// Reserves the top of the display and puts the bar there, unless it's already there.
    public void Place(bool force = false)
    {
        if (closed) return;
        Display = Display.Of(Display.Handle) ?? Display;
        int height = (int)Math.Round(HeightDip * Display.Scale);
        appBar.Register();
        var wanted = appBar.Query(Display.Bounds, height);
        if (placed && !force && wanted.SameAs(Rect)) return;
        Rect = appBar.Reserve(wanted);
        placed = true;
        uint show = hiddenForFullScreen ? 0 : Native.SWP_SHOWWINDOW;
        Native.SetWindowPos(Hwnd, Native.HWND_TOPMOST, Rect.Left, Rect.Top, Rect.Width, Rect.Height, Native.SWP_NOACTIVATE | show);
    }

    /// Steps aside while a full-screen app, such as a game or a video, is on this display.
    public void SetHiddenForFullScreen(bool hidden)
    {
        if (hidden == hiddenForFullScreen || closed) return;
        hiddenForFullScreen = hidden;
        Log.Write($"bar {Display.Handle}: {(hidden ? "hidden for a full-screen app" : "shown again")}");
        if (hidden)
        {
            panel?.Dismiss();
            Native.ShowWindow(Hwnd, Native.SW_HIDE);
        }
        else
        {
            Native.SetWindowPos(Hwnd, Native.HWND_TOPMOST, Rect.Left, Rect.Top, Rect.Width, Rect.Height,
                Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        }
    }

    public bool Owns(IntPtr hwnd) => hwnd == Hwnd || (panel is not null && hwnd == panel.Hwnd);

    /// Another app came to the front: close the panel, as clicking elsewhere would.
    public void DismissPanel() => panel?.Dismiss();

    /// Gives the space back and closes.
    public void Shutdown()
    {
        if (closed) return;
        panel?.Close();
        appBar.Remove();
        Native.RemoveWindowSubclass(Hwnd, subclass, 1);
        Close();
    }

    public void PanelDismissed()
    {
        if (openItem is { } item) item.Background = Look.Clear;
        openItem = null;
    }

    FrameworkElement Build()
    {
        // A background, so a press anywhere on the bar reaches it: one between items closes the panel.
        var grid = new Grid { Padding = new Thickness(6, 0, 6, 0), Background = Look.Clear };
        grid.PointerPressed += (_, _) => panel?.Dismiss();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        // The brief's first line, which opens the Overview.
        var brief = new Grid { ColumnSpacing = 8 };
        brief.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        brief.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        brief.Children.Add(Look.Mark(16));
        var line = Look.Text(Demo.Brief[0].Text, 12, Look.Primary);
        Grid.SetColumn(line, 1);
        brief.Children.Add(line);
        var overview = Item(brief, "overview");
        overview.HorizontalAlignment = HorizontalAlignment.Left;
        overview.Margin = new Thickness(0, 0, 24, 0);
        ToolTipService.SetToolTip(overview, $"{Demo.Count(State.NeedsYou)} need you · {Demo.Count(State.Failing)} went wrong · "
            + $"{Demo.Count(State.Running)} running · {Demo.Count(State.Done)} done or ready");
        grid.Children.Add(overview);

        var items = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        foreach (var source in Demo.BarOrder) items.Children.Add(SourceItem(source));
        Grid.SetColumn(items, 1);
        grid.Children.Add(items);
        return grid;
    }

    /// A source's glyph, then its counts by state.
    Border SourceItem(Source source)
    {
        var look = Look.Of(source);
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var counts = Look.Order(source).Select(state => (state, count: Demo.Count(state, source))).Where(pair => pair.count > 0).ToList();
        if (look.ColoredInBar)
        {
            // Teams: the glyph in its color with the unread count, as on the Mac.
            var unread = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            unread.Children.Add(look.Glyph.Make(16, counts.Count > 0 ? Look.Brush(look.Color) : Look.Primary));
            if (counts.Count > 0) unread.Children.Add(Look.Text(counts.Sum(pair => pair.count).ToString(), 12, Look.Primary, Look.SemiBold));
            content.Children.Add(unread);
        }
        else
        {
            content.Children.Add(look.Glyph.Make(16, Look.Primary));
            foreach (var (state, count) in counts) content.Children.Add(Look.Count(state, source, count));
        }
        var item = Item(content, source.ToString());
        var summary = string.Join(", ", counts.Select(pair => $"{pair.count} {Look.CountLabel(pair.state)}"));
        ToolTipService.SetToolTip(item, $"{look.Owner} {look.Title}: {(summary.Length > 0 ? summary : "nothing new")}");
        return item;
    }

    Border Item(FrameworkElement content, string key)
    {
        var item = new Border
        {
            Child = content,
            Height = 26,
            Padding = new Thickness(8, 0, 8, 0),
            CornerRadius = new CornerRadius(5),
            VerticalAlignment = VerticalAlignment.Center,
            Background = Look.Clear,
        };
        item.PointerEntered += (_, _) => { if (item != openItem) item.Background = Look.Hover; };
        item.PointerExited += (_, _) => { if (item != openItem) item.Background = Look.Clear; };
        // On the press, not the click: a click can lose its release when the press moves focus between BriefBar's
        // windows, as it does when it closes the panel.
        item.PointerPressed += (_, args) =>
        {
            if (!args.GetCurrentPoint(item).Properties.IsLeftButtonPressed) return;
            args.Handled = true;
            // A press that makes the bar the active window can arrive twice; the second would close the panel the
            // first opened.
            long now = Environment.TickCount64;
            if (key == lastPressKey && now - lastPressAt < 350)
            {
                Log.Write($"bar {Display.Handle}: ignored a repeated press on {key}");
                return;
            }
            lastPressKey = key;
            lastPressAt = now;
            Toggle(item, key);
        };
        return item;
    }

    void Toggle(Border item, string key)
    {
        panel ??= new PanelWindow(this);
        Log.Write($"bar {Display.Handle}: clicked {key}; panel shown: {panel.IsShown}, showing {panel.Key ?? "nothing"}");
        if (panel.IsShown && panel.Key == key)
        {
            panel.Dismiss();
            return;
        }
        if (panel.JustClosed(key)) return;
        // Only one panel at a time, across displays.
        App.Current.DismissPanels(except: this);
        if (openItem is { } previous) previous.Background = Look.Clear;
        openItem = item;
        item.Background = Look.Pressed;
        panel.Open(key, AnchorOf(item));
    }

    /// Where `item` is on the screen, in physical pixels.
    Native.RECT AnchorOf(FrameworkElement item)
    {
        double scale = item.XamlRoot.RasterizationScale;
        var origin = item.TransformToVisual(null).TransformPoint(new Point(0, 0));
        return new Native.RECT
        {
            Left = Rect.Left + (int)Math.Round(origin.X * scale),
            Top = Rect.Top,
            Right = Rect.Left + (int)Math.Round((origin.X + item.ActualWidth) * scale),
            Bottom = Rect.Bottom,
        };
    }

    IntPtr WindowProc(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr data)
    {
        switch (message)
        {
            case AppBar.CallbackMessage:
                switch ((int)wParam)
                {
                    case Native.ABN_POSCHANGED:
                        DispatcherQueue.TryEnqueue(() => Place());
                        break;
                    case Native.ABN_FULLSCREENAPP:
                        DispatcherQueue.TryEnqueue(App.Current.CheckFullScreen);
                        break;
                }
                return IntPtr.Zero;
            case Native.WM_ACTIVATE:
                appBar.Activated();
                break;
            case Native.WM_MOUSEACTIVATE:
                // Clicking the bar never makes it the active window, so no click is spent activating it, whatever app
                // is in front.
                return Native.MA_NOACTIVATE;
            case Native.WM_WINDOWPOSCHANGED:
                appBar.Moved();
                break;
            case Native.WM_GETMINMAXINFO:
            {
                // No minimum size: at 100% scaling the bar is shorter than a window normally may be.
                var result = Native.DefSubclassProc(hWnd, message, wParam, lParam);
                var info = Marshal.PtrToStructure<Native.MINMAXINFO>(lParam);
                info.ptMinTrackSize = new Native.POINT { X = 1, Y = 1 };
                Marshal.StructureToPtr(info, lParam, false);
                return result;
            }
            case Native.WM_DPICHANGED:
                // Windows suggests the bar's rect scaled to the new DPI. Keep it where it is, then fit it to the new scaling.
                if (placed) Marshal.StructureToPtr(Rect, lParam, false);
                DispatcherQueue.TryEnqueue(() => Place());
                break;
            case Native.WM_DISPLAYCHANGE:
                DispatcherQueue.TryEnqueue(App.Current.DisplaysChanged);
                break;
            default:
                if (message == App.TaskbarCreated)
                {
                    // Explorer restarted: reserve the space again.
                    appBar.Forget();
                    DispatcherQueue.TryEnqueue(() => Place(force: true));
                }
                break;
        }
        return Native.DefSubclassProc(hWnd, message, wParam, lParam);
    }
}
