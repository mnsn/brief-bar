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
    /// it starts, in place of its paused self. Nothing for one that's on.
    public async Task TurnOnAsync(SourceEntry entry, ISourceRunner runner)
    {
        ArgumentNullException.ThrowIfNull(argument: runner);
        if (State(entry: entry) == SourceState.On)
        {
            return;
        }
        choices.TurnOn(source: entry.Id, version: entry.Description.Version, date: time.GetUtcNow());
        choices.Save(settings: settings);
        Log.Write(line: $"sources: {entry.Id} turned on, version {entry.Description.Version}");
        Release(source: await runner.RemoveAsync(source: entry.Id).ConfigureAwait(continueOnCapturedContext: true));
        await runner.AddAsync(source: make(arg: entry)).ConfigureAwait(continueOnCapturedContext: true);
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }

    /// Turns `entry` off: saved first, then it stops, and what it saved for you is deleted, whether it ran or waited,
    /// paused. Its settings stay. Nothing for one that's off.
    public async Task TurnOffAsync(SourceEntry entry, ISourceRunner runner)
    {
        ArgumentNullException.ThrowIfNull(argument: runner);
        if (State(entry: entry) == SourceState.Off)
        {
            return;
        }
        choices.TurnOff(source: entry.Id);
        choices.Save(settings: settings);
        Log.Write(line: $"sources: {entry.Id} turned off");
        var stopped = await runner.RemoveAsync(source: entry.Id).ConfigureAwait(continueOnCapturedContext: true);
        // A paused source saved nothing, but what the source saved before it was paused is still there.
        var owner = stopped is null or PausedSource ? make(arg: entry) : stopped;
        owner.DeleteSavedData();
        Release(source: owner);
        if (!ReferenceEquals(objA: owner, objB: stopped))
        {
            Release(source: stopped);
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }

    static void Release(ISectionSource? source) => (source as IDisposable)?.Dispose();
}
