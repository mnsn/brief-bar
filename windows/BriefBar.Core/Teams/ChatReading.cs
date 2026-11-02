namespace BriefBar.Core.Teams;

/// Which of a chat's messages are unread, decided as Teams' own list does, from Teams' data, BriefBar's own marks and Keep
/// Unread For. The Mac decides from notifications (`UnreadTracker`); Teams on Windows posts none by default, so BriefBar
/// reads Teams' own state instead.
public static class ChatReading
{
    /// Whether Teams' own data says `chat` may have messages you haven't read: its newest message isn't yours, and is newer
    /// than how far you've read it in Teams. BriefBar reads its messages then, to tell which and how many. A muted chat
    /// never needs you, as Teams doesn't notify you of it.
    public static bool MayBeUnread(TeamsChat chat)
    {
        ArgumentNullException.ThrowIfNull(argument: chat);
        return !chat.IsMuted && chat.Newest is { IsFromMe: false } newest && newest.Id > (chat.Marker?.MessageId ?? 0);
    }

    /// The messages of `chat` that are unread, oldest first: what someone else wrote, after how far you've read it in Teams,
    /// after how far you marked it read in BriefBar (`markedUpTo`), after your own newest message, and no older than
    /// `keepUnreadFor` (null keeps them until they're read). `messages` are what Teams' message cache has of it; its newest
    /// message counts too, should the cache not have it yet.
    public static IReadOnlyList<TeamsMessage> Unread(
        TeamsChat chat, IReadOnlyList<TeamsMessage> messages, long? markedUpTo, TimeSpan? keepUnreadFor, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: chat);
        ArgumentNullException.ThrowIfNull(argument: messages);
        if (!MayBeUnread(chat: chat))
        {
            return [];
        }
        var all = messages.Append(element: chat.Newest!).DistinctBy(keySelector: message => message.Id).ToList();
        var readUpTo = Math.Max(val1: chat.Marker?.MessageId ?? 0, val2: markedUpTo ?? 0);
        // Writing in a chat reads it, as Teams moves its marker to what you sent.
        var mine = all.Where(predicate: message => message.IsFromMe).Select(selector: message => message.Id).DefaultIfEmpty(defaultValue: 0).Max();
        readUpTo = Math.Max(val1: readUpTo, val2: mine);
        return all
            .Where(predicate: message => message.Id > readUpTo
                && !message.IsFromMe
                && message.IsContent
                && (keepUnreadFor is not { } keep || now - message.ArrivedAt <= keep))
            .OrderBy(keySelector: message => message.Id)
            .ToList();
    }
}
