using System.Diagnostics;
using BriefBar.Core;
using BriefBar.Core.Logging;
using BriefBar.Core.Presentation;
using BriefBar.Interop;
using BriefBar.Services;
using BriefBar.ViewModels;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Windows.UI.ViewManagement;

namespace BriefBar.Shell;

/// BriefBar on the desktop: a bar on every display, again whenever displays change; the one panel; what the sources
/// show, kept up to date on both; the theme; and quitting, which gives every bar's space back before anything closes.
/// No window closes before then: as displays change, bar windows are kept, moved or hidden (`BarArrangement`).
internal sealed class AppShell : IDisposable
{
    /// What Explorer broadcasts when it starts again, having forgotten every bar's space.
    public static readonly uint TaskbarCreated = User32.RegisterWindowMessage(message: "TaskbarCreated");

    readonly DispatcherQueue queue;
    readonly AppSources appSources;
    readonly SourceHost sources;
    readonly Action exit;
    /// A bar on each display, in the order of `Displays.All`.
    readonly List<BarWindow> bars = [];
    /// Bars that stepped aside as their display went: hidden, holding no space, for a display that comes back.
    readonly List<BarWindow> spares = [];
    readonly PanelController panel;
    readonly DesktopWatcher desktop;
    readonly DispatcherQueueTimer displaysSettle;
    readonly DispatcherQueueTimer ticker;
    readonly UISettings uiSettings = new();
    readonly AccessibilitySettings accessibility = new();
    /// Sources being turned on or off: quitting waits a while for them to start or stop. One turned off has deleted what
    /// it saved by then, as that doesn't wait for it to stop.
    readonly List<Task> switching = [];
    SettingsWindow? settings;
    bool quitting;

    public AppShell(DispatcherQueue queue, AppSources sources, bool isDemo, Action exit)
    {
        this.queue = queue;
        this.exit = exit;
        IsDemo = isDemo;
        appSources = sources;
        this.sources = new SourceHost(sources: sources.Initial(), queue: queue);
        panel = new PanelController(shell: this);
        desktop = new DesktopWatcher(queue: queue);
        displaysSettle = queue.CreateTimer();
        displaysSettle.Interval = TimeSpan.FromMilliseconds(value: 800);
        displaysSettle.IsRepeating = false;
        displaysSettle.Tick += (_, _) => DisplaysSettled();
        // Times such as "3m" and "Updated 20 s ago" move on by themselves.
        ticker = queue.CreateTimer();
        ticker.Interval = TimeSpan.FromSeconds(value: 15);
        ticker.Tick += (_, _) => Refresh();
        var theme = Application.Current.RequestedTheme == ApplicationTheme.Dark ? ElementTheme.Dark : ElementTheme.Light;
        Palette = ThemePalette.For(theme: theme, isHighContrast: accessibility.HighContrast, settings: uiSettings);
    }

    public bool IsDemo { get; }

    /// It's quitting: its windows are closing, and its sources stopping.
    public bool IsQuitting => quitting;

    public ThemePalette Palette { get; private set; }

    /// Windows' text size: 1 at 100%.
    public double TextScale => uiSettings.TextScaleFactor;

    public void Start()
    {
        sources.Changed += (_, _) => Refresh();
        desktop.ForegroundChanged += (_, _) => panel.Dismiss(reason: PanelCloseReason.OtherApp);
        desktop.FullScreenChanged += (_, _) => ApplyFullScreen();
        uiSettings.TextScaleFactorChanged += (_, _) => queue.TryEnqueue(callback: () => PlaceBars(force: true));
        // Light, dark, accent and High Contrast changes; AccessibilitySettings' own event needs a UWP window.
        uiSettings.ColorValuesChanged += (_, _) => queue.TryEnqueue(callback: () => ThemeChanged(theme: CurrentTheme()));
        ArrangeBars();
        desktop.Start();
        ticker.Start();
        StartSources();
    }

    public IReadOnlyList<SectionSnapshot> Snapshots() => sources.Snapshots();

