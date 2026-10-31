namespace BriefBar.Core.Presentation;

/// What a panel asks a source to do: `Command` to the row `RowId` of `Section`, to its group `GroupKey`, or, with
/// neither, to the section itself.
public sealed record CommandRequest(SectionId Section, string Command, string? RowId = null, string? GroupKey = null);
