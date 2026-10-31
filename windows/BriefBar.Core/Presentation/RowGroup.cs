namespace BriefBar.Core.Presentation;

/// One of a section's own groups, such as Copilot's "Running" or "Idle": its rows show under its title in the section's
/// panel. `State` colors it, or none for a group that isn't counted, such as an idle session's.
public sealed record RowGroup(string Key, string Title, ItemState? State)
{
    /// What its panel can ask its source to do to the whole group, such as "Clear".
    public IReadOnlyList<PanelCommand> Commands { get; init; } = [];

    /// It starts folded, showing only its title and count until you unfold it, as Copilot's idle sessions do.
    public bool IsFolded { get; init; }
}
