namespace BriefBar.Core;

/// One of a source's sections: a list it shows under an item in the bar, and a page in the window.
/// `Title` names its page ("Sessions"); `BarLabel` names its item in the bar, by its source where that's clearer
/// ("Copilot"); `FullName` says what it is anywhere, for tooltips and Narrator ("GitHub Copilot sessions"). `Tint` is
/// its source's color, as ARGB. `States` are the states its things can be in, in the order its item in the bar shows
/// them; none for a section such as the sprint.
public sealed record SectionInfo(
    SectionId Id,
    string Title,
    string BarLabel,
    string FullName,
    IconKey Glyph,
    uint Tint,
    CountNoun Counted,
    IReadOnlyList<ItemState> States)
{
    /// Such as "GitHub Copilot", or the raw name of a source this version doesn't know.
    public string SourceName => Id.Source is { } source ? SourceIds.DisplayName(source: source) : Id.RawValue;
}