    /// Does what a panel asked: BriefBar's own commands, such as reviewing a paused source in Settings, here; the rest,
    /// its source.
    public void Perform(CommandRequest request)
    {
        ArgumentNullException.ThrowIfNull(argument: request);
        if (quitting)
        {
            return;
        }
        Log.Write(line: $"panel: {request.Section} asked for a command");
        if (request.Command == AppCommands.ReviewSource)
        {
            OpenSettings(source: request.Section.Source);
            return;
        }
        sources.Perform(request: request);
    }

    /// Opens Settings at `source`'s page, or at General, or brings it to the front there, in place of the panel.
    public void OpenSettings(SourceId? source)
    {
        if (quitting)
        {
            return;
        }
        panel.Dismiss(reason: PanelCloseReason.Opened);
        if (settings is null)
        {
            var viewModel = new SettingsViewModel(sources: appSources.Switch, copilot: appSources.Copilot, palette: Palette);
            settings = new SettingsWindow(shell: this, viewModel: viewModel);
            var opened = settings;
            opened.Closed += (_, _) =>
            {
                if (settings == opened)
                {
                    settings = null;
                }
            };
            Log.Write(line: $"settings: opened");
        }
        settings.Show(source: source);
    }

    /// Turns `entry` on, or keeps it on after an update, with your consent to what it reads now: its sections show on
    /// the bar as it starts. Returns whether your choice is saved, to last after BriefBar quits (`SourceSwitch`).
    public Task<bool> TurnOnAsync(SourceEntry entry) => SwitchAsync(operation: appSources.Switch.TurnOnAsync(entry: entry, runner: sources));

    /// Turns `entry` off: it stops, its sections leave the bar, and what it saved is deleted. Returns whether your choice
    /// is saved, to last after BriefBar quits (`SourceSwitch`).
    public Task<bool> TurnOffAsync(SourceEntry entry) => SwitchAsync(operation: appSources.Switch.TurnOffAsync(entry: entry, runner: sources));

    /// Opens the Overview on the main display, as a second start of BriefBar asks.
    public void ShowOverview()
    {
        var bar = bars.Find(match: candidate => candidate.Display.IsPrimary) ?? bars.FirstOrDefault();
        if (quitting || bar is null)
        {
            return;
        }
        panel.Show(bar: bar, target: PanelTarget.Overview, itemAnchor: bar.OverviewAnchor());
    }

    /// Quits: gives every bar's space back at once, closes the panel, then the windows, stops the sources and ends.
    public void Quit()
    {
        if (quitting)
        {
            return;
        }
        quitting = true;
        var started = Stopwatch.GetTimestamp();
        Log.Write(line: $"quitting");
        // The space first, so nothing that follows can keep it reserved.
        GiveSpaceBack();
        panel.Shutdown();
        settings?.Close();
        settings = null;
        desktop.Dispose();
        ticker.Stop();
        displaysSettle.Stop();
        foreach (var bar in bars.Concat(second: spares))
        {
            bar.CloseWindow();
        }
        bars.Clear();
        spares.Clear();
        Log.Write(line: $"quitting: windows closed after {Stopwatch.GetElapsedTime(startingTimestamp: started)}");
        FinishQuitting(started: started);
    }

    /// Another program asked a bar to close, as `taskkill` without /F does: BriefBar quits, once that bar's close is
    /// turned down.
    public void CloseRequested()
    {
        if (quitting)
        {
            return;
        }
        Log.Write(line: $"asked to close: quitting");
        queue.TryEnqueue(callback: Quit);
    }

    public void Dispose()
    {
        desktop.Dispose();
        sources.Dispose();
    }

    /// Gives every bar's space back at once, as BriefBar quits or ends.
    public void GiveSpaceBack()
    {
        foreach (var bar in bars)
        {
            bar.GiveSpaceBack();
        }
    }

