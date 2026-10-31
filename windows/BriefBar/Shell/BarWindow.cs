using System.Runtime.InteropServices;
using BriefBar.Core.Logging;
using BriefBar.Core.Presentation;
using BriefBar.Interop;
using BriefBar.ViewModels;
using BriefBar.Views;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Foundation;
using WinRT.Interop;

namespace BriefBar.Shell;

/// One display's bar: its window, the space it reserves, and the window messages a docked bar has to handle. It never
/// becomes the active window, so a click on it leaves your window active, and it isn't on the taskbar or in Alt+Tab.
internal sealed partial class BarWindow : Window
{
    readonly AppShell shell;
    readonly AppBarReservation reservation;
    readonly SubclassProc subclass;
    readonly BarView view;
    bool placed;
    bool hiddenForFullScreen;
    bool closingForGood;
    bool closed;

    public BarWindow(AppShell shell, Display display)
    {
        this.shell = shell;
        Display = display;
        Hwnd = WindowNative.GetWindowHandle(target: this);
        Title = "BriefBar";
        var presenter = OverlappedPresenter.Create();
        presenter.SetBorderAndTitleBar(hasBorder: false, hasTitleBar: false);
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        AppWindow.SetPresenter(appWindowPresenter: presenter);
        // Not a tool window: on Windows 11, tool windows don't hear when scaling changes.
        var style = User32.GetWindowLongPtr(hWnd: Hwnd, index: WindowStyles.GWL_EXSTYLE).ToInt64();
        User32.SetWindowLongPtr(
            hWnd: Hwnd,
            index: WindowStyles.GWL_EXSTYLE,
            value: (nint)((style | WindowStyles.WS_EX_NOACTIVATE) & ~WindowStyles.WS_EX_APPWINDOW));
        var square = Dwm.TrySet(hWnd: Hwnd, attribute: DwmAttributes.DWMWA_WINDOW_CORNER_PREFERENCE, value: DwmAttributes.DWMWCP_DONOTROUND);
        var borderless = Dwm.TrySet(hWnd: Hwnd, attribute: DwmAttributes.DWMWA_BORDER_COLOR, value: DwmAttributes.DWMWA_COLOR_NONE);
        if (!square || !borderless)
        {
            Log.Write(line: $"bar {display.Handle}: Windows kept its corners {!square} or border {!borderless}");
        }
        // WindowProc uses the reservation from its first message on.
        reservation = new AppBarReservation(hwnd: Hwnd, edge: BarEdge.Top);
        subclass = WindowProc;
        ComCtl32.SetWindowSubclass(hWnd: Hwnd, callback: subclass, id: 1, data: 0);
        WindowMenu.Remove(hwnd: Hwnd);
        view = new BarView(viewModel: ViewModel);
        view.ItemPressed += (_, args) => shell.ItemPressed(bar: this, target: args.Target, anchor: AnchorOf(item: args.Item));
        view.EmptySpacePressed += (_, _) => shell.EmptySpacePressed();
        view.QuitRequested += (_, _) => shell.Quit();
        view.ActualThemeChanged += (_, _) => shell.ThemeChanged(theme: view.ActualTheme);
        Content = view;
        SystemBackdrop = new ActiveAcrylic(kind: DesktopAcrylicKind.Base);
        // A bar closes only as BriefBar quits or displays change. Another program asking it to close, as `taskkill`
        // without /F does, asks BriefBar to quit, which gives every bar's space back.
        AppWindow.Closing += (_, args) =>
        {
            if (!closingForGood)
            {
                args.Cancel = true;
                shell.CloseRequested();
            }
        };
        Closed += (_, _) => closed = true;
    }

    public nint Hwnd { get; }

    public Display Display { get; private set; }

    public BarViewModel ViewModel { get; } = new();

    /// Where the bar is, in physical pixels.
    public PixelRect Rect { get; private set; }

    public ElementTheme Theme => view.ActualTheme;

