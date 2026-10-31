using System.Runtime.InteropServices;
using BriefBar.Core.Logging;
using BriefBar.Core.Presentation;
using BriefBar.Interop;
using BriefBar.ViewModels;
using BriefBar.Views;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;
using WinRT.Interop;

namespace BriefBar.Shell;

/// The panel's window, like a menu-bar item's popover on the Mac. It hides, rather than closes, when you press Esc,
/// click anywhere but BriefBar, or bring another app forward; `PanelController` decides the rest. It shows its own view
/// model, which goes with it.
internal sealed partial class PanelWindow : Window
{
    readonly PanelController controller;
    readonly PanelView view;
    readonly SubclassProc subclass;
    readonly LowLevelMouseProc mouseCallback;
    nint mouseHook;
    /// It became the active window since it was shown: only then does losing that mean you went elsewhere.
    bool wasActive;
    /// The window that took over when it last stopped being the active window.
    nint successor;
    /// How many times it was shown, so that something meant for one showing doesn't touch the next.
    int showing;
    bool closingForGood;
    bool gone;

    public PanelWindow(PanelController controller)
    {
        this.controller = controller;
        Hwnd = WindowNative.GetWindowHandle(target: this);
        Title = "BriefBar";
        var presenter = OverlappedPresenter.Create();
        presenter.SetBorderAndTitleBar(hasBorder: true, hasTitleBar: false);
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        AppWindow.SetPresenter(appWindowPresenter: presenter);
        AppWindow.IsShownInSwitchers = false;
        if (!Dwm.TrySet(hWnd: Hwnd, attribute: DwmAttributes.DWMWA_WINDOW_CORNER_PREFERENCE, value: DwmAttributes.DWMWCP_ROUND))
        {
            Log.Write(line: $"panel: Windows kept its corners square");
        }
        subclass = WindowProc;
        ComCtl32.SetWindowSubclass(hWnd: Hwnd, callback: subclass, id: 1, data: 0);
        WindowMenu.Remove(hwnd: Hwnd);
        mouseCallback = OnMouse;
        view = new PanelView(viewModel: ViewModel);
        view.EscapePressed += (_, _) => controller.Dismiss();
        view.QuitRequested += (_, _) => controller.QuitRequested();
        Content = view;
        SystemBackdrop = new ActiveAcrylic(kind: DesktopAcrylicKind.Base);
        Activated += OnActivated;
        // Alt+F4 hides it, as Esc does; only quitting closes it.
        AppWindow.Closing += (_, args) =>
        {
            if (!closingForGood)
            {
                args.Cancel = true;
                controller.Dismiss();
            }
        };
        // WinUI says when a window closes, but not when Windows destroys it, as it does an owned window with its owner.
        Closed += (_, _) => Gone();
        AppWindow.Destroying += (_, _) => Gone();
    }

    /// Its window is gone, closed or destroyed, and it can't show again.
    public event EventHandler? WindowGone;

    public nint Hwnd { get; }

    public PanelViewModel ViewModel { get; } = new();

    public bool IsShown => User32.IsWindowVisible(hWnd: Hwnd);

    /// How tall its content is `width` device-independent pixels wide, as tall as `maxHeight` at most.
    public double ContentHeight(double width, double maxHeight) => view.ContentHeight(width: width, maxHeight: maxHeight);

    /// Shows it at `rect`, in physical pixels, above the bar `owner`, at its top, and brings it to the front. `Settle`
    /// puts the keyboard on it once it's laid out.
    public void ShowAt(PixelRect rect, nint owner)
    {
        // Owned by the bar: above it, and without a taskbar button of its own.
        User32.SetWindowLongPtr(hWnd: Hwnd, index: WindowStyles.GWLP_HWNDPARENT, value: owner);
        MoveTo(rect: rect);
        wasActive = false;
        showing++;
        view.ScrollToTop();
        Activate();
        var inFront = Foreground.Bring(hwnd: Hwnd);
        WatchClicks();
        Log.Write(line: $"panel: shown at {rect}, in front {inFront}");
    }

    /// Once it's laid out on screen: at its top, with the keyboard on its first row, so arrows and Esc work at once.
    public void Settle()
    {
        view.ScrollToTop();
        view.FocusFirst();
    }

