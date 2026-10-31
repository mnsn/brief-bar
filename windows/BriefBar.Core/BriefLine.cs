namespace BriefBar.Core;

/// One line of a brief across sources: one thing, said in a sentence, which opens it. `Id` names the thing, and changes
/// when what it says should; `Date` is when it got to its state, for the newest first.
public sealed record BriefLine(string Id, SectionId Section, ItemState State, DateTimeOffset? Date, string Sentence)
{
    public SourceId? Source => Section.Source;
}
