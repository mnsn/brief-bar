using BriefBar.Core.Presentation;

namespace BriefBar.Core;

/// One source, as the app sees it: it reads nothing until `StartAsync`, and says when what its sections show may have
/// changed. A source that's off isn't created at all.
public interface ISectionSource
{
    SourceId Source { get; }

    /// Its sections, in the order the bar shows them.
    IReadOnlyList<SectionInfo> Sections { get; }

    /// Raised, on any thread, when what one of its sections shows may have changed.
    event EventHandler? Changed;

    /// Starts reading. Returns once it's started, not once it has read.
    Task StartAsync(CancellationToken cancellationToken);

    /// Stops reading, and gives back whatever it holds open.
    Task StopAsync();

    /// What `section` shows now. Safe to call from any thread.
    SectionSnapshot Snapshot(SectionId section);
}
