using BriefBar.Core.Logging;
using BriefBar.Core.Settings;

namespace BriefBar.Core;

/// Turning sources on and off, as Settings does: your choice is saved first (`SourceChoices`), then the source starts,
/// or stops and deletes what it saved. A source you turned on that reads more now than when you did is made paused
/// (`PausedSource`): it reads nothing until you keep it on. The Mac's `AppModel`, for sources. Used on one thread.
public sealed class SourceSwitch
{
    readonly ISettingsStorage settings;
    readonly Func<SourceEntry, ISectionSource> make;
    readonly TimeProvider time;
    readonly SourceChoices choices;
    /// How many times each source was turned on or off, so that one still under way can tell a later choice was made
    /// since, as from Settings opened again, and leave it to that one.
    readonly Dictionary<SourceId, int> choicesMade = [];

    /// - `make`: a source of `entry`, not started yet.
    public SourceSwitch(ISettingsStorage settings, IReadOnlyList<SourceEntry> entries, Func<SourceEntry, ISectionSource> make, TimeProvider? time = null)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        ArgumentNullException.ThrowIfNull(argument: entries);
        ArgumentNullException.ThrowIfNull(argument: make);
        this.settings = settings;
        this.make = make;
        this.time = time ?? TimeProvider.System;
        Entries = entries;
        choices = SourceChoices.Load(settings: settings);
    }

    /// Every source you can turn on, in Settings' order.
    public IReadOnlyList<SourceEntry> Entries { get; }

    /// A source was turned on or off. Raised once it has started, or stopped and deleted what it saved.
    public event EventHandler? Changed;

    public SourceState State(SourceEntry entry)
    {
        ArgumentNullException.ThrowIfNull(argument: entry);
        return choices.State(source: entry.Id, version: entry.Description.Version);
    }

    /// The sources to run as BriefBar starts: each that's on, and each waiting for you to review it, paused.
    public IReadOnlyList<ISectionSource> Initial()
    {
        var sources = new List<ISectionSource>();
        foreach (var entry in Entries)
        {
            switch (State(entry: entry))
            {
                case SourceState.On:
                    sources.Add(item: make(arg: entry));
                    break;
                case SourceState.NeedsReview:
                    Log.Write(line: $"sources: {entry.Id} paused until you review what it reads, version {entry.Description.Version}");
                    sources.Add(item: new PausedSource(source: entry.Id, sections: entry.Sections));
                    break;
                case SourceState.Off:
                    break;
                default:
                    throw new InvalidOperationException(message: "A source is in an unknown state.");
            }
        }
        return sources;
    }

    /// Turns `entry` on, or keeps it on once you've reviewed what it reads now: your consent to that is saved first, then
    /// it starts, in place of its paused self. Nothing for one that's on. Returns whether your choices are saved, to last
    /// after BriefBar quits: when not, as on a full disk, it's on until BriefBar quits, and off after.
    public async Task<bool> TurnOnAsync(SourceEntry entry, ISourceRunner runner)
    {
        ArgumentNullException.ThrowIfNull(argument: runner);
        if (State(entry: entry) == SourceState.On)
        {
            return Saved();
        }
        var choice = NewChoice(source: entry.Id);
        choices.TurnOn(source: entry.Id, version: entry.Description.Version, date: time.GetUtcNow());
        choices.Save(settings: settings);
        Log.Write(line: $"sources: {entry.Id} turned on, version {entry.Description.Version}");
        if (runner.Remove(source: entry.Id) is { } paused)
        {
            await Task.Run(function: paused.StopAsync).ConfigureAwait(continueOnCapturedContext: true);
            Release(source: paused);
            if (choice != choicesMade[entry.Id])
            {
                // Turned off, or on again, while its paused self stopped: the later choice stands, with its own source.
                return Saved();
            }
        }
        await runner.AddAsync(source: make(arg: entry)).ConfigureAwait(continueOnCapturedContext: true);
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
        return Saved();
    }

    /// Turns `entry` off: saved first, then it leaves the bar and stops, on the thread pool, so a stop that blocks can't
    /// hold up the caller, and what it saved for you is deleted, whether it ran or waited, paused. That's at once, before
    /// anything else can happen, such as quitting, rather than once it has stopped, which can take a while. Its settings
    /// stay. Nothing for one that's off. Returns whether your choices are saved, to last after BriefBar quits: when not,
    /// it's off until BriefBar quits, but what's saved still has your consent, so it may be on again after.
    public async Task<bool> TurnOffAsync(SourceEntry entry, ISourceRunner runner)
    {
        ArgumentNullException.ThrowIfNull(argument: runner);
        if (State(entry: entry) == SourceState.Off)
        {
            return Saved();
        }
        _ = NewChoice(source: entry.Id);
        choices.TurnOff(source: entry.Id);
        choices.Save(settings: settings);
        Log.Write(line: $"sources: {entry.Id} turned off");
        var removed = runner.Remove(source: entry.Id);
        var stopping = removed is null ? Task.CompletedTask : Task.Run(function: removed.StopAsync);
        // A paused source saved nothing, but what the source saved before it was paused is still there. Deleting it stops
        // its saving too, whether or not its stop has begun.
        var owner = removed is null or PausedSource ? make(arg: entry) : removed;
        owner.DeleteSavedData();
        var saved = Saved();
        try
        {
            await stopping.ConfigureAwait(continueOnCapturedContext: true);
        }
        finally
        {
            Release(source: owner);
            if (!ReferenceEquals(objA: owner, objB: removed))
            {
                Release(source: removed);
            }
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
        return saved;
    }

    static void Release(ISectionSource? source) => (source as IDisposable)?.Dispose();

    /// Counts a choice for `source`, which makes any earlier one still under way stale; returns its number.
    int NewChoice(SourceId source) => choicesMade[source] = choicesMade.GetValueOrDefault(key: source) + 1;

    /// Whether everything is saved, now that a choice is made: what couldn't be saved before is tried again, so a choice
    /// saved by a later write counts.
    bool Saved()
    {
        var saved = settings.Flush();
        if (!saved)
        {
            Log.Write(line: $"sources: a choice isn't saved, so it lasts only until BriefBar quits");
        }
        return saved;
    }
}
