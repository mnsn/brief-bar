namespace BriefBar.Core.Teams;

/// A chat message, from Teams' own data: its chat, its ID (when it arrived, in milliseconds since 1970), who sent it and
/// whether that's you, Teams' type for it (`RichText/Html`, `Text`, `Event/Call`…), its text on one line, and when it
/// arrived.
public sealed record TeamsMessage(
    string ConversationId,
    long Id,
    string? Sender,
    bool IsFromMe,
    string Type,
    string Text,
    DateTimeOffset ArrivedAt)
{
    /// Whether it's something someone wrote, which can be unread, rather than a call, a recording or a change to the
    /// chat, which Teams lists but doesn't count.
    public bool IsContent => TeamsMessageTypes.IsContent(type: Type);
}
