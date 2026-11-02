namespace BriefBar.Core.Presentation;

/// What's left before a row's thing is done, and what's done, on a line under it, as the Mac's line under each of your
/// pull requests says what's left before you can complete it: each thing in order, `Summary`, all of it in a sentence or
/// two, which Narrator says, and `IsQuiet`, its words all quiet, as an idle row's title is.
public sealed record RowChecklist(ValueList<RowChecklistItem> Items, ValueList<string> Summary, bool IsQuiet = false);
