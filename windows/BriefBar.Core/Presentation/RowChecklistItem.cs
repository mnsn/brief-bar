namespace BriefBar.Core.Presentation;

/// One thing on a row's checklist: its icon, in `State`'s color or quiet without one, its words, and whether it's done,
/// which reads quieter than what's left.
public sealed record RowChecklistItem(IconKey Icon, ItemState? State, string Label, bool IsDone);
