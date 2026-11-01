using System.Diagnostics;
using System.Text.Json.Nodes;
using BriefBar.Core.Presentation;
using BriefBar.Core.Settings;

namespace BriefBar.Core.Tests;

public sealed class SourceSwitchTests
{
    /// Long enough for anything that should happen; a test that waits this long has failed.
    static readonly TimeSpan wait = TimeSpan.FromSeconds(value: 10);

    static readonly SourceEntry entry = new(
        Id: SourceId.Copilot,
        Name: "GitHub Copilot",
        Glyph: IconKey.Pulse,
        Tint: Sections.CopilotSessions.Tint,
        Description: new SourceDescription(Version: 2, Summary: "Made up", Reads: "Made up", Network: "None", Needs: "Nothing"),
        Sections: [Sections.CopilotSessions]);

    [Fact]
    public void RunsNothingUntilASourceIsTurnedOn()
    {
        var made = new List<FakeSource>();
        var sources = Switch(settings: new MemorySettings(), made: made);
        Assert.Equal(expected: SourceState.Off, actual: sources.State(entry: entry));
        Assert.Empty(collection: sources.Initial());
        Assert.Empty(collection: made);
    }

    [Fact]
    public async Task TurningOnSavesYourConsentThenStartsIt()
    {
        var settings = new MemorySettings();
        var made = new List<FakeSource>();
        var runner = new FakeRunner();
        var sources = Switch(settings: settings, made: made);
        var changes = 0;
        sources.Changed += (_, _) => changes++;

        await sources.TurnOnAsync(entry: entry, runner: runner);

        Assert.Equal(expected: SourceState.On, actual: sources.State(entry: entry));
        Assert.Equal(expected: made, actual: runner.Running);
        Assert.Equal(expected: 1, actual: changes);
        var consent = SourceChoices.Load(settings: settings).Consents["copilot"];
        Assert.Equal(expected: new SourceConsent(Version: 2, Date: Times.At(seconds: 0)), actual: consent);
        // As BriefBar starts again, it's on.
        Assert.IsType<FakeSource>(@object: Assert.Single(collection: Switch(settings: settings, made: made).Initial()));

        // Turning it on again changes nothing.
        Assert.True(condition: await sources.TurnOnAsync(entry: entry, runner: runner));
        Assert.Single(collection: runner.Running);
        Assert.Equal(expected: 1, actual: changes);
    }

    [Fact]
    public async Task TurningOffForgetsYourConsentStopsItAndDeletesWhatItSaved()
    {
        var settings = new MemorySettings();
        var made = new List<FakeSource>();
        var runner = new FakeRunner();
        var sources = Switch(settings: settings, made: made);
        await sources.TurnOnAsync(entry: entry, runner: runner);
        var running = Assert.Single(collection: made);

        await sources.TurnOffAsync(entry: entry, runner: runner);

        Assert.Equal(expected: SourceState.Off, actual: sources.State(entry: entry));
        Assert.Empty(collection: runner.Running);
        Assert.True(condition: running.Stopped);
        Assert.Equal(expected: 1, actual: running.Deletions);
        Assert.True(condition: running.Disposed);
        Assert.Empty(collection: SourceChoices.Load(settings: settings).Consents);
    }

    /// What it saved is deleted as it's turned off, without waiting for it to stop, which can take a while, as while its
    /// first read runs: BriefBar may quit meanwhile, waiting only so long.
    [Fact]
    public async Task DeletesWhatItSavedWithoutWaitingForItToStop()
    {
        var settings = new MemorySettings();
        var made = new List<FakeSource>();
        var runner = new FakeRunner();
        var sources = Switch(settings: settings, made: made);
        await sources.TurnOnAsync(entry: entry, runner: runner);
        var running = Assert.Single(collection: made);
        var stopped = new TaskCompletionSource();
        running.Stopping = stopped.Task;
        var changes = 0;
        sources.Changed += (_, _) => changes++;

        var turningOff = sources.TurnOffAsync(entry: entry, runner: runner);

        Assert.False(condition: turningOff.IsCompleted);
        Assert.Empty(collection: runner.Running);
        Assert.Equal(expected: 1, actual: running.Deletions);
        Assert.Empty(collection: SourceChoices.Load(settings: settings).Consents);
        Assert.False(condition: running.Disposed);
        Assert.Equal(expected: 0, actual: changes);
        // Its stop runs on the thread pool.
        await running.StopCalled.Task.WaitAsync(timeout: wait, cancellationToken: TestContext.Current.CancellationToken);

        stopped.SetResult();
        Assert.True(condition: await turningOff.WaitAsync(timeout: wait, cancellationToken: TestContext.Current.CancellationToken));
        Assert.True(condition: running.Disposed);
        Assert.Equal(expected: 1, actual: changes);
    }

