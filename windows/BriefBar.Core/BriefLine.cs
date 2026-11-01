namespace BriefBar.Core;

/// One line of a brief across sources: one thing, said in a sentence, which opens it. `Id` is its row's, unique within
/// its `Section`, so the two name the thing across sources, as the Mac's IDs do by starting with their source. `Date`
/// is when it got to its state, for the newest first.
public sealed record BriefLine(string Id, SectionId Section, ItemState State, DateTimeOffset? Date, string Sentence)
{
    public SourceId? Source => Section.Source;
}
