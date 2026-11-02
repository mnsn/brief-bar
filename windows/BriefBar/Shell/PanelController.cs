using BriefBar.Core;
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
        var action = toggle.Press(target: target, bar: bar.Hwnd, open: openHere, now: Environment.TickCount64);
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
        panel.ViewModel.FoldAll();
        panel.ViewModel.Update(target: target, snapshots: shell.Snapshots(), palette: shell.Palette, now: DateTimeOffset.Now, isDemo: shell.IsDemo);
        anchor = itemAnchor;
        shownAt = PlaceUnder(bar: bar, panel: panel);
        var previous = OpenTarget;
        OpenTarget = target;
        Owner = bar;
        shell.ShowOpen(owner: bar, target: target);
        shell.PanelChanged(previous: previous, current: target);
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
        var owner = Owner;
        OpenTarget = null;
        Owner = null;
        window?.HideWindow();
        toggle.Closed(target: target, bar: owner?.Hwnd ?? 0, reason: reason, now: Environment.TickCount64);
        shell.ShowOpen(owner: null, target: null);
        shell.PanelChanged(previous: target, current: null);
        Log.Write(line: $"panel: {target} closed, {reason}");
    }

    /// Ctrl and `number`, pressed in the panel: shows what that key opens in the bar it's under (`PanelKeys`), in place.
    public void ShowNumbered(int number)
    {
        if (OpenTarget is null || Owner is not { } bar)
        {
            return;
        }
        if (PanelKeys.Numbered(targets: bar.ViewModel.Targets(), number: number) is { } target)
        {
            SwitchTo(bar: bar, target: target);
        }
    }

    /// Ctrl+Tab, pressed in the panel, or Ctrl+Shift+Tab for `backward`: shows the next item in the bar it's under, or
    /// the one before, around.
    public void ShowNext(bool backward)
    {
        if (OpenTarget is not { } open || Owner is not { } bar)
        {
            return;
        }
        if (PanelKeys.Next(targets: bar.ViewModel.Targets(), current: open, backward: backward) is { } target)
        {
            SwitchTo(bar: bar, target: target);
        }
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

    /// Does what the panel asked: something that opens elsewhere closes the panel first, as on the Mac, so the app it
    /// opens comes to the front over it.
    public void Perform(CommandRequest request, bool opens)
    {
        if (opens)
        {
            Dismiss(reason: PanelCloseReason.Opened);
        }
        shell.Perform(request: request);
    }

    /// Opens Settings, at `source`'s page or at General, in place of the panel.
    public void OpenSettings(SourceId? source)
    {
        Dismiss(reason: PanelCloseReason.Opened);
        shell.OpenSettings(source: source);
    }

    /// Whether going to `hwnd`, with a click or as it comes to the front, leaves the panel open: a bar, which a press on
    /// its item goes through, or the panel itself, and their menus. Settings is somewhere else, as another app is.
    public bool KeepsOpenFor(nint hwnd) => Foreground.IsOurs(hwnd: hwnd) && !shell.IsSettings(hwnd: hwnd);

    /// Fits it again, once what it shows has changed on screen, as a group folds.
    public void Refit()
    {
        if (window is not { } panel)
        {
            return;
        }
        panel.DispatcherQueue.TryEnqueue(priority: DispatcherQueuePriority.Low, callback: Fit);
    }

    /// Closes it for good, as BriefBar quits: closed first, then its window.
    public void Shutdown()
    {
        Dismiss(reason: PanelCloseReason.Quitting);
        var closing = window;
        window = null;
        closing?.CloseForGood();
    }

    /// Shows `target` under its item in `bar`, from the keyboard, unless it's showing already.
    void SwitchTo(BarWindow bar, PanelTarget target)
    {
        if (target == OpenTarget)
        {
            return;
        }
        Log.Write(line: $"panel: key for {target}");
        Show(bar: bar, target: target, itemAnchor: bar.AnchorOf(target: target));
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
        if (OpenTarget is { } target)
        {
            OpenTarget = null;
            Owner = null;
            shell.ShowOpen(owner: null, target: null);
            shell.PanelChanged(previous: target, current: null);
        }
    }
}