    /// Reserves the top of its display and puts the bar there, unless it's there already, or `force`. A bar whose
    /// display is gone asks for a bar on each display again instead.
    public void Place(bool force)
    {
        if (closed)
        {
            return;
        }
        if (Displays.Of(monitor: Display.Handle) is not { } display)
        {
            shell.DisplaysChanged();
            return;
        }
        Display = display;
        var height = BarMetrics.HeightPixels(textScale: shell.TextScale, displayScale: Display.Scale);
        reservation.Register();
        var wanted = reservation.Query(display: Display.Bounds, height: height);
        if (placed && !force && wanted == Rect)
        {
            return;
        }
        Rect = reservation.Reserve(rect: wanted);
        // The first placement also has Windows work out the frame again, which the bar has none of (WM_NCCALCSIZE).
        var frameChanged = placed ? 0 : WindowStyles.SWP_FRAMECHANGED;
        placed = true;
        var show = hiddenForFullScreen ? 0 : WindowStyles.SWP_SHOWWINDOW;
        User32.SetWindowPos(
            hWnd: Hwnd, hWndInsertAfter: WindowStyles.HWND_TOPMOST, x: Rect.Left, y: Rect.Top, cx: Rect.Width, cy: Rect.Height,
            flags: WindowStyles.SWP_NOACTIVATE | frameChanged | show);
        Log.Write(line: $"bar {Display.Handle}: at {Rect}, scale {Display.Scale}");
    }

    /// Steps aside while a full-screen window, such as a game or a video, is in front on its display.
    public void SetHiddenForFullScreen(bool hidden)
    {
        if (hidden == hiddenForFullScreen || closed)
        {
            return;
        }
        hiddenForFullScreen = hidden;
        Log.Write(line: $"bar {Display.Handle}: {(hidden ? FullScreenState.Hidden : FullScreenState.Shown)} for full screen");
        if (hidden)
        {
            User32.ShowWindow(hWnd: Hwnd, command: WindowStyles.SW_HIDE);
        }
        else
        {
            User32.SetWindowPos(
                hWnd: Hwnd, hWndInsertAfter: WindowStyles.HWND_TOPMOST, x: Rect.Left, y: Rect.Top, cx: Rect.Width, cy: Rect.Height,
                flags: WindowStyles.SWP_NOACTIVATE | WindowStyles.SWP_SHOWWINDOW);
        }
    }

    /// Where the Overview's item is, for a panel opened by something other than a press, such as a second start.
    public PixelRect OverviewAnchor() => AnchorOf(item: view.OverviewItem);

    public bool Contains(Win32Point point) => !closed && User32.Contains(hWnd: Hwnd, point: point);

    /// Gives the reserved space back at once, without closing the window.
    public void GiveSpaceBack()
    {
        reservation.Remove();
        placed = false;
    }

    /// Explorer restarted and forgot every reservation: reserves the space again.
    public void ReserveAgain()
    {
        reservation.Forget();
        Place(force: true);
    }

    /// Closes the window for good. Call `GiveSpaceBack` first.
    public void CloseWindow()
    {
        if (closed)
        {
            return;
        }
        closingForGood = true;
        ComCtl32.RemoveWindowSubclass(hWnd: Hwnd, callback: subclass, id: 1);
        Close();
    }

    /// Where `item` is on the screen, in physical pixels: across its width, and the bar's height.
    PixelRect AnchorOf(FrameworkElement item)
    {
        var scale = item.XamlRoot?.RasterizationScale ?? Display.Scale;
        var origin = item.TransformToVisual(visual: null).TransformPoint(point: new Point(x: 0, y: 0));
        var left = Rect.Left + (int)Math.Round(value: origin.X * scale, mode: MidpointRounding.AwayFromZero);
        var width = (int)Math.Round(value: item.ActualWidth * scale, mode: MidpointRounding.AwayFromZero);
        return new PixelRect(Left: left, Top: Rect.Top, Width: width, Height: Rect.Height);
    }

