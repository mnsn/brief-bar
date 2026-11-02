namespace BriefBar.Core.Teams;

/// A chat as a section lists it: its ID, kind and names; its unread messages, oldest first; its newest message; when it
/// was last active; and whether you marked it unread in Teams, which makes it unread even without unread messages. The
/// Mac's `ConversationSummary`, which can't know the last.
public sealed record ConversationSummary(
    string Id,
    ConversationKind Kind,
    string Title,
    string? FullTitle,
    IReadOnlyList<TeamsMessage> Unread,
    TeamsMessage? Latest,
    DateTimeOffset? LastActivity,
    bool IsMarkedUnread = false)
{
    public ChatGroup Group => ConversationIds.Group(kind: Kind);

    public bool IsUnread => Unread.Count > 0 || IsMarkedUnread;

    /// Marked unread in Teams, without a message someone else wrote since: what its row says instead of a message.
    public bool IsOnlyMarkedUnread => IsMarkedUnread && Unread.Count == 0;

    /// The message its row shows: its newest unread one, else its newest.
    public TeamsMessage? Shown => Unread.Count > 0 ? Unread[^1] : Latest;

    /// When its row says it was: its newest unread message's arrival, else when it was last active.
    public DateTimeOffset? Date => Unread.Count > 0 ? Unread[^1].ArrivedAt : LastActivity;

    /// Where opening it goes: in Teams, at its oldest unread message, else at its newest.
    public Uri? Link => DeepLink.To(conversation: this);
}
