namespace BriefBar.Core.Presentation;

/// A small capsule on a row for what it's linked to, such as a work item's number.
public sealed record RowChip(RowChipKind Kind, string Text);
