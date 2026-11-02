namespace BriefBar.Core.Presentation;

/// What a section's panel says when nothing in it is counted, above any rows it doesn't count: Copilot's "All quiet",
/// over "3 idle sessions".
public sealed record QuietNote(string Title, string Detail);
