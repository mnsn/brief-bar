using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// comctl32.dll: window subclassing, to handle messages WinUI doesn't pass on.
internal static class ComCtl32
{
    [DllImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetWindowSubclass(nint hWnd, SubclassProc callback, nuint id, nuint data);

    [DllImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool RemoveWindowSubclass(nint hWnd, SubclassProc callback, nuint id);

    [DllImport("comctl32.dll")]
    public static extern nint DefSubclassProc(nint hWnd, uint message, nint wParam, nint lParam);
}
