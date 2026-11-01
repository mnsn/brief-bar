namespace BriefBar.Interop;

/// The window messages BriefBar handles.
internal static class WindowMessages
{
    public const uint WM_ACTIVATE = 0x0006;
    public const uint WM_ENDSESSION = 0x0016;
    public const uint WM_SETTINGCHANGE = 0x001A;
    public const uint WM_MOUSEACTIVATE = 0x0021;
    public const uint WM_GETMINMAXINFO = 0x0024;
    public const uint WM_WINDOWPOSCHANGED = 0x0047;
    public const uint WM_STYLECHANGING = 0x007C;
    public const uint WM_DISPLAYCHANGE = 0x007E;
    public const uint WM_NCDESTROY = 0x0082;
    public const uint WM_NCCALCSIZE = 0x0083;
    public const uint WM_SYSCOMMAND = 0x0112;
    public const uint WM_POWERBROADCAST = 0x0218;
    public const uint WM_DPICHANGED = 0x02E0;
    public const uint WM_APP = 0x8000;
    public const uint WM_LBUTTONDOWN = 0x0201;
    public const uint WM_RBUTTONDOWN = 0x0204;
    public const uint WM_MBUTTONDOWN = 0x0207;

    /// `WM_MOUSEACTIVATE`'s answer: don't activate the window for the click.
    public const int MA_NOACTIVATE = 3;

    /// `WM_POWERBROADCAST`'s: the computer woke up.
    public const int PBT_APMRESUMEAUTOMATIC = 0x0012;

    /// `WM_SETTINGCHANGE`'s: the work area changed, as when a display or a docked bar comes or goes.
    public const int SPI_SETWORKAREA = 0x002F;

    /// `WM_SYSCOMMAND`'s: close the window, as Alt+F4 asks. Its low four bits are Windows' own.
    public const int SC_CLOSE = 0xF060;
    public const int SC_MASK = 0xFFF0;
}
