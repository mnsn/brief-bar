namespace BriefBar.Core.Presentation;

/// Decides what a press on an item in the bar does, as the prototype learned on Windows 11:
/// a press that makes the bar the active window can arrive twice, about 130 ms apart, and the second would close the
/// panel the first opened; and a press can move focus from an open panel before it reaches its item, closing the panel
/// that the press itself means to close. Both happen on the bar that was pressed, so a press on another display's bar
/// is always one of its own. Times are milliseconds on a clock that only goes forward; a bar is any number that tells
/// the bars apart.
public sealed class PanelToggle
{
    /// A second press on the same item of the same bar this soon is the same press.
    public const long RepeatedPressMilliseconds = 350;

    /// A panel that closed this soon before a press on its item, in the bar it was under, closed because of that press.
    public const long JustClosedMilliseconds = 600;

    (PanelTarget Target, nint Bar)? lastPress;
    long lastPressAt;
    (PanelTarget Target, nint Bar)? lastClosed;
    long lastClosedAt;

    /// What a press on `target`'s item in `bar` at `now` does, with `open` showing under that bar now, or null for none:
    /// a panel open under another display's bar doesn't count, so the same item there opens it here.
    public PanelToggleAction Press(PanelTarget target, nint bar, PanelTarget? open, long now)
    {
        var isRepeat = Matches(item: lastPress, target: target, bar: bar) && now - lastPressAt < RepeatedPressMilliseconds;
        lastPress = (target, bar);
        lastPressAt = now;
        if (isRepeat)
        {
            return PanelToggleAction.Ignore;
        }
        if (open == target)
        {
            return PanelToggleAction.Close;
        }
        if (Matches(item: lastClosed, target: target, bar: bar) && now - lastClosedAt < JustClosedMilliseconds)
        {
            return PanelToggleAction.Ignore;
        }
        return PanelToggleAction.Open;
    }

    /// The panel showing `target` under `bar` closed at `now`, for `reason`. Only a close that a press on its item could
    /// have caused itself, by moving focus from the panel or seeming to land elsewhere, makes a press on that item in
    /// that bar soon after do nothing.
    public void Closed(PanelTarget target, nint bar, PanelCloseReason reason, long now)
    {
        if (reason is not (PanelCloseReason.OtherApp or PanelCloseReason.ClickElsewhere))
        {
            return;
        }
        lastClosed = (target, bar);
        lastClosedAt = now;
    }

    static bool Matches((PanelTarget Target, nint Bar)? item, PanelTarget target, nint bar) =>
        item is { } known && known.Target == target && known.Bar == bar;
}
