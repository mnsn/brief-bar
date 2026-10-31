namespace BriefBar.Interop;

/// `SHAppBarMessage`'s messages, edges and notifications:
/// https://learn.microsoft.com/windows/win32/shell/application-desktop-toolbars
internal static class AppBarMessages
{
    public const uint ABM_NEW = 0;
    public const uint ABM_REMOVE = 1;
    public const uint ABM_QUERYPOS = 2;
    public const uint ABM_SETPOS = 3;
    public const uint ABM_ACTIVATE = 6;
    public const uint ABM_WINDOWPOSCHANGED = 9;

    public const uint ABE_TOP = 1;
    public const uint ABE_BOTTOM = 3;

    public const int ABN_POSCHANGED = 1;
    public const int ABN_FULLSCREENAPP = 2;
}
