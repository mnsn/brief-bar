using BriefBar.Interop;

namespace BriefBar.Shell;

/// Bringing BriefBar's windows to the front.
internal static class Foreground
{
    /// Brings `hwnd` to the front, even while another app holds it, as a full-screen game on another display does: a
    /// window may come forward when its app received the last input, as a press on the bar is; when Windows refuses,
    /// it attaches to the front window's input for a moment, unless that window isn't responding, which could hang
    /// BriefBar too.
    public static bool Bring(nint hwnd)
    {
        var front = User32.GetForegroundWindow();
        if (front == hwnd)
        {
            return true;
        }
        if (User32.SetForegroundWindow(hWnd: hwnd) && User32.GetForegroundWindow() == hwnd)
        {
            return true;
        }
        if (front == 0 || User32.IsHungAppWindow(hWnd: front))
        {
            return false;
        }
        var frontThread = User32.GetWindowThreadProcessId(hWnd: front, processId: out _);
        var ours = Kernel32.GetCurrentThreadId();
        var attached = frontThread != 0 && frontThread != ours
            && User32.AttachThreadInput(attach: ours, attachTo: frontThread, doAttach: true);
        try
        {
            User32.SetForegroundWindow(hWnd: hwnd);
            User32.BringWindowToTop(hWnd: hwnd);
        }
        finally
        {
            if (attached)
            {
                User32.AttachThreadInput(attach: ours, attachTo: frontThread, doAttach: false);
            }
        }
        return User32.GetForegroundWindow() == hwnd;
    }

    /// Whether `hwnd` belongs to this process.
    public static bool IsOurs(nint hwnd)
    {
        if (hwnd == 0)
        {
            return false;
        }
        var thread = User32.GetWindowThreadProcessId(hWnd: hwnd, processId: out var owner);
        return thread != 0 && owner == (uint)Environment.ProcessId;
    }
}
