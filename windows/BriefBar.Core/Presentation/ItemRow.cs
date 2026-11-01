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

    /// Unread messages, for a chat.
    public int Unread { get; init; }

    /// New since you last looked at it.
    public bool IsNew { get; init; }

    public IReadOnlyList<RowChip> Chips { get; init; } = [];

    /// A chat's initials, shown in place of its state's icon.
    public string? Initials { get; init; }
}
