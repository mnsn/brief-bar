using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// shell32.dll: the application desktop toolbar API, which reserves the bar's space.
internal static class Shell32
{
    [DllImport("shell32.dll")]
    public static extern nuint SHAppBarMessage(uint message, ref AppBarData data);
}
