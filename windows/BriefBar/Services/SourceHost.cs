using BriefBar.Core;
using BriefBar.Core.Logging;
using BriefBar.Core.Presentation;
using Microsoft.UI.Dispatching;

namespace BriefBar.Services;

/// Runs the sources that are on, and hands what their sections show to the UI thread: a burst of changes from a source
/// becomes one update there. Sources come and go as you turn them on and off in Settings. Used on the UI thread only.
internal sealed class SourceHost : ISourceRunner, IDisposable
{
    readonly List<ISectionSource> sources;
    readonly DispatcherQueue queue;
    readonly CancellationTokenSource stopping = new();
    bool started;
    int updateQueued;

    public SourceHost(IReadOnlyList<ISectionSource> sources, DispatcherQueue queue)
    {
        this.sources = [.. sources];
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
        started = true;
        foreach (var source in sources.ToList())
        {
            cancellationToken.ThrowIfCancellationRequested();
            await source.StartAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: true);
        }
        Log.Write(line: $"sources: {sources.Count} started");
    }

    /// Adds a source you turned on, and starts it once the others have started, or at once after that. Its sections show
    /// at once, starting.
    public async Task AddAsync(ISectionSource source)
    {
        ArgumentNullException.ThrowIfNull(argument: source);
        var cancellationToken = stopping.Token;
        cancellationToken.ThrowIfCancellationRequested();
        sources.Add(item: source);
        source.Changed += OnSourceChanged;
        OnSourceChanged(sender: source, e: EventArgs.Empty);
        if (started)
        {
            await source.StartAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: true);
        }
        Log.Write(line: $"sources: {source.Source} added");
    }

    /// Stops `source` and takes its sections off the bar, as you turn it off, and returns it, stopped; or null when it
    /// isn't running.
    public async Task<ISectionSource?> RemoveAsync(SourceId source)
    {
        var running = sources.Find(match: candidate => candidate.Source == source);
        if (running is null)
        {
            return null;
        }
        sources.Remove(item: running);
        running.Changed -= OnSourceChanged;
        OnSourceChanged(sender: running, e: EventArgs.Empty);
        await running.StopAsync().ConfigureAwait(continueOnCapturedContext: true);
        Log.Write(line: $"sources: {source} removed");
        return running;
    }

    /// Asks the source whose section `request` names to do it; nothing when that source is gone, as it may be by the time
    /// a click arrives.
    public void Perform(CommandRequest request)
    {
        ArgumentNullException.ThrowIfNull(argument: request);
        var source = sources.Find(match: candidate => candidate.Sections.Any(predicate: section => section.Id == request.Section));
        source?.Perform(request: request);
    }

    /// Stops every source, waiting at most `timeout` for them, cancelling included, and lets go of their events.
    public async Task StopAsync(TimeSpan timeout)
    {
        var deadline = Task.Delay(delay: timeout);
        // Within the timeout too: the cancellation finishes only once every callback registered on the token has run,
        // and a callback, such as one stopping a program a source started, may block.
        var cancelled = stopping.CancelAsync();
        var stoppingSources = sources.ToList();
        foreach (var source in stoppingSources)
        {
            source.Changed -= OnSourceChanged;
        }
        // Each source stops off the UI thread, so one that blocks before it returns its task is timed out like the rest,
        // and holds no other back.
        var stopped = Task.WhenAll(tasks: [cancelled, .. stoppingSources.Select(selector: source => Task.Run(function: source.StopAsync))]);
        if (await Task.WhenAny(task1: stopped, task2: deadline).ConfigureAwait(continueOnCapturedContext: true) != stopped)
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