    /// A stop that blocks before it returns, as one waiting for a program might, can't hold up turning its source off:
    /// it runs on the thread pool, and what the source saved is deleted at once.
    [Fact]
    public async Task TurnsOffWithoutWaitingForAStopThatBlocks()
    {
        var settings = new MemorySettings();
        var made = new List<FakeSource>();
        var runner = new FakeRunner();
        var sources = Switch(settings: settings, made: made);
        await sources.TurnOnAsync(entry: entry, runner: runner);
        var running = Assert.Single(collection: made);
        using var hold = new ManualResetEventSlim(initialState: false);
        running.HoldStop = hold;

        var clock = Stopwatch.StartNew();
        var turningOff = sources.TurnOffAsync(entry: entry, runner: runner);
        var returnedAfter = clock.Elapsed;
        await running.StopCalled.Task.WaitAsync(timeout: wait, cancellationToken: TestContext.Current.CancellationToken);

        Assert.True(condition: returnedAfter < TimeSpan.FromSeconds(value: 1), userMessage: $"It took {returnedAfter} to return.");
        Assert.False(condition: turningOff.IsCompleted);
        Assert.Equal(expected: 1, actual: running.Deletions);
        Assert.Empty(collection: SourceChoices.Load(settings: settings).Consents);

        hold.Set();
        Assert.True(condition: await turningOff.WaitAsync(timeout: wait, cancellationToken: TestContext.Current.CancellationToken));
        Assert.True(condition: running.Disposed);
    }

    /// One that fails to stop has still deleted what it saved, and turning it off says it failed.
    [Fact]
    public async Task DeletesWhatItSavedWhenItFailsToStop()
    {
        var settings = new MemorySettings();
        var made = new List<FakeSource>();
        var runner = new FakeRunner();
        var sources = Switch(settings: settings, made: made);
        await sources.TurnOnAsync(entry: entry, runner: runner);
        var running = Assert.Single(collection: made);
        running.Stopping = Task.FromException(exception: new InvalidOperationException(message: "Made-up failure."));

        await Assert.ThrowsAsync<InvalidOperationException>(testCode: () => sources.TurnOffAsync(entry: entry, runner: runner));

        Assert.Equal(expected: SourceState.Off, actual: sources.State(entry: entry));
        Assert.Empty(collection: runner.Running);
        Assert.Equal(expected: 1, actual: running.Deletions);
        Assert.True(condition: running.Disposed);
        Assert.Empty(collection: SourceChoices.Load(settings: settings).Consents);
    }

    /// A choice that can't be saved, as on a full disk, holds until BriefBar quits, and it says so, for Settings to tell
    /// you: a source you turned off would otherwise be on again after a restart, with what's saved still your consent.
    /// The next save that works saves it.
    [Fact]
    public async Task SaysWhenYourChoiceIsntSaved()
    {
        var settings = new FlakySettings();
        var made = new List<FakeSource>();
        var runner = new FakeRunner();
        var sources = Switch(settings: settings, made: made);
        Assert.True(condition: await sources.TurnOnAsync(entry: entry, runner: runner));
        var running = Assert.Single(collection: made);
        settings.Fails = true;

        Assert.False(condition: await sources.TurnOffAsync(entry: entry, runner: runner));

        // It's off now, and what it saved is deleted, from memory at least.
        Assert.Equal(expected: SourceState.Off, actual: sources.State(entry: entry));
        Assert.Empty(collection: runner.Running);
        Assert.Equal(expected: 1, actual: running.Deletions);
        // But a restart would find your consent.
        Assert.Equal(expected: SourceState.On, actual: SourceChoices.Load(settings: settings.AsSaved()).State(source: SourceId.Copilot, version: 2));

        settings.Fails = false;
        Assert.True(condition: await sources.TurnOffAsync(entry: entry, runner: runner));
        Assert.Equal(expected: SourceState.Off, actual: SourceChoices.Load(settings: settings.AsSaved()).State(source: SourceId.Copilot, version: 2));
    }

    /// One turned on whose consent can't be saved is on until BriefBar quits, and off after: it says so too.
    [Fact]
    public async Task SaysWhenItsOnOnlyUntilBriefBarQuits()
    {
        var settings = new FlakySettings { Fails = true };
        var runner = new FakeRunner();
        var sources = Switch(settings: settings, made: []);

        Assert.False(condition: await sources.TurnOnAsync(entry: entry, runner: runner));

        Assert.Equal(expected: SourceState.On, actual: sources.State(entry: entry));
        Assert.Single(collection: runner.Running);
        Assert.Equal(expected: SourceState.Off, actual: SourceChoices.Load(settings: settings.AsSaved()).State(source: SourceId.Copilot, version: 2));
    }

    /// An update made it read more than you saw: it reads nothing, paused, until you've seen what it reads now.
    [Fact]
    public async Task PausesASourceThatReadsMoreUntilYouKeepItOn()
    {
        var settings = new MemorySettings();
        var choices = new SourceChoices();
        choices.TurnOn(source: SourceId.Copilot, version: 1, date: Times.At(seconds: -60));
        choices.Save(settings: settings);
        var made = new List<FakeSource>();
        var sources = Switch(settings: settings, made: made);
        Assert.Equal(expected: SourceState.NeedsReview, actual: sources.State(entry: entry));
        var paused = Assert.IsType<PausedSource>(@object: Assert.Single(collection: sources.Initial()));
        Assert.Empty(collection: made);
        var runner = new FakeRunner(running: [paused]);

        await sources.TurnOnAsync(entry: entry, runner: runner);

        Assert.Equal(expected: SourceState.On, actual: sources.State(entry: entry));
        Assert.IsType<FakeSource>(@object: Assert.Single(collection: runner.Running));
        Assert.Equal(expected: 2, actual: SourceChoices.Load(settings: settings).Consents["copilot"].Version);
    }

