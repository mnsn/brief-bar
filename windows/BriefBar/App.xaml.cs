using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace BriefBar;

/// Puts a bar at the top of every display, keeps them out of the way of full-screen apps, and gives the space back
/// when it quits.
public partial class App : Application
{
    public static new App Current => (App)Application.Current;
    /// What Explorer broadcasts when it restarts, having forgotten every bar.
    public static readonly uint TaskbarCreated = Native.RegisterWindowMessage("TaskbarCreated");

    static readonly string[] desktopClasses = ["Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd"];

    readonly List<BarWindow> bars = [];
    /// Each display's full-screen window, which keeps its bar hidden until another window on that display comes forward.
    readonly Dictionary<IntPtr, IntPtr> fullScreen = [];
    readonly uint processId = (uint)Environment.ProcessId;
    Native.WinEventProc? winEvents;
    readonly List<IntPtr> hooks = [];
    DispatcherQueueTimer? timer, displaysTimer;
    Mutex? instance;
    EventWaitHandle? quitSignal;

    public App()
    {
        InitializeComponent();
        // Bars come and go with displays; the app quits only from its Quit button.
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        UnhandledException += (_, _) => RemoveBars();
        AppDomain.CurrentDomain.ProcessExit += (_, _) => RemoveBars();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        instance = new Mutex(true, "BriefBar.Windows", out bool first);
        if (!first)
        {
            Exit();
            return;
        }
        Log.Write($"started, pid {processId}");
        var queue = DispatcherQueue.GetForCurrentThread();
        // Lets a script quit it cleanly: quit.ps1 sets this event.
        quitSignal = new EventWaitHandle(false, EventResetMode.AutoReset, "BriefBar.Windows.Quit");
        ThreadPool.RegisterWaitForSingleObject(quitSignal, (_, _) => queue.TryEnqueue(Quit), null, Timeout.Infinite, true);
        CreateBars();

        winEvents = OnWinEvent;
        foreach (var kind in new[] { Native.EVENT_SYSTEM_FOREGROUND, Native.EVENT_OBJECT_LOCATIONCHANGE })
        {
            hooks.Add(Native.SetWinEventHook(kind, kind, IntPtr.Zero, winEvents, 0, 0,
                Native.WINEVENT_OUTOFCONTEXT | Native.WINEVENT_SKIPOWNPROCESS));
        }
        timer = queue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(1);
        timer.Tick += (_, _) => CheckFullScreen();
        timer.Start();
        displaysTimer = queue.CreateTimer();
        displaysTimer.Interval = TimeSpan.FromMilliseconds(800);
        displaysTimer.IsRepeating = false;
        displaysTimer.Tick += (_, _) => RecreateBars();
        CheckFullScreen();
    }

    void CreateBars()
    {
        foreach (var display in Display.All())
        {
            var bar = new BarWindow(display);
            bars.Add(bar);
            bar.Place();
        }
    }

    /// Displays were added, removed or rearranged: once they settle, a bar for each again.
    public void DisplaysChanged()
    {
        displaysTimer?.Stop();
        displaysTimer?.Start();
    }

    void RecreateBars()
    {
        foreach (var bar in bars) bar.Shutdown();
        bars.Clear();
        fullScreen.Clear();
        CreateBars();
        CheckFullScreen();
    }

    void OnWinEvent(IntPtr hook, uint kind, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        if (kind == Native.EVENT_SYSTEM_FOREGROUND)
        {
            // Another app came to the front, so a panel's no longer what you're looking at.
            DismissPanels();
            CheckFullScreen();
        }
        else if (idObject == 0 && idChild == 0 && hwnd == Native.GetForegroundWindow())
        {
            // The window in front changed size, such as a video going full screen.
            CheckFullScreen();
        }
    }

    /// Hides the bar on any display with a full-screen window, as the taskbar does.
    public void CheckFullScreen()
    {
        var front = Native.GetForegroundWindow();
        if (front != IntPtr.Zero && !IsOurs(front))
        {
            var monitor = Native.MonitorFromWindow(front, Native.MONITOR_DEFAULTTONEAREST);
            if (IsFullScreen(front, monitor)) fullScreen[monitor] = front;
            else fullScreen.Remove(monitor);
        }
        foreach (var (monitor, window) in fullScreen.ToList())
        {
            if (!IsFullScreen(window, monitor)) fullScreen.Remove(monitor);
        }
        foreach (var bar in bars) bar.SetHiddenForFullScreen(fullScreen.ContainsKey(bar.Display.Handle));
    }

    public bool IsOurs(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return false;
        Native.GetWindowThreadProcessId(hwnd, out var owner);
        return owner == processId;
    }

    internal void DismissPanels(BarWindow? except = null)
    {
        foreach (var bar in bars)
        {
            if (bar != except) bar.DismissPanel();
        }
    }

    static bool IsFullScreen(IntPtr hwnd, IntPtr monitor)
    {
        if (!Native.IsWindow(hwnd) || !Native.IsWindowVisible(hwnd) || Native.IsIconic(hwnd)) return false;
        if (Native.MonitorFromWindow(hwnd, Native.MONITOR_DEFAULTTONEAREST) != monitor) return false;
        if (Native.DwmGetWindowAttribute(hwnd, Native.DWMWA_CLOAKED, out int cloaked, sizeof(int)) == 0 && cloaked != 0) return false;
        if (desktopClasses.Contains(Native.ClassName(hwnd))) return false;
        return Display.Of(monitor) is { } display && Native.GetWindowRect(hwnd, out var rect) && rect.Covers(display.Bounds);
    }

    void RemoveBars()
    {
        foreach (var bar in bars)
        {
            try { bar.Shutdown(); } catch { }
        }
        bars.Clear();
    }

    public void Quit()
    {
        Log.Write("quitting");
        timer?.Stop();
        foreach (var hook in hooks) Native.UnhookWinEvent(hook);
        RemoveBars();
        instance?.ReleaseMutex();
        Exit();
    }
}
