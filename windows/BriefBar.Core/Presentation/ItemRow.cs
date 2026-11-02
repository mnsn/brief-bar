namespace BriefBar.Core.Presentation;

/// One of a section's things, as its rows show it: a chat, a pull request, a Copilot session.
public sealed record ItemRow
{
    /// Unique within its section, and the same for as long as it's the same thing.
    public required string Id { get; init; }

    public required SectionId Section { get; init; }

    /// The key of the section's group it shows in.
    public required string Group { get; init; }

    /// What it means for you, or null for a thing the bar doesn't count, such as an idle session.
    public ItemState? State { get; init; }

    public required IconKey Icon { get; init; }

    public required string Title { get; init; }

    /// Where it stands, such as "Waiting for your answer · shop-web".
    public required string Status { get; init; }

    public StatusTone StatusTone { get; init; } = StatusTone.State;

    /// What it's about, such as the question it asks, in two lines at most.
    public string? Detail { get; init; }

    /// When it got to its state, or last changed.
    public DateTimeOffset? Date { get; init; }

    /// When it was created, set while its section's list is sorted by that: its time there says how long ago it was
    /// created, rather than since `Date`, which the Overview still orders and dates it by.
    public DateTimeOffset? Created { get; init; }

    /// Unread messages, for a chat.
    public int Unread { get; init; }

    /// New since you last looked at it.
    public bool IsNew { get; init; }

    public IReadOnlyList<RowChip> Chips { get; init; } = [];

    /// A chat's initials, shown in place of its state's icon.
    public string? Initials { get; init; }

    /// What its panel can ask its source to do to it, in its menu; the first is what pressing it does. None for a row
    /// that opens nothing.
    public IReadOnlyList<PanelCommand> Commands { get; init; } = [];

    /// More about it than the row shows, for its tooltip.
    public string? ToolTip { get; init; }

    /// How far it's indented under the row it belongs with, such as a Copilot session under the one that started it.
    public int Depth { get; init; }

    /// Something related, named on the row, which it opens.
    public RowTag? Tag { get; init; }

    /// How full it is, such as a Copilot session's context window.
    public RowMeter? Meter { get; init; }

    /// What's left before it's done, and what's done, on a line under it, such as what's left before you can complete one
    /// of your pull requests.
    public RowChecklist? Checklist { get; init; }
}
