using BriefBar.Core.Presentation;

namespace BriefBar.Core;

/// A source you turned on that reads more now than what you saw then: it reads nothing, and its sections say it's paused
/// until you've seen what it reads now, in Settings (`SourceState.NeedsReview`).
public sealed class PausedSource(SourceId source, IReadOnlyList<SectionInfo> sections) : ISectionSource
{
    public SourceId Source { get; } = source;

    public IReadOnlyList<SectionInfo> Sections { get; } = sections;

    /// It never changes.
    public event EventHandler? Changed
    {
        add { }
        remove { }
    }

    public Task StartAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    public Task StopAsync() => Task.CompletedTask;

    public SectionSnapshot Snapshot(SectionId section)
    {
        var info = Sections.FirstOrDefault(predicate: candidate => candidate.Id == section)
            ?? throw new ArgumentException(message: "Not one of this source's sections.", paramName: nameof(section));
        return new SectionSnapshot(
            Info: info,
            Status: new SectionStatus(Condition: SectionCondition.Paused),
            Groups: [],
            Rows: [],
            BriefLines: [])
        {
            Commands = [new PanelCommand(Key: AppCommands.ReviewSource, Title: "Review what it reads", Opens: true)],
            EmptyText = "It reads nothing until you've seen what it reads now, and kept it on, in Settings.",
        };
    }

    /// Review is BriefBar's own command.
    public void Perform(CommandRequest request)
    {
    }

    /// It saved nothing while paused; what it saved before stays until you turn it off.
    public void DeleteSavedData()
    {
    }
}
