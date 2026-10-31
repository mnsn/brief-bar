using System.Runtime.InteropServices;
using BriefBar.Core;
using BriefBar.Core.Copilot;
using BriefBar.Core.Logging;
using BriefBar.Interop;
using BriefBar.Shell;
using Microsoft.Win32;
using Windows.System;

namespace BriefBar.Services;

/// The GitHub Copilot app, as Windows knows it, for `CopilotSource`: the app registers `ghapp:` links, as it does on the
/// Mac, and a session's link opens it there. Whether it's installed, and in front, goes by the program Windows opens
/// those links with. The Mac's `CopilotApp`, the half that asks the system.
internal static class CopilotAppShell
{
    const string Scheme = "ghapp";

    public static CopilotAppAccess Access { get; } = new(
        OpenSession: id => Launch(link: CopilotApp.SessionLink(id: id)),
        Activate: Activate,
        IsInstalled: () => Program() is not null,
        IsFrontmost: IsFrontmost);

    /// The program that opens `ghapp:` links, while it's there: the Copilot app's.
    static string? Program()
    {
        using var scheme = Registry.ClassesRoot.OpenSubKey(name: Scheme);
        if (scheme?.GetValue(name: "URL Protocol") is null)
        {
            return null;
        }
        using var command = scheme.OpenSubKey(name: @"shell\open\command");
        var program = ShellCommand.Program(command: command?.GetValue(name: null) as string);
        return program is not null && File.Exists(path: program) ? program : null;
    }

    static bool IsFrontmost()
    {
        var program = Program();
        if (program is null)
        {
            return false;
        }
        var front = User32.GetForegroundWindow();
        return front != 0 && IsOf(window: front, program: program);
    }

    /// Brings the app's window to the front, as the Mac opens the app, without changing what it shows. When it shows no
    /// window, as when it isn't running, its link starts it, or shows it, at its start page.
    static void Activate()
    {
        var program = Program();
        var window = program is null ? 0 : MainWindow(program: program);
        if (window == 0)
        {
            Launch(link: new Uri(uriString: Scheme + "://"));
            return;
        }
        if (User32.IsIconic(hWnd: window))
        {
            User32.ShowWindow(hWnd: window, command: WindowStyles.SW_RESTORE);
        }
        if (!Foreground.Bring(hwnd: window))
        {
            Log.Write(line: $"copilot: Windows didn't bring the Copilot app's window to the front");
        }
    }

    /// The app's frontmost window that's on screen and its own, not a dialog's.
    static nint MainWindow(string program)
    {
        nint found = 0;
        User32.EnumWindows(
            callback: (window, _) =>
            {
                if (User32.IsWindowVisible(hWnd: window)
                    && User32.GetWindow(hWnd: window, command: WindowStyles.GW_OWNER) == 0
                    && User32.GetWindowTextLength(hWnd: window) > 0
                    && IsOf(window: window, program: program))
                {
                    found = window;
                    return false;
                }
                return true;
            },
            data: 0);
        return found;
    }

    static bool IsOf(nint window, string program)
    {
        var thread = User32.GetWindowThreadProcessId(hWnd: window, processId: out var processId);
        return thread != 0
            && Kernel32.ProgramPath(processId: processId) is { } path
            && string.Equals(a: path, b: program, comparisonType: StringComparison.OrdinalIgnoreCase);
    }

    /// Opens `link` in the Copilot app. A link Windows can't open is logged, without the link.
    static void Launch(Uri link) => _ = LaunchAsync(link: link);

    static async Task LaunchAsync(Uri link)
    {
        try
        {
            if (!await Launcher.LaunchUriAsync(uri: link))
            {
                Log.Write(line: $"copilot: Windows didn't open the Copilot app's link");
            }
        }
        catch (COMException error)
        {
            Log.Write(error: error, context: $"copilot: Windows couldn't open the Copilot app's link");
        }
        catch (UnauthorizedAccessException error)
        {
            Log.Write(error: error, context: $"copilot: Windows couldn't open the Copilot app's link");
        }
    }
}
