namespace BriefBar.Core.Presentation;

/// Why a panel closed, for `PanelToggle` and the log.
public enum PanelCloseReason
{
    /// Its item was pressed again.
    PressedAgain,

    /// Esc, or Alt+F4.
    Keyboard,

    /// A press on the bar, between its items.
    EmptySpace,

    /// A click anywhere but BriefBar's windows.
    ClickElsewhere,

    /// Another app's window came to the front.
    OtherApp,

    /// A full-screen window came to the front on its display, and the bar stepped aside.
    FullScreen,

    /// The displays changed, and the bars were arranged again.
    DisplaysChanged,

    /// BriefBar is quitting.
    Quitting,

    /// Something in it opened what it's about, in another app or in Settings, which comes to the front.
    Opened,
}
