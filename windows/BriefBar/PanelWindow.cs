using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Foundation;
using Windows.Graphics;
using Windows.System;
using WinRT.Interop;

namespace BriefBar;

/// The panel under the bar, like the popover of a menu-bar item on the Mac: it closes when you click elsewhere,
/// press Esc or click its item again.
internal sealed class PanelWindow : Window
{
    const double WidthDip = 400, MaxHeightDip = 720, GapDip = 6, MarginDip = 8;

    public IntPtr Hwnd { get; }
    /// What it shows: "overview", or a source's name. Nil while it's closed.
    public string? Key { get; private set; }
    public bool IsShown => Native.IsWindowVisible(Hwnd);
    /// What it showed when it last closed, and when.
    string? closedKey;
    long closedAt;

    /// It closed for `key` a moment ago, as it does when a click on the bar takes focus from it before the click
    /// reaches the item: that click closed it, so it shouldn't open it again.
    public bool JustClosed(string key) => closedKey == key && Environment.TickCount64 - closedAt < 600;

    readonly BarWindow bar;
    /// It became the active window since it opened: only then does losing that mean you went elsewhere.
    bool wasActive;
    /// The window that took over when the panel last stopped being the active window.
    IntPtr successor;
    readonly Native.SubclassProc subclass;
    Native.LowLevelMouseProc? mouseProc;
    IntPtr mouseHook;

    public PanelWindow(BarWindow bar)
    {
        this.bar = bar;
        Hwnd = WindowNative.GetWindowHandle(this);
        Title = "BriefBar";
        var presenter = OverlappedPresenter.Create();
        presenter.SetBorderAndTitleBar(true, false);
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        AppWindow.SetPresenter(presenter);
        // Owned by the bar: above it, and without a taskbar button of its own.
        Native.SetWindowLongPtr(Hwnd, Native.GWLP_HWNDPARENT, bar.Hwnd);
        int corners = Native.DWMWCP_ROUND;
        Native.DwmSetWindowAttribute(Hwnd, Native.DWMWA_WINDOW_CORNER_PREFERENCE, ref corners, sizeof(int));
        subclass = WindowProc;
        Native.SetWindowSubclass(Hwnd, subclass, 1, 0);
        Content = new Grid();
        SystemBackdrop = new ActiveAcrylic(DesktopAcrylicKind.Base);
        Activated += (_, args) =>
        {
            Log.Write($"panel {Key}: {args.WindowActivationState}");
            if (args.WindowActivationState != WindowActivationState.Deactivated)
            {
                wasActive = true;
                return;
            }
            if (!wasActive) return;
            var next = successor != IntPtr.Zero ? successor : Native.GetForegroundWindow();
            if (App.Current.IsOurs(next))
            {
                // A press on a bar moves focus to it before the press reaches its item, which then decides: the same
                // item closes the panel, another opens its own. So that isn't you going elsewhere. Unless the press
                // closed it by then, the panel takes focus back, for Esc.
                DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
                {
                    if (IsShown) Native.ForceForeground(Hwnd);
                });
                return;
            }
            Dismiss();
        };
    }

    IntPtr WindowProc(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr data)
    {
        // Losing activation names the window that's taking it.
        if (message == Native.WM_ACTIVATE) successor = (wParam.ToInt64() & 0xFFFF) == 0 ? lParam : IntPtr.Zero;
        return Native.DefSubclassProc(hWnd, message, wParam, lParam);
    }

    /// Shows `key`'s list under `anchor`, the item's rect on the screen.
    public void Open(string key, Native.RECT anchor)
    {
        Key = key;
        var root = PanelContent.Build(key, App.Current.Quit);
        var escape = new KeyboardAccelerator { Key = VirtualKey.Escape };
        escape.Invoked += (_, args) =>
        {
            args.Handled = true;
            Dismiss();
        };
        root.KeyboardAccelerators.Add(escape);
        Content = root;

        var display = bar.Display;
        double scale = display.Scale;
        double room = (display.Work.Height / scale) - GapDip - MarginDip;
        root.Measure(new Size(WidthDip, double.PositiveInfinity));
        double heightDip = Math.Min(root.DesiredSize.Height > 40 ? root.DesiredSize.Height : MaxHeightDip, Math.Min(MaxHeightDip, room));
        int width = (int)Math.Round(WidthDip * scale), height = (int)Math.Round(heightDip * scale);
        int margin = (int)Math.Round(MarginDip * scale);
        // Centered under its item, as far as the display's edges allow.
        int x = Math.Clamp(anchor.Left + (anchor.Width - width) / 2, display.Work.Left + margin, display.Work.Right - margin - width);
        int y = bar.Rect.Bottom + (int)Math.Round(GapDip * scale);
        // Moving first lets the window take on the display's scaling before it's sized for it.
        AppWindow.Move(new PointInt32(x, y));
        AppWindow.ResizeClient(new SizeInt32(width, height));
        AppWindow.Move(new PointInt32(x, y));
        wasActive = false;
        Activate();
        bool front = Native.ForceForeground(Hwnd);
        PanelContent.FocusList(root);
        WatchClicks();
        Log.Write($"panel {key}: opened at {x},{y} {width}x{height} (measured {root.DesiredSize.Height:0} dip), in front: {front}");
    }

    public void Dismiss()
    {
        StopWatchingClicks();
        if (!IsShown) return;
        AppWindow.Hide();
        Log.Write($"panel {Key}: dismissed");
        closedKey = Key;
        closedAt = Environment.TickCount64;
        Key = null;
        bar.PanelDismissed();
    }

    /// Closes the panel when you click anywhere but the panel or its bar, even if it couldn't become the active window.
    void WatchClicks()
    {
        if (mouseHook != IntPtr.Zero) return;
        mouseProc ??= OnMouse;
        mouseHook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, mouseProc, Native.GetModuleHandle(null), 0);
    }

    void StopWatchingClicks()
    {
        if (mouseHook == IntPtr.Zero) return;
        Native.UnhookWindowsHookEx(mouseHook);
        mouseHook = IntPtr.Zero;
    }

    IntPtr OnMouse(int code, IntPtr message, IntPtr data)
    {
        if (code >= 0 && (uint)message is Native.WM_LBUTTONDOWN or Native.WM_RBUTTONDOWN or Native.WM_MBUTTONDOWN)
        {
            // MSLLHOOKSTRUCT starts with the point, in physical pixels.
            var point = System.Runtime.InteropServices.Marshal.PtrToStructure<Native.POINT>(data);
            if (!Native.Contains(Hwnd, point) && !Native.Contains(bar.Hwnd, point)) DispatcherQueue.TryEnqueue(Dismiss);
        }
        return Native.CallNextHookEx(mouseHook, code, message, data);
    }
}