    nint WindowProc(nint hWnd, uint message, nint wParam, nint lParam, nuint id, nuint data)
    {
        switch (message)
        {
            case AppBarReservation.CallbackMessage:
                OnAppBarNotification(notification: (int)wParam);
                return 0;
            case WindowMessages.WM_ACTIVATE:
                reservation.Activated();
                break;
            case WindowMessages.WM_MOUSEACTIVATE:
                // A click never makes the bar the active window, so none is spent activating it, whatever is in front.
                return WindowMessages.MA_NOACTIVATE;
            case WindowMessages.WM_WINDOWPOSCHANGED:
                reservation.Moved();
                break;
            case WindowMessages.WM_GETMINMAXINFO:
                return AllowAnySize(hWnd: hWnd, message: message, wParam: wParam, lParam: lParam);
            case WindowMessages.WM_NCCALCSIZE when wParam != 0:
                // No frame: the window is all content, so the items reach the screen's edge, and a flick of the pointer
                // to the top lands on one. Without this, WinUI's presenter keeps a 3-pixel dialog frame.
                return 0;
            case WindowMessages.WM_STYLECHANGING:
                return WindowMenu.OnStyleChanging(hWnd: hWnd, wParam: wParam, lParam: lParam);
            case WindowMessages.WM_SYSCOMMAND when ((int)wParam & WindowMessages.SC_MASK) == WindowMessages.SC_CLOSE:
                // Alt+F4 doesn't close a bar, as it doesn't close the taskbar.
                return 0;
            case WindowMessages.WM_NCDESTROY:
                ComCtl32.RemoveWindowSubclass(hWnd: hWnd, callback: subclass, id: 1);
                break;
            case WindowMessages.WM_DPICHANGED:
                // Windows suggests the bar's rect scaled to the new DPI: keep it where it is, then fit it to the new scaling.
                if (placed)
                {
                    Marshal.StructureToPtr(structure: Win32Rect.From(rect: Rect), ptr: lParam, fDeleteOld: false);
                }
                DispatcherQueue.TryEnqueue(callback: () => shell.LayoutChanged(bar: this, force: true));
                break;
            case WindowMessages.WM_SETTINGCHANGE when wParam == WindowMessages.SPI_SETWORKAREA:
                DispatcherQueue.TryEnqueue(callback: () => shell.LayoutChanged(bar: this, force: false));
                break;
            case WindowMessages.WM_DISPLAYCHANGE:
                DispatcherQueue.TryEnqueue(callback: shell.DisplaysChanged);
                break;
            case WindowMessages.WM_POWERBROADCAST when wParam == WindowMessages.PBT_APMRESUMEAUTOMATIC:
                DispatcherQueue.TryEnqueue(callback: shell.DisplaysChanged);
                break;
            case WindowMessages.WM_ENDSESSION when wParam != 0:
                // Windows is signing out or shutting down: give the space back now, while BriefBar still can.
                shell.GiveSpaceBack();
                break;
            default:
                if (message == AppShell.TaskbarCreated)
                {
                    DispatcherQueue.TryEnqueue(callback: shell.ExplorerRestarted);
                }
                break;
        }
        return ComCtl32.DefSubclassProc(hWnd: hWnd, message: message, wParam: wParam, lParam: lParam);
    }

    void OnAppBarNotification(int notification)
    {
        switch (notification)
        {
            case AppBarMessages.ABN_POSCHANGED:
                DispatcherQueue.TryEnqueue(callback: () => shell.LayoutChanged(bar: this, force: false));
                break;
            case AppBarMessages.ABN_FULLSCREENAPP:
                DispatcherQueue.TryEnqueue(callback: shell.CheckFullScreen);
                break;
            default:
                break;
        }
    }

    /// At 100% scaling the bar is shorter than a WinUI window may normally be.
    static nint AllowAnySize(nint hWnd, uint message, nint wParam, nint lParam)
    {
        var result = ComCtl32.DefSubclassProc(hWnd: hWnd, message: message, wParam: wParam, lParam: lParam);
        var info = Marshal.PtrToStructure<MinMaxInfo>(ptr: lParam);
        info.ptMinTrackSize = new Win32Point { X = 1, Y = 1 };
        Marshal.StructureToPtr(structure: info, ptr: lParam, fDeleteOld: false);
        return result;
    }
}
