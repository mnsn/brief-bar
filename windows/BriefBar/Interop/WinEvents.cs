namespace BriefBar.Interop;

/// The accessibility events and hooks BriefBar listens to.
internal static class WinEvents
{
    public const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    public const uint EVENT_SYSTEM_MINIMIZEEND = 0x0017;
    public const uint EVENT_OBJECT_LOCATIONCHANGE = 0x800B;

    public const uint WINEVENT_OUTOFCONTEXT = 0x0000;
    public const uint WINEVENT_SKIPOWNPROCESS = 0x0002;

    /// The window itself, rather than its caret, cursor or a part of it.
    public const int OBJID_WINDOW = 0;

    /// A low-level mouse hook.
    public const int WH_MOUSE_LL = 14;
}
