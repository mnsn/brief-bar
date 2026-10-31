using BriefBar.Core.Presentation;
using BriefBar.Core.Settings;

namespace BriefBar.Core.Tests;

public sealed class SourceSwitchTests
{
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
        await sources.TurnOnAsync(entry: entry, runner: runner);
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

    static SourceSwitch Switch(MemorySettings settings, List<FakeSource> made) => new(
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

    sealed class FakeRunner(List<ISectionSource>? running = null) : ISourceRunner
    {
        public List<ISectionSource> Running { get; } = running ?? [];

        public async Task AddAsync(ISectionSource source)
        {
            Running.Add(item: source);
            await source.StartAsync(cancellationToken: CancellationToken.None);
        }

        public async Task<ISectionSource?> RemoveAsync(SourceId source)
        {
            var found = Running.Find(match: candidate => candidate.Source == source);
            if (found is null)
            {
                return null;
            }
            Running.Remove(item: found);
            await found.StopAsync();
            return found;
        }
    }

    sealed class FakeSource : ISectionSource, IDisposable
    {
        public SourceId Source => SourceId.Copilot;

        public IReadOnlyList<SectionInfo> Sections { get; } = [Core.Sections.CopilotSessions];

        public bool Started { get; private set; }

        public bool Stopped { get; private set; }

        public int Deletions { get; private set; }

        public bool Disposed { get; private set; }

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
            Stopped = true;
            return Task.CompletedTask;
        }

        public SectionSnapshot Snapshot(SectionId section) => SectionSnapshot.Starting(info: Core.Sections.CopilotSessions);

        public void Perform(CommandRequest request)
        {
        }

        public void DeleteSavedData() => Deletions++;

        public void Dispose() => Disposed = true;
    }
}