    /// An item was pressed on `bar`. A bar that stepped aside keeps its buttons, which a UI Automation client that held
    /// on to one could still press: nothing opens from it.
    public void ItemPressed(BarWindow bar, PanelTarget target, PixelRect anchor)
    {
        if (!quitting && bars.Contains(item: bar))
        {
            panel.Press(bar: bar, target: target, itemAnchor: anchor);
        }
    }

    public void EmptySpacePressed() => panel.Dismiss(reason: PanelCloseReason.EmptySpace);

    /// Displays were added, removed or rearranged, or the computer woke: once they settle, a bar for each again.
    public void DisplaysChanged()
    {
        displaysSettle.Stop();
        displaysSettle.Start();
    }

    /// Something moved `bar`'s space, the work area or the scaling. If the displays are still the ones the bars are on,
    /// `bar` fits itself to the change; otherwise, a bar for each display again, as `DisplaysChanged`: a remote session
    /// whose monitors change, for one, tells windows only that their space moved. A spare has no space to fit.
    public void LayoutChanged(BarWindow bar, bool force)
    {
        if (quitting || !bars.Contains(item: bar))
        {
            return;
        }
        var displays = Displays.All();
        var same = displays.Count == bars.Count && displays.All(predicate: display => bars.Exists(
            match: candidate => candidate.Display.Handle == display.Handle && candidate.Display.Bounds == display.Bounds));
        if (same)
        {
            bar.Place(force: force);
            return;
        }
        if (!displaysSettle.IsRunning)
        {
            Log.Write(line: $"displays: {displays.Count}, not the {bars.Count} the bars are on");
        }
        DisplaysChanged();
    }

    public void CheckFullScreen() => desktop.Check();

    public void ExplorerRestarted()
    {
        Log.Write(line: $"Explorer started again: reserving {bars.Count} bars' space again");
        foreach (var bar in bars)
        {
            bar.ReserveAgain();
        }
    }

    /// Windows changed between light and dark, turned High Contrast on or off, or changed its contrast theme:
    /// everything's colors follow.
    public void ThemeChanged(ElementTheme theme)
    {
        var palette = ThemePalette.For(theme: theme, isHighContrast: accessibility.HighContrast, settings: uiSettings);
        if (palette.Matches(other: Palette))
        {
            return;
        }
        Palette = palette;
        Log.Write(line: $"theme: dark {palette.IsDark}, high contrast {palette.IsHighContrast}");
        settings?.UsePalette(palette: palette);
        Refresh();
    }

    /// Marks `target`'s item open on `owner`, the bar the panel opened from, and every other item closed.
    public void ShowOpen(BarWindow? owner, PanelTarget? target)
    {
        foreach (var bar in bars)
        {
            bar.ViewModel.ShowOpen(target: bar == owner ? target : null);
        }
    }

    /// A bar on each display, from the windows BriefBar has where it can (`BarArrangement`): a bar keeps its display or
    /// takes another, a spare shows again, and only a display left over gets a new window. A bar that takes no display
    /// steps aside. None closes: closing a WinUI window while a UI Automation client holds on to it can crash BriefBar,
    /// and a display change, with its window messages, is just when that happens.
    void ArrangeBars()
    {
        var displays = Displays.All();
        var windows = bars.Concat(second: spares).ToList();
        var plan = BarArrangement.Plan(
            candidates: windows.Select(selector: bar => bar.Candidate).ToList(),
            displays: displays.Select(selector: display => display.Shape).ToList());
        foreach (var index in plan.SteppingAside)
        {
            windows[index].StepAside();
        }
        var now = DateTimeOffset.Now;
        var snapshots = sources.Snapshots();
        var arranged = new List<BarWindow>();
        for (var index = 0; index < displays.Count; index++)
        {
            var display = displays[index];
            var bar = plan.ForDisplays[index] is { } taken ? windows[taken] : new BarWindow(shell: this, display: display);
            bar.TakeOver(display: display);
            bar.ViewModel.Update(snapshots: snapshots, palette: Palette, now: now);
            arranged.Add(item: bar);
        }
        bars.Clear();
        bars.AddRange(collection: arranged);
        spares.Clear();
        spares.AddRange(collection: windows.Where(predicate: bar => !arranged.Contains(item: bar)));
        foreach (var bar in bars)
        {
            bar.Place(force: true);
        }
        var created = plan.ForDisplays.Count(predicate: taken => taken is null);
        Log.Write(line: $"bars: {bars.Count}, {created} new, {plan.SteppingAside.Count} stepped aside, {spares.Count} spare");
        ApplyFullScreen();
    }

