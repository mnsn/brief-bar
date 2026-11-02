namespace BriefBar.Core.Teams;

/// A chat's unread messages, oldest first, and whether you marked it unread in Teams, which makes it unread even
/// without any.
public sealed record ChatUnread(IReadOnlyList<TeamsMessage> Messages, bool IsMarkedUnread)
{
    public static ChatUnread None { get; } = new(Messages: [], IsMarkedUnread: false);

    public bool IsUnread => Messages.Count > 0 || IsMarkedUnread;
}
