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

    /// The displays changed, and the bars were made again.
    DisplaysChanged,

    /// BriefBar is quitting.
    Quitting,
}
