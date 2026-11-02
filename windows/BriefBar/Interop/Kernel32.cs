using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// kernel32.dll: for hooks, the module and thread they belong to; which program a window belongs to; for a moment,
/// another program's console, to find the terminal it's in; and freeing what Windows returns.
internal static class Kernel32
{
    /// Enough to ask a process its program's path.
    public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

    /// The kinds of console events a handler can take for its process: Ctrl+C and Ctrl+Break.
    public const uint CTRL_C_EVENT = 0;
    public const uint CTRL_BREAK_EVENT = 1;

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AttachConsole(uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FreeConsole();

    [DllImport("kernel32.dll")]
    public static extern nint GetConsoleWindow();

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetConsoleCtrlHandler(ConsoleCtrlHandler? handler, [MarshalAs(UnmanagedType.Bool)] bool add);

    [DllImport("kernel32.dll", EntryPoint = "GetModuleHandleW", CharSet = CharSet.Unicode)]
    public static extern nint GetModuleHandle(string? moduleName);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern nint OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool QueryFullProcessImageName(nint process, uint flags, [Out] char[] name, ref uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseHandle(nint handle);

    /// Frees what Windows allocated for a caller, such as what crypt32.dll returns.
    [DllImport("kernel32.dll")]
    public static extern nint LocalFree(nint memory);

    /// The path of the program the process `processId` runs, or null when Windows won't say, as for a process that's
    /// gone or runs as another user.
    public static string? ProgramPath(uint processId)
    {
        var process = OpenProcess(access: PROCESS_QUERY_LIMITED_INFORMATION, inheritHandle: false, processId: processId);
        if (process == 0)
        {
            return null;
        }
        try
        {
            var name = new char[1024];
            var size = (uint)name.Length;
            return QueryFullProcessImageName(process: process, flags: 0, name: name, size: ref size)
                ? new string(value: name, startIndex: 0, length: (int)size)
                : null;
        }
        finally
        {
            CloseHandle(handle: process);
        }
    }
}