    /// Moves and sizes it to `rect`, in physical pixels.
    public void MoveTo(PixelRect rect)
    {
        // Moving first lets the window take on the display's scaling before it's sized for it.
        AppWindow.Move(position: new PointInt32(_X: rect.Left, _Y: rect.Top));
        AppWindow.ResizeClient(size: new SizeInt32(_Width: rect.Width, _Height: rect.Height));
        AppWindow.Move(position: new PointInt32(_X: rect.Left, _Y: rect.Top));
    }

    public void HideWindow()
    {
        StopWatchingClicks();
        AppWindow.Hide();
        // Owned by no bar while hidden: Windows destroys owned windows with their owner, as when a bar closes because
        // displays changed.
        User32.SetWindowLongPtr(hWnd: Hwnd, index: WindowStyles.GWLP_HWNDPARENT, value: 0);
    }

    /// Closes it for good, as BriefBar quits.
    public void CloseForGood()
    {
        closingForGood = true;
        StopWatchingClicks();
        ComCtl32.RemoveWindowSubclass(hWnd: Hwnd, callback: subclass, id: 1);
        Close();
    }

    void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState != WindowActivationState.Deactivated)
        {
            wasActive = true;
            return;
        }
        if (!wasActive || !IsShown)
        {
            return;
        }
        var next = successor != 0 ? successor : User32.GetForegroundWindow();
        if (Foreground.IsOurs(hwnd: next))
        {
            // A press on a bar moves focus there before the press reaches its item, which then decides: the same item
            // closes the panel, another opens its own. So that isn't you going elsewhere. Unless the press closed the
            // panel by then, it takes focus back, for Esc.
            var shown = showing;
            DispatcherQueue.TryEnqueue(priority: DispatcherQueuePriority.Low, callback: () =>
            {
                if (IsShown && shown == showing)
                {
                    Foreground.Bring(hwnd: Hwnd);
                }
            });
            return;
        }
        controller.Dismiss();
    }

    nint WindowProc(nint hWnd, uint message, nint wParam, nint lParam, nuint id, nuint data)
    {
        switch (message)
        {
            case WindowMessages.WM_ACTIVATE:
                // Losing activation names the window that takes it.
                successor = (wParam & 0xFFFF) == 0 ? lParam : 0;
                break;
            case WindowMessages.WM_STYLECHANGING:
                return WindowMenu.OnStyleChanging(hWnd: hWnd, wParam: wParam, lParam: lParam);
            case WindowMessages.WM_NCDESTROY:
                ComCtl32.RemoveWindowSubclass(hWnd: hWnd, callback: subclass, id: 1);
                break;
            default:
                break;
        }
        return ComCtl32.DefSubclassProc(hWnd: hWnd, message: message, wParam: wParam, lParam: lParam);
    }

    /// However its window went, it stops watching clicks, and says so, once.
    void Gone()
    {
        if (gone)
        {
            return;
        }
        gone = true;
        StopWatchingClicks();
        WindowGone?.Invoke(sender: this, e: EventArgs.Empty);
    }

    /// Closes it on a click on anything but BriefBar's own windows, even when Windows didn't let it become the active
    /// window, as with a full-screen game in front.
    void WatchClicks()
    {
        if (mouseHook != 0)
        {
            return;
        }
        mouseHook = User32.SetWindowsHookEx(
            kind: WinEvents.WH_MOUSE_LL, callback: mouseCallback, module: Kernel32.GetModuleHandle(moduleName: null), threadId: 0);
        if (mouseHook == 0)
        {
            Log.Write(line: $"panel: can't watch for clicks elsewhere, error {Marshal.GetLastPInvokeError()}");
        }
    }

    void StopWatchingClicks()
    {
        if (mouseHook == 0)
        {
            return;
        }
        User32.UnhookWindowsHookEx(hook: mouseHook);
        mouseHook = 0;
    }

    nint OnMouse(int code, nint message, nint data)
    {
        if (code >= 0 && (uint)message is WindowMessages.WM_LBUTTONDOWN or WindowMessages.WM_RBUTTONDOWN or WindowMessages.WM_MBUTTONDOWN)
        {
            // The hook's data starts with the point, in physical pixels.
            var point = Marshal.PtrToStructure<Win32Point>(ptr: data);
            if (!Foreground.IsOurs(hwnd: User32.WindowFromPoint(point: point)))
            {
                var shown = showing;
                DispatcherQueue.TryEnqueue(callback: () =>
                {
                    if (shown == showing)
                    {
                        controller.Dismiss();
                    }
                });
            }
        }
        return User32.CallNextHookEx(hook: mouseHook, code: code, message: message, data: data);
    }
}
