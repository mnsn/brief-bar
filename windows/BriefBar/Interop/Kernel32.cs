using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// kernel32.dll: for hooks, the module and thread they belong to.
internal static class Kernel32
{
    [DllImport("kernel32.dll", EntryPoint = "GetModuleHandleW", CharSet = CharSet.Unicode)]
    public static extern nint GetModuleHandle(string? moduleName);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();
}
