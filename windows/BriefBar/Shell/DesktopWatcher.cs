using BriefBar.Core.Logging;
using BriefBar.Core.Presentation;
using BriefBar.Interop;
using Microsoft.UI.Dispatching;

namespace BriefBar.Shell;

/// Follows the window in front: says when another app comes forward, which closes the panel, and keeps track of each
/// display's full-screen window, such as a game or a video, whose display's bar steps aside as the taskbar does, for as
/// long as that window stays full screen on that display, even while you work on another.
///
/// It listens only to the foreground changing, and to the window in front moving or resizing, by hooking that one
/// thread's location changes; not to every window's, which would wake BriefBar on every move of the mouse. While a
/// display has a full-screen window, it looks again every second, to see it go.
internal sealed class DesktopWatcher : IDisposable
{
    static readonly string[] desktopClasses = ["Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd"];

    readonly DispatcherQueue queue;
    readonly Dictionary<nint, nint> fullScreenByMonitor = [];
    readonly WinEventProc foregroundCallback;
    readonly WinEventProc locationCallback;
    readonly DispatcherQueueTimer recheck;
    readonly DispatcherQueueTimer settle;
    nint foregroundHook;
    nint locationHook;
    bool disposed;

    public DesktopWatcher(DispatcherQueue queue)
    {
        this.queue = queue;
        foregroundCallback = OnForeground;
        locationCallback = OnLocation;
        recheck = queue.CreateTimer();
        recheck.Interval = TimeSpan.FromSeconds(value: 1);
        recheck.Tick += (_, _) => Check();
        settle = queue.CreateTimer();
        settle.Interval = TimeSpan.FromMilliseconds(value: 100);
        settle.IsRepeating = false;
        settle.Tick += (_, _) => Check();
    }

    /// Another app's window came to the front.
    public event EventHandler? ForegroundChanged;

    /// Which displays have a full-screen window in front changed.
    public event EventHandler? FullScreenChanged;

    public void Start()
    {
        foregroundHook = User32.SetWinEventHook(
            eventMin: WinEvents.EVENT_SYSTEM_FOREGROUND,
            eventMax: WinEvents.EVENT_SYSTEM_FOREGROUND,
            module: 0,
            callback: foregroundCallback,
            processId: 0,
            threadId: 0,
            flags: WinEvents.WINEVENT_OUTOFCONTEXT | WinEvents.WINEVENT_SKIPOWNPROCESS);
        if (foregroundHook == 0)
        {
            Log.Write(line: $"desktop: couldn't follow the window in front; bars won't step aside for full screen");
        }
        WatchLocation(window: User32.GetForegroundWindow());
        Check();
    }

    /// Whether `monitor` has a full-screen window in front.
    public bool HasFullScreen(nint monitor) => fullScreenByMonitor.ContainsKey(key: monitor);

    /// Looks again at which displays have a full-screen window in front, as when Windows says one opened.
    public void Check()
    {
        if (disposed)
        {
            return;
        }
        var before = fullScreenByMonitor.Keys.ToHashSet();
        var front = User32.GetForegroundWindow();
        if (front != 0 && !Foreground.IsOurs(hwnd: front))
        {
            var monitor = User32.MonitorFromWindow(hWnd: front, flags: WindowStyles.MONITOR_DEFAULTTONEAREST);
            if (IsFullScreen(window: front, monitor: monitor))
            {
                fullScreenByMonitor[monitor] = front;
            }
            else
            {
                fullScreenByMonitor.Remove(key: monitor);
            }
        }
        foreach (var (monitor, window) in fullScreenByMonitor.ToList())
        {
            if (!IsFullScreen(window: window, monitor: monitor))
            {
                fullScreenByMonitor.Remove(key: monitor);
            }
        }
        if (fullScreenByMonitor.Count > 0)
        {
            recheck.Start();
        }
        else
        {
            recheck.Stop();
        }
        if (!before.SetEquals(other: fullScreenByMonitor.Keys))
        {
            Log.Write(line: $"desktop: {fullScreenByMonitor.Count} displays with a full-screen window in front");
            FullScreenChanged?.Invoke(sender: this, e: EventArgs.Empty);
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        recheck.Stop();
        settle.Stop();
        Unhook(hook: ref foregroundHook);
        Unhook(hook: ref locationHook);
    }

    void OnForeground(nint hook, uint eventKind, nint hWnd, int idObject, int idChild, uint thread, uint time)
    {
        if (disposed)
        {
            return;
        }
        WatchLocation(window: hWnd);
        ForegroundChanged?.Invoke(sender: this, e: EventArgs.Empty);
        Check();
    }

    void OnLocation(nint hook, uint eventKind, nint hWnd, int idObject, int idChild, uint thread, uint time)
    {
        // Only the window in front itself, such as a video going full screen; not its caret or cursor.
        if (disposed || idObject != WinEvents.OBJID_WINDOW || idChild != 0 || hWnd != User32.GetForegroundWindow())
        {
            return;
        }
        settle.Stop();
        settle.Start();
    }

    /// Follows `window`'s thread's windows moving and resizing, instead of the previous one's.
    void WatchLocation(nint window)
    {
        Unhook(hook: ref locationHook);
        if (window == 0 || Foreground.IsOurs(hwnd: window))
        {
            return;
        }
        var thread = User32.GetWindowThreadProcessId(hWnd: window, processId: out var process);
        if (thread == 0)
        {
            return;
        }
        locationHook = User32.SetWinEventHook(
            eventMin: WinEvents.EVENT_OBJECT_LOCATIONCHANGE,
            eventMax: WinEvents.EVENT_OBJECT_LOCATIONCHANGE,
            module: 0,
            callback: locationCallback,
            processId: process,
            threadId: thread,
            flags: WinEvents.WINEVENT_OUTOFCONTEXT);
    }

    static void Unhook(ref nint hook)
    {
        if (hook != 0)
        {
            User32.UnhookWinEvent(hook: hook);
            hook = 0;
        }
    }

    static bool IsFullScreen(nint window, nint monitor)
    {
        if (!User32.IsWindow(hWnd: window) || !User32.IsWindowVisible(hWnd: window) || User32.IsIconic(hWnd: window))
        {
            return false;
        }
        if (User32.MonitorFromWindow(hWnd: window, flags: WindowStyles.MONITOR_DEFAULTTONEAREST) != monitor)
        {
            return false;
        }
        if (Dwm.DwmGetWindowAttribute(hWnd: window, attribute: DwmAttributes.DWMWA_CLOAKED, value: out var cloaked, size: sizeof(int)) == 0
            && cloaked != 0)
        {
            return false;
        }
        if (desktopClasses.Contains(value: User32.ClassName(hWnd: window), comparer: StringComparer.Ordinal))
        {
            return false;
        }
        return Displays.Of(monitor: monitor) is { } display
            && User32.GetWindowRect(hWnd: window, rect: out var rect)
            && rect.ToPixelRect().Covers(other: display.Bounds);
    }
}
