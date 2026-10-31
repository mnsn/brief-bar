namespace BriefBar.Core.Presentation;

/// A small tag on a row that names something related, such as "↳ Release 2.5", the session that started a Copilot
/// session: `Spoken` says what it is, in words, and `Command` is the row's command that opens it, or null when nothing
/// can.
public sealed record RowTag(string Text, string ToolTip, string Spoken, string? Command);