    /// The displays settled after a change: a bar for each again, without the panel, which opened under a bar that may
    /// have moved.
    void DisplaysSettled()
    {
        if (quitting)
        {
            return;
        }
        panel.Dismiss(reason: PanelCloseReason.DisplaysChanged);
        ArrangeBars();
        desktop.Check();
    }

    void PlaceBars(bool force)
    {
        foreach (var bar in bars)
        {
            bar.Place(force: force);
        }
    }

    void Refresh()
    {
        if (quitting)
        {
            return;
        }
        var now = DateTimeOffset.Now;
        var snapshots = sources.Snapshots();
        foreach (var bar in bars)
        {
            bar.ViewModel.Update(snapshots: snapshots, palette: Palette, now: now);
        }
        panel.Refresh(now: now);
    }

    void ApplyFullScreen()
    {
        foreach (var bar in bars)
        {
            var hidden = desktop.HasFullScreen(monitor: bar.Display.Handle);
            if (hidden && panel.Owner == bar)
            {
                panel.Dismiss(reason: PanelCloseReason.FullScreen);
            }
            bar.SetHiddenForFullScreen(hidden: hidden);
        }
    }

    ElementTheme CurrentTheme() => bars.FirstOrDefault()?.Theme ?? ElementTheme.Default;

    /// A source that fails to start ends BriefBar, logged, through the UI thread's unhandled-exception handler. Quitting
    /// while sources start stops their starting, which isn't a failure.
    async void StartSources()
    {
        try
        {
            await sources.StartAsync().ConfigureAwait(continueOnCapturedContext: true);
        }
        catch (OperationCanceledException) when (quitting)
        {
            Log.Write(line: $"sources: starting stopped, as BriefBar quits");
        }
    }

    /// Waits for sources being turned on or off to finish, then for the sources to stop, at most 2 seconds each; saves
    /// what couldn't be saved, if it can now; and ends.
    async void FinishQuitting(long started)
    {
        try
        {
            await WaitForSwitchingAsync(timeout: TimeSpan.FromSeconds(value: 2)).ConfigureAwait(continueOnCapturedContext: true);
            await sources.StopAsync(timeout: TimeSpan.FromSeconds(value: 2)).ConfigureAwait(continueOnCapturedContext: true);
        }
        finally
        {
            appSources.Settings.Flush();
            Dispose();
            Log.Write(line: $"quit after {Stopwatch.GetElapsedTime(startingTimestamp: started)}");
            exit();
        }
    }

    /// Notes `operation`, a source being turned on or off, until it's done, for quitting to wait for.
    async Task<bool> SwitchAsync(Task<bool> operation)
    {
        switching.Add(item: operation);
        try
        {
            return await operation.ConfigureAwait(continueOnCapturedContext: true);
        }
        finally
        {
            switching.Remove(item: operation);
        }
    }

    /// Waits at most `timeout` for every source being turned on or off. How each went is for whoever asked for it,
    /// Settings, which awaits it, to say: here, only that it's done.
    async Task WaitForSwitchingAsync(TimeSpan timeout)
    {
        if (switching.Count == 0)
        {
            return;
        }
        var all = Task.WhenAll(tasks: switching.ToList());
        if (await Task.WhenAny(task1: all, task2: Task.Delay(delay: timeout)).ConfigureAwait(continueOnCapturedContext: true) != all)
        {
            Log.Write(line: $"sources: still turning on or off after {timeout}; quitting anyway");
        }
    }
}
