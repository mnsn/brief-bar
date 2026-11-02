using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// CoreMessaging.dll: a Windows.System dispatcher queue, which Windows' own compositor needs, on a thread with only
/// WinUI's.
internal static class CoreMessaging
{
    [DllImport("CoreMessaging.dll")]
    public static extern int CreateDispatcherQueueController(DispatcherQueueOptions options, out nint dispatcherQueueController);
}
