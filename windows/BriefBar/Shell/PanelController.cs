using BriefBar.Core.Logging;
using BriefBar.Core.Presentation;
using Microsoft.UI.Dispatching;

namespace BriefBar.Shell;

/// The one panel, shared by every bar: what a press on an item does to it (`PanelToggle`), what it shows, where it
/// opens and how tall it is, and closing it. Only one panel shows at a time, across displays.
internal sealed class PanelController(AppShell shell)
{
    readonly PanelToggle toggle = new();
    PanelWindow? window;
    /// The item it opened under, and where it is now, for fitting it to what it shows.
    PixelRect anchor;
    PixelRect shownAt;
    /// How many times it opened, so that settling one opening doesn't touch the next.
    int openings;

    /// What it shows, or null while it's closed.
    public PanelTarget? OpenTarget { get; private set; }

    /// The bar it opened from.
    public BarWindow? Owner { get; private set; }

    public void Press(BarWindow bar, PanelTarget target, PixelRect itemAnchor)
    {
        // Only a panel open under this bar counts: the same item on another display opens the panel there.
        var openHere = Owner == bar ? OpenTarget : null;
        var action = toggle.Press(target: target, open: openHere, now: Environment.TickCount64);
        Log.Write(line: $"panel: press on {target}, {action}");
        switch (action)
        {
            case PanelToggleAction.Open:
                Show(bar: bar, target: target, itemAnchor: itemAnchor);
                break;
            case PanelToggleAction.Close:
                Dismiss(reason: PanelCloseReason.PressedAgain);
                break;
            case PanelToggleAction.Ignore:
                break;
            default:
                throw new InvalidOperationException(message: "A press did something unknown.");
        }
    }

    /// Opens `target`'s panel under `itemAnchor`, an item on `bar`, in place of any other.
    public void Show(BarWindow bar, PanelTarget target, PixelRect itemAnchor)
    {
        var panel = window ??= CreateWindow();
        panel.ViewModel.Update(target: target, snapshots: shell.Snapshots(), palette: shell.Palette, now: DateTimeOffset.Now, isDemo: shell.IsDemo);
        anchor = itemAnchor;
        shownAt = PlaceUnder(bar: bar, panel: panel);
        OpenTarget = target;
        Owner = bar;
        shell.ShowOpen(owner: bar, target: target);
        panel.ShowAt(rect: shownAt, owner: bar.Hwnd);
        // Once it's laid out on screen, its rows may wrap differently than measured: it's fitted again, then settled.
        var opening = ++openings;
        panel.DispatcherQueue.TryEnqueue(priority: DispatcherQueuePriority.Low, callback: () =>
        {
            if (opening != openings || OpenTarget is null)
            {
                return;
            }
            Fit();
            panel.Settle();
        });
    }

    /// Closes it, for `reason`, which the log says.
    public void Dismiss(PanelCloseReason reason)
    {
        if (OpenTarget is not { } target)
        {
            return;
        }
        OpenTarget = null;
        Owner = null;
        window?.HideWindow();
        toggle.Closed(target: target, reason: reason, now: Environment.TickCount64);
        shell.ShowOpen(owner: null, target: null);
        Log.Write(line: $"panel: {target} closed, {reason}");
    }

    /// Shows what the sources show now, in place, if it's open, as tall as that needs.
    public void Refresh(DateTimeOffset now)
    {
        if (OpenTarget is not { } target || window is not { } panel)
        {
            return;
        }
        panel.ViewModel.Update(target: target, snapshots: shell.Snapshots(), palette: shell.Palette, now: now, isDemo: shell.IsDemo);
        Fit();
    }

    public void QuitRequested() => shell.Quit();

    /// Closes it for good, as BriefBar quits: closed first, then its window.
    public void Shutdown()
    {
        Dismiss(reason: PanelCloseReason.Quitting);
        var closing = window;
        window = null;
        closing?.CloseForGood();
    }

    /// Makes the open panel as tall as what it shows, as far as the display allows.
    void Fit()
    {
        if (OpenTarget is null || Owner is not { } bar || window is not { } panel)
        {
            return;
        }
        var rect = PlaceUnder(bar: bar, panel: panel);
        if (rect != shownAt)
        {
            Log.Write(line: $"panel: fitted from {shownAt} to {rect}");
            shownAt = rect;
            panel.MoveTo(rect: rect);
        }
    }

    /// Where the panel goes under its item on `bar`, for what it shows now, in the display's work area as it is now.
    PixelRect PlaceUnder(BarWindow bar, PanelWindow panel)
    {
        var display = Displays.Of(monitor: bar.Display.Handle) ?? bar.Display;
        return PanelPlacement.Place(
            workArea: display.Work,
            bar: bar.Rect,
            anchor: anchor,
            edge: BarEdge.Top,
            contentHeightDip: panel.ContentHeight(width: PanelPlacement.WidthDip, maxHeight: PanelPlacement.MaxHeightDip),
            scale: display.Scale);
    }

    PanelWindow CreateWindow()
    {
        var created = new PanelWindow(controller: this);
        created.WindowGone += (_, _) => Forget(gone: created);
        return created;
    }

    /// Its window went, closed or destroyed, other than as BriefBar quits: the panel is closed, and the next one gets a
    /// new window.
    void Forget(PanelWindow gone)
    {
        if (window != gone)
        {
            return;
        }
        window = null;
        Log.Write(line: $"panel: its window is gone");
        if (OpenTarget is not null)
        {
            OpenTarget = null;
            Owner = null;
            shell.ShowOpen(owner: null, target: null);
        }
    }
}
