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
internal sealed class AppShell : IDisposable
{
    /// What Explorer broadcasts when it starts again, having forgotten every bar's space.
    public static readonly uint TaskbarCreated = User32.RegisterWindowMessage(message: "TaskbarCreated");

    readonly DispatcherQueue queue;
    readonly SourceHost sources;
    readonly Action exit;
    readonly List<BarWindow> bars = [];
    readonly PanelController panel;
    readonly DesktopWatcher desktop;
    readonly DispatcherQueueTimer displaysSettle;
    readonly DispatcherQueueTimer ticker;
    readonly UISettings uiSettings = new();
    readonly AccessibilitySettings accessibility = new();
    bool quitting;

    public AppShell(DispatcherQueue queue, IReadOnlyList<ISectionSource> sources, bool isDemo, Action exit)
    {
        this.queue = queue;
        this.exit = exit;
        IsDemo = isDemo;
        this.sources = new SourceHost(sources: sources, queue: queue);
        panel = new PanelController(shell: this);
        desktop = new DesktopWatcher(queue: queue);
        displaysSettle = queue.CreateTimer();
        displaysSettle.Interval = TimeSpan.FromMilliseconds(value: 800);
        displaysSettle.IsRepeating = false;
        displaysSettle.Tick += (_, _) => RecreateBars();
        // Times such as "3m" and "Updated 20 s ago" move on by themselves.
        ticker = queue.CreateTimer();
        ticker.Interval = TimeSpan.FromSeconds(value: 15);
        ticker.Tick += (_, _) => Refresh();
        var theme = Application.Current.RequestedTheme == ApplicationTheme.Dark ? ElementTheme.Dark : ElementTheme.Light;
        Palette = ThemePalette.For(theme: theme, isHighContrast: accessibility.HighContrast);
    }

    public bool IsDemo { get; }

    public ThemePalette Palette { get; private set; }

    /// Windows' text size: 1 at 100%.
    public double TextScale => uiSettings.TextScaleFactor;

    public void Start()
    {
        sources.Changed += (_, _) => Refresh();
        desktop.ForegroundChanged += (_, _) => panel.Dismiss();
        desktop.FullScreenChanged += (_, _) => ApplyFullScreen();
        uiSettings.TextScaleFactorChanged += (_, _) => queue.TryEnqueue(callback: () => PlaceBars(force: true));
        // Light, dark, accent and High Contrast changes; AccessibilitySettings' own event needs a UWP window.
        uiSettings.ColorValuesChanged += (_, _) => queue.TryEnqueue(callback: () => ThemeChanged(theme: CurrentTheme()));
        CreateBars();
        desktop.Start();
        ticker.Start();
        StartSources();
    }

    public IReadOnlyList<SectionSnapshot> Snapshots() => sources.Snapshots();

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
        desktop.Dispose();
        ticker.Stop();
        displaysSettle.Stop();
        foreach (var bar in bars)
        {
            bar.CloseWindow();
        }
        bars.Clear();
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

    public void ItemPressed(BarWindow bar, PanelTarget target, PixelRect anchor)
    {
        if (!quitting)
        {
            panel.Press(bar: bar, target: target, itemAnchor: anchor);
        }
    }

    public void EmptySpacePressed() => panel.Dismiss();

    /// Displays were added, removed or rearranged, or the computer woke: once they settle, a bar for each again.
    public void DisplaysChanged()
    {
        displaysSettle.Stop();
        displaysSettle.Start();
    }

    /// Something moved `bar`'s space, the work area or the scaling. If the displays are still the ones the bars are on,
    /// `bar` fits itself to the change; otherwise, a bar for each display again, as `DisplaysChanged`: a remote session
    /// whose monitors change, for one, tells windows only that their space moved.
    public void LayoutChanged(BarWindow bar, bool force)
    {
        if (quitting)
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

    /// Windows changed between light and dark, or High Contrast: everything's colors follow.
    public void ThemeChanged(ElementTheme theme)
    {
        var palette = ThemePalette.For(theme: theme, isHighContrast: accessibility.HighContrast);
        if (palette.IsDark == Palette.IsDark && palette.IsHighContrast == Palette.IsHighContrast)
        {
            return;
        }
        Palette = palette;
        Log.Write(line: $"theme: dark {palette.IsDark}, high contrast {palette.IsHighContrast}");
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

    void CreateBars()
    {
        var now = DateTimeOffset.Now;
        var snapshots = sources.Snapshots();
        foreach (var display in Displays.All())
        {
            var bar = new BarWindow(shell: this, display: display);
            bar.ViewModel.Update(snapshots: snapshots, palette: Palette, now: now);
            bars.Add(item: bar);
            bar.Place(force: true);
        }
        Log.Write(line: $"bars: {bars.Count}");
        ApplyFullScreen();
    }

    void RecreateBars()
    {
        if (quitting)
        {
            return;
        }
        panel.Dismiss();
        foreach (var bar in bars)
        {
            bar.GiveSpaceBack();
            bar.CloseWindow();
        }
        bars.Clear();
        CreateBars();
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
                panel.Dismiss();
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

    /// Waits for the sources to stop, at most 2 seconds, then ends.
    async void FinishQuitting(long started)
    {
        try
        {
            await sources.StopAsync(timeout: TimeSpan.FromSeconds(value: 2)).ConfigureAwait(continueOnCapturedContext: true);
        }
        finally
        {
            Dispose();
            Log.Write(line: $"quit after {Stopwatch.GetElapsedTime(startingTimestamp: started)}");
            exit();
        }
    }
}
