using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// comctl32.dll: window subclassing, to handle messages WinUI doesn't pass on; and Windows' task dialog, from Common
/// Controls 6, which the app's manifest asks for.
internal static class ComCtl32
{
    /// A task dialog's OK button.
    public const int TDCBF_OK_BUTTON = 0x0001;

    /// A task dialog's information icon, `MAKEINTRESOURCE(-3)`.
    public const nint TD_INFORMATION_ICON = 0xFFFD;

    [DllImport("comctl32.dll", CharSet = CharSet.Unicode)]
    public static extern int TaskDialog(
        nint owner, nint instance, string title, string mainInstruction, string content, int buttons, nint icon, out int button);

    [DllImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetWindowSubclass(nint hWnd, SubclassProc callback, nuint id, nuint data);

    [DllImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool RemoveWindowSubclass(nint hWnd, SubclassProc callback, nuint id);

    [DllImport("comctl32.dll")]
    public static extern nint DefSubclassProc(nint hWnd, uint message, nint wParam, nint lParam);
}
