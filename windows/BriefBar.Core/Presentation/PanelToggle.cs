namespace BriefBar.Core.Presentation;

/// Decides what a press on an item in the bar does, as the prototype learned on Windows 11:
/// a press that makes the bar the active window can arrive twice, about 130 ms apart, and the second would close the
/// panel the first opened; and a press can move focus from an open panel before it reaches its item, closing the panel
/// that the press itself means to close. Times are milliseconds on a clock that only goes forward.
public sealed class PanelToggle
{
    /// A second press on the same item this soon is the same press.
    public const long RepeatedPressMilliseconds = 350;

    /// A panel that closed this soon before a press on its item closed because of that press.
    public const long JustClosedMilliseconds = 600;

    PanelTarget? lastPress;
    long lastPressAt;
    PanelTarget? lastClosed;
    long lastClosedAt;

    /// What a press on `target`'s item at `now` does, with `open` showing under that item's bar now, or null for none:
    /// a panel open under another display's bar doesn't count, so the same item there opens it here.
    public PanelToggleAction Press(PanelTarget target, PanelTarget? open, long now)
    {
        var isRepeat = lastPress == target && now - lastPressAt < RepeatedPressMilliseconds;
        lastPress = target;
        lastPressAt = now;
        if (isRepeat)
        {
            return PanelToggleAction.Ignore;
        }
        if (open == target)
        {
            return PanelToggleAction.Close;
        }
        if (lastClosed == target && now - lastClosedAt < JustClosedMilliseconds)
        {
            return PanelToggleAction.Ignore;
        }
        return PanelToggleAction.Open;
    }

    /// The panel showing `target` closed at `now`, however it closed.
    public void Closed(PanelTarget target, long now)
    {
        lastClosed = target;
        lastClosedAt = now;
    }
}