    /// What it saved before an update paused it is still there to delete.
    [Fact]
    public async Task TurningOffAPausedSourceDeletesWhatItSavedBefore()
    {
        var settings = new MemorySettings();
        var choices = new SourceChoices();
        choices.TurnOn(source: SourceId.Copilot, version: 1, date: Times.At(seconds: -60));
        choices.Save(settings: settings);
        var made = new List<FakeSource>();
        var sources = Switch(settings: settings, made: made);
        var runner = new FakeRunner(running: [.. sources.Initial()]);

        await sources.TurnOffAsync(entry: entry, runner: runner);

        Assert.Empty(collection: runner.Running);
        var deleting = Assert.Single(collection: made);
        Assert.False(condition: deleting.Started);
        Assert.Equal(expected: 1, actual: deleting.Deletions);
        Assert.True(condition: deleting.Disposed);
        Assert.Equal(expected: SourceState.Off, actual: sources.State(entry: entry));
    }

    static SourceSwitch Switch(ISettingsStorage settings, List<FakeSource> made) => new(
        settings: settings,
        entries: [entry],
        make: _ =>
        {
            var source = new FakeSource();
            made.Add(item: source);
            return source;
        },
        time: new FixedTime(now: Times.At(seconds: 0)));

    sealed class FixedTime(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;
    }

    /// Settings whose saves fail while `Fails` is set, as on a full disk: what a restart would read is `AsSaved()`.
    sealed class FlakySettings : ISettingsStorage
    {
        readonly Dictionary<string, JsonNode> values = new(comparer: StringComparer.Ordinal);
        Dictionary<string, JsonNode> saved = new(comparer: StringComparer.Ordinal);
        bool unsaved;

        public bool Fails { get; set; }

        public JsonNode? Read(string key) => values.TryGetValue(key: key, value: out var value) ? value.DeepClone() : null;

        public bool Write(string key, JsonNode? value)
        {
            if (value is null)
            {
                values.Remove(key: key);
            }
            else
            {
                values[key] = value.DeepClone();
            }
            return Save();
        }

        public bool Flush() => !unsaved || Save();

        /// What a restart would read.
        public MemorySettings AsSaved()
        {
            var restarted = new MemorySettings();
            foreach (var (key, value) in saved)
            {
                restarted.Write(key: key, value: value);
            }
            return restarted;
        }

        bool Save()
        {
            if (Fails)
            {
                unsaved = true;
                return false;
            }
            saved = values.ToDictionary(keySelector: pair => pair.Key, elementSelector: pair => pair.Value.DeepClone(), comparer: StringComparer.Ordinal);
            unsaved = false;
            return true;
        }
    }

    sealed class FakeRunner(List<ISectionSource>? running = null) : ISourceRunner
    {
        public List<ISectionSource> Running { get; } = running ?? [];

        public async Task AddAsync(ISectionSource source)
        {
            Running.Add(item: source);
            await source.StartAsync(cancellationToken: CancellationToken.None);
        }

        public ISectionSource? Remove(SourceId source)
        {
            var found = Running.Find(match: candidate => candidate.Source == source);
            if (found is not null)
            {
                Running.Remove(item: found);
            }
            return found;
        }
    }

    sealed class FakeSource : ISectionSource, IDisposable
    {
        public SourceId Source => SourceId.Copilot;

        public IReadOnlyList<SectionInfo> Sections { get; } = [Core.Sections.CopilotSessions];

        public bool Started { get; private set; }

        /// Its stop was called, on whichever thread.
        public bool Stopped => StopCalled.Task.IsCompleted;

        /// Completes as its stop is called.
        public TaskCompletionSource StopCalled { get; } = new(creationOptions: TaskCreationOptions.RunContinuationsAsynchronously);

        public int Deletions { get; private set; }

        public bool Disposed { get; private set; }

        /// What its stop returns: done at once, unless a test says otherwise.
        public Task Stopping { get; set; } = Task.CompletedTask;

        /// When set, its stop waits for it before it returns, as a stop that blocks would.
        public ManualResetEventSlim? HoldStop { get; set; }

        public event EventHandler? Changed
        {
            add { }
            remove { }
        }

        public Task StartAsync(CancellationToken cancellationToken)
        {
            Started = true;
            return Task.CompletedTask;
        }

        public Task StopAsync()
        {
            StopCalled.TrySetResult();
            HoldStop?.Wait(timeout: wait);
            return Stopping;
        }

        public SectionSnapshot Snapshot(SectionId section) => SectionSnapshot.Starting(info: Core.Sections.CopilotSessions);

        public void Perform(CommandRequest request)
        {
        }

        public void DeleteSavedData() => Deletions++;

        public void Dispose() => Disposed = true;
    }
}
