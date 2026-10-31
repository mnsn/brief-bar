using BriefBar.Core;
using BriefBar.Core.Logging;
using BriefBar.Core.Presentation;
using Microsoft.UI.Dispatching;

namespace BriefBar.Services;

/// Runs the sources that are on, and hands what their sections show to the UI thread: a burst of changes from a source
/// becomes one update there.
internal sealed class SourceHost : IDisposable
{
    readonly IReadOnlyList<ISectionSource> sources;
    readonly DispatcherQueue queue;
    readonly CancellationTokenSource stopping = new();
    int updateQueued;

    public SourceHost(IReadOnlyList<ISectionSource> sources, DispatcherQueue queue)
    {
        this.sources = sources;
        this.queue = queue;
        foreach (var source in sources)
        {
            source.Changed += OnSourceChanged;
        }
    }

    /// What the sections show may have changed. Raised on the UI thread.
    public event EventHandler? Changed;

    /// Every section of the sources that are on, in the bar's order.
    public IReadOnlyList<SectionSnapshot> Snapshots()
    {
        var snapshots = sources
            .SelectMany(selector: source => source.Sections.Select(selector: section => source.Snapshot(section: section.Id)))
            .ToList();
        var order = Sections.InBarOrder.Select(selector: section => section.Id).ToList();
        return snapshots
            .OrderBy(keySelector: snapshot => order.IndexOf(item: snapshot.Info.Id) is var index && index >= 0 ? index : int.MaxValue)
            .ToList();
    }

    /// Starts every source, in turn, and none once they're stopping. A source handles what it can expect, such as a
    /// missing sign-in, and shows it as its section's problem; anything else it throws ends BriefBar, logged, rather
    /// than leaving its section starting forever. Stopping makes it throw `OperationCanceledException`.
    public async Task StartAsync()
    {
        // Taken once: the token stays readable after the host is disposed, as quitting may do while a source starts.
        var cancellationToken = stopping.Token;
        foreach (var source in sources)
        {
            cancellationToken.ThrowIfCancellationRequested();
            await source.StartAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: true);
        }
        Log.Write(line: $"sources: {sources.Count} started");
    }

    /// Stops every source, waiting at most `timeout` for them, and lets go of their events.
    public async Task StopAsync(TimeSpan timeout)
    {
        await stopping.CancelAsync().ConfigureAwait(continueOnCapturedContext: true);
        foreach (var source in sources)
        {
            source.Changed -= OnSourceChanged;
        }
        var stopped = Task.WhenAll(tasks: sources.Select(selector: source => source.StopAsync()));
        if (await Task.WhenAny(task1: stopped, task2: Task.Delay(delay: timeout)).ConfigureAwait(continueOnCapturedContext: true) != stopped)
        {
            Log.Write(line: $"sources: still stopping after {timeout}; quitting anyway");
        }
        else
        {
            await stopped.ConfigureAwait(continueOnCapturedContext: true);
        }
    }

    public void Dispose() => stopping.Dispose();

    void OnSourceChanged(object? sender, EventArgs e)
    {
        // One update for a burst: while one waits on the UI thread, more changes join it.
        if (Interlocked.Exchange(location1: ref updateQueued, value: 1) == 1)
        {
            return;
        }
        if (!queue.TryEnqueue(callback: () =>
        {
            Volatile.Write(location: ref updateQueued, value: 0);
            Changed?.Invoke(sender: this, e: EventArgs.Empty);
        }))
        {
            Volatile.Write(location: ref updateQueued, value: 0);
        }
    }
}
