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

    /// Stops reading, and gives back whatever it holds open, which may take a while. It saves nothing more once it
    /// returns, before its task completes: what it saved can be deleted then (`DeleteSavedData`).
    Task StopAsync();

    /// What `section` shows now. Safe to call from any thread.
    SectionSnapshot Snapshot(SectionId section);

    /// Does what its panel asked, on the UI thread, such as opening a row's item: one of the commands its snapshot
    /// offers. One it doesn't offer now, as for a row that's gone, does nothing.
    void Perform(CommandRequest request);

    /// Deletes what it saved about your data, but not its settings: as you turn it off, once `StopAsync` has returned,
    /// without waiting for its task, or on a source that never started.
    void DeleteSavedData();
}
