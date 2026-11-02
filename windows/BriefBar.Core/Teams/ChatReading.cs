namespace BriefBar.Core.Teams;

/// Which of a chat's messages are unread, decided as Teams' own list does, from Teams' data, BriefBar's own marks and Keep
/// Unread For. The Mac decides from notifications (`UnreadTracker`); Teams on Windows posts none by default, so BriefBar
/// reads Teams' own state instead.
public static class ChatReading
{
    /// Whether Teams' own data says `chat` may be unread: its newest message isn't yours, and is newer than how far you've
    /// read it in Teams; or you marked it unread in Teams. BriefBar reads its messages then, to tell which and how many. A
    /// muted chat never needs you, as Teams doesn't notify you of it.
    public static bool MayBeUnread(TeamsChat chat)
    {
        ArgumentNullException.ThrowIfNull(argument: chat);
        return !chat.IsMuted
            && (chat.MarkedUnread is not null
                || (chat.Newest is { IsFromMe: false } newest && newest.Id > (chat.Marker?.MessageId ?? 0)));
    }

    /// What of `chat` is unread. Marked unread in Teams after you last marked it read in BriefBar (`mark`), it's unread,
    /// with what someone else wrote after where it was marked unread, until it's opened in Teams, whatever
    /// `keepUnreadFor` says, as Teams keeps it so. Otherwise its unread messages are what someone else wrote after how far
    /// you've read it in Teams, after `mark`, after your own newest message, and no older than `keepUnreadFor` (null
    /// keeps them until they're read). `messages` are what Teams' message cache has of it; its newest message counts too,
    /// should the cache not have it yet.
    public static ChatUnread Unread(
        TeamsChat chat, IReadOnlyList<TeamsMessage> messages, TeamsReadMark? mark, TimeSpan? keepUnreadFor, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: chat);
        ArgumentNullException.ThrowIfNull(argument: messages);
        if (!MayBeUnread(chat: chat))
        {
            return ChatUnread.None;
        }
        var all = chat.Newest is { } newest
            ? messages.Append(element: newest).DistinctBy(keySelector: message => message.Id).ToList()
            : messages.DistinctBy(keySelector: message => message.Id).ToList();
        if (chat.MarkedUnread is { } markedUnread && mark?.Dismisses(markedUnread: markedUnread) != true)
        {
            return new ChatUnread(
                Messages: Written(messages: all, after: markedUnread.MessageId, keepUnreadFor: null, now: now),
                IsMarkedUnread: true);
        }
        if (chat.Newest is not { IsFromMe: false } || chat.Newest.Id <= (chat.Marker?.MessageId ?? 0))
        {
            return ChatUnread.None;
        }
        var readUpTo = Math.Max(val1: chat.Marker?.MessageId ?? 0, val2: mark?.UpTo ?? 0);
        // Writing in a chat reads it, as Teams moves its marker to what you sent.
        var mine = all.Where(predicate: message => message.IsFromMe).Select(selector: message => message.Id).DefaultIfEmpty(defaultValue: 0).Max();
        readUpTo = Math.Max(val1: readUpTo, val2: mine);
        return new ChatUnread(Messages: Written(messages: all, after: readUpTo, keepUnreadFor: keepUnreadFor, now: now), IsMarkedUnread: false);
    }

    /// What someone else wrote after the message `after`, within `keepUnreadFor` if it's given, oldest first.
    static List<TeamsMessage> Written(List<TeamsMessage> messages, long after, TimeSpan? keepUnreadFor, DateTimeOffset now) => messages
        .Where(predicate: message => message.Id > after
            && !message.IsFromMe
            && message.IsContent
            && (keepUnreadFor is not { } keep || now - message.ArrivedAt <= keep))
        .OrderBy(keySelector: message => message.Id)
        .ToList();
}
