namespace BriefBar.Core.Presentation;

/// A group of rows as a panel shows it: its title, the state that colors it, and its rows in order.
public sealed record PanelGroup(string Key, string Title, ItemState? State, IReadOnlyList<ItemRow> Rows);
