using BriefBar.Core.Copilot;
using BriefBar.Core.Logging;
using BriefBar.Interop;
using BriefBar.Shell;
using Microsoft.UI.Dispatching;

namespace BriefBar.Services;

/// What Windows does for `CLISession`, on a PC without the GitHub Copilot app: it brings up the terminal a Copilot CLI
/// runs in, found through its console, and tells you what went wrong, in Windows' own dialog. On the UI thread, whichever
/// thread asks. The Mac's `CLISession.bringUp` and `CLISession.alert`.
internal static class CopilotCLIShell
{
    /// A pseudo console's own window: a stand-in, owned by the terminal that shows the console, such as Windows Terminal.
    const string PseudoConsoleClass = "PseudoConsoleWindow";

    /// Takes Ctrl+C and Ctrl+Break in a console BriefBar attaches to for a moment, which would otherwise end it. Kept here,
    /// so that it lives as long as Windows may call it.
    static readonly ConsoleCtrlHandler ignoreBreaks = kind => kind is Kernel32.CTRL_C_EVENT or Kernel32.CTRL_BREAK_EVENT;

    /// What `CLISession` asks of Windows, done on `queue`'s thread, the UI thread.
    public static CLISessionShell Make(DispatcherQueue queue)
    {
        ArgumentNullException.ThrowIfNull(argument: queue);
        return new CLISessionShell(
            ShowTerminalOf: processId => Post(queue: queue, work: () => BringUp(processId: processId)),
            Say: (message, information) => Post(queue: queue, work: () => Tell(message: message, information: information)));
    }

    static void Post(DispatcherQueue queue, DispatcherQueueHandler work)
    {
        if (!queue.TryEnqueue(callback: work))
        {
            Log.Write(line: $"copilot: BriefBar is quitting, so it didn't bring up a session's terminal or say why it couldn't");
        }
    }

    /// Brings up the terminal that the process `processId` runs in, restored if it's minimized; where BriefBar can't tell
    /// which that is, as in an editor's terminal, it says so, as the Mac does for tmux.
    static void BringUp(int processId)
    {
        var terminal = TerminalOf(processId: (uint)processId);
        if (terminal == 0)
        {
            Tell(
                message: "The session is open in another terminal",
                information: "The Copilot CLI has it open where BriefBar can't bring it up, such as in an editor's terminal or over SSH. Go on with it there: opening it in a second terminal would fork its history.");
            return;
        }
        if (User32.IsIconic(hWnd: terminal))
        {
            User32.ShowWindow(hWnd: terminal, command: WindowStyles.SW_RESTORE);
        }
        if (!Foreground.Bring(hwnd: terminal))
        {
            Log.Write(line: $"copilot: Windows didn't bring a session's terminal to the front");
        }
    }

    /// The window of the terminal that the process `processId` runs in, through its console: the console's own window, or,
    /// for a pseudo console, the terminal's window that owns its stand-in. 0 when it has no console, as a program run in
    /// the background, or its stand-in belongs to no window, as in an editor's terminal. BriefBar has no console, and
    /// attaches to the process's only for as long as it takes to ask.
    static nint TerminalOf(uint processId)
    {
        nint console;
        Kernel32.SetConsoleCtrlHandler(handler: ignoreBreaks, add: true);
        try
        {
            if (!Kernel32.AttachConsole(processId: processId))
            {
                return 0;
            }
            try
            {
                console = Kernel32.GetConsoleWindow();
            }
            finally
            {
                Kernel32.FreeConsole();
            }
        }
        finally
        {
            Kernel32.SetConsoleCtrlHandler(handler: ignoreBreaks, add: false);
        }
        if (console == 0)
        {
            return 0;
        }
        var window = User32.GetAncestor(hWnd: console, flags: WindowStyles.GA_ROOTOWNER) is var owner and not 0 ? owner : console;
        if (window == console && User32.ClassName(hWnd: console) == PseudoConsoleClass)
        {
            return 0;
        }
        return User32.IsWindowVisible(hWnd: window) ? window : 0;
    }

    /// Tells you what went wrong in Windows' own dialog, as the Mac's alert does: what happened, then what to do.
    static void Tell(string message, string information)
    {
        var result = ComCtl32.TaskDialog(
            owner: 0,
            instance: 0,
            title: "BriefBar",
            mainInstruction: message,
            content: information,
            buttons: ComCtl32.TDCBF_OK_BUTTON,
            icon: ComCtl32.TD_INFORMATION_ICON,
            button: out _);
        if (result < 0)
        {
            Log.Write(line: $"copilot: Windows didn't show what went wrong with a session, HRESULT {result}");
        }
    }
}
