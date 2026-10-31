namespace BriefBar.Core;

/// A source BriefBar for Windows can show, as Settings lists it: its name, glyph and color, what it says it reads, and
/// its sections.
public sealed record SourceEntry(SourceId Id, string Name, IconKey Glyph, uint Tint, SourceDescription Description, IReadOnlyList<SectionInfo> Sections);
