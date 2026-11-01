using System.Runtime.InteropServices;
using BriefBar.Interop;

namespace BriefBar.Shell;

/// Keeps a window without its window menu, the one Alt+Space opens, which Narrator lists as "System" and which could
/// move or close a bar. WinUI's presenter puts it back whenever it sets the window's styles, so it's taken off again
/// after WinUI's turn.
internal static class WindowMenu
{
    /// Takes the menu off `hwnd` now.
    public static void Remove(nint hwnd)
    {
        var style = User32.GetWindowLongPtr(hWnd: hwnd, index: WindowStyles.GWL_STYLE).ToInt64();
        User32.SetWindowLongPtr(hWnd: hwnd, index: WindowStyles.GWL_STYLE, value: (nint)(style & ~WindowStyles.WS_SYSMENU));
    }

    /// Handles a subclass's `WM_STYLECHANGING`: lets WinUI set the styles, then takes the menu off them.
    public static nint OnStyleChanging(nint hWnd, nint wParam, nint lParam)
    {
        var result = ComCtl32.DefSubclassProc(hWnd: hWnd, message: WindowMessages.WM_STYLECHANGING, wParam: wParam, lParam: lParam);
        if ((int)wParam == WindowStyles.GWL_STYLE)
        {
            var change = Marshal.PtrToStructure<StyleStruct>(ptr: lParam);
            change.styleNew &= ~(uint)WindowStyles.WS_SYSMENU;
            Marshal.StructureToPtr(structure: change, ptr: lParam, fDeleteOld: false);
        }
        return result;
    }
}
