namespace BriefBar.Core.Teams;

/// What reading Teams' message cache gave: the messages of each chat it has any of, oldest first; the chats whose
/// messages it couldn't all read, which may have more unread than it found; the chats to read again at the next change,
/// as when a table that may only be being written kept it from reading them; and the chats with a message whose blob
/// entry, which Chromium writes after it, hadn't been written yet.
internal sealed record TeamsMessagesRead(
    Dictionary<string, List<TeamsMessage>> Messages,
    HashSet<string> Incomplete,
    HashSet<string> Retry,
    HashSet<string> AwaitingBlobEntry);
