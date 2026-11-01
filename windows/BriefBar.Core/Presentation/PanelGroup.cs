namespace BriefBar.Core.Presentation;

/// A group of rows as a panel shows it: its title, the state that colors it, and its rows in order.
public sealed record PanelGroup(string Key, string Title, ItemState? State, IReadOnlyList<ItemRow> Rows)
{
    /// What the panel can ask its source to do to the whole group, such as "Clear".
    public IReadOnlyList<PanelCommand> Commands { get; init; } = [];

    /// It starts folded, as Copilot's idle sessions do.
    public bool IsFolded { get; init; }
}
