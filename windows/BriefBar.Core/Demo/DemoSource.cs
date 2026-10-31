using BriefBar.Core.Presentation;

namespace BriefBar.Core.Demo;

/// A source that shows `DemoData`'s made-up sections and reads nothing. Its rows' times are minutes before it was made,
/// so they age as they would.
public sealed class DemoSource : ISectionSource
{
    readonly Dictionary<SectionId, SectionSnapshot> snapshots;

    public DemoSource(SourceId source, DateTimeOffset madeAt)
    {
        Source = source;
        var ofSource = DemoData.Snapshots(now: madeAt).Where(predicate: snapshot => snapshot.Info.Id.Source == source).ToList();
        snapshots = ofSource.ToDictionary(keySelector: snapshot => snapshot.Info.Id);
        Sections = ofSource.Select(selector: snapshot => snapshot.Info).ToList();
    }

    public SourceId Source { get; }

    public IReadOnlyList<SectionInfo> Sections { get; }

    /// It never changes.
    public event EventHandler? Changed
    {
        add { }
        remove { }
    }

    /// Every source's made-up sections, each as its own source.
    public static IReadOnlyList<DemoSource> All(DateTimeOffset madeAt) => Enum.GetValues<SourceId>()
        .Select(selector: source => new DemoSource(source: source, madeAt: madeAt))
        .ToList();

    public Task StartAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    public Task StopAsync() => Task.CompletedTask;

    public SectionSnapshot Snapshot(SectionId section) =>
        snapshots.TryGetValue(key: section, value: out var snapshot)
            ? snapshot
            : throw new ArgumentException(message: "Not one of this source's sections.", paramName: nameof(section));
}
