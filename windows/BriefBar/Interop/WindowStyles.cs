namespace BriefBar.Interop;

/// Window styles, and how `SetWindowPos` and `ShowWindow` place and show windows.
internal static class WindowStyles
{
    public const int GWL_STYLE = -16;
    public const int GWL_EXSTYLE = -20;
    public const int GWLP_HWNDPARENT = -8;

    /// The window menu, which Narrator would otherwise list as "System" in BriefBar's windows.
    public const long WS_SYSMENU = 0x00080000;

    public const long WS_EX_NOACTIVATE = 0x08000000;
    public const long WS_EX_APPWINDOW = 0x00040000;

    public static readonly nint HWND_TOPMOST = -1;

    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_FRAMECHANGED = 0x0020;
    public const uint SWP_SHOWWINDOW = 0x0040;

    public const int SW_HIDE = 0;

    public const uint MONITOR_DEFAULTTONEAREST = 2;
}
