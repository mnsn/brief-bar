using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// kernel32.dll: for hooks, the module and thread they belong to; and which program a window belongs to.
internal static class Kernel32
{
    /// Enough to ask a process its program's path.
    public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

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
