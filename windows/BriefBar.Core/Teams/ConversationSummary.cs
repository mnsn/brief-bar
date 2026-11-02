namespace BriefBar.Core.Teams;

/// A chat as a section lists it: its ID, kind and names; its unread messages, oldest first; its newest message; and when
/// it was last active. The Mac's `ConversationSummary`.
public sealed record ConversationSummary(
    string Id,
    ConversationKind Kind,
    string Title,
    string? FullTitle,
    IReadOnlyList<TeamsMessage> Unread,
    TeamsMessage? Latest,
    DateTimeOffset? LastActivity)
{
    public ChatGroup Group => ConversationIds.Group(kind: Kind);

    public bool IsUnread => Unread.Count > 0;

    /// The message its row shows: its newest unread one, else its newest.
    public TeamsMessage? Shown => IsUnread ? Unread[^1] : Latest;

    /// When its row says it was: its newest unread message's arrival, else when it was last active.
    public DateTimeOffset? Date => IsUnread ? Unread[^1].ArrivedAt : LastActivity;

    /// Where opening it goes: in Teams, at its oldest unread message, else at its newest.
    public Uri? Link => DeepLink.To(conversation: this);
}
