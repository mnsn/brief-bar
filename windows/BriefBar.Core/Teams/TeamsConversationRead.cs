namespace BriefBar.Core.Teams;

/// A conversation record as a folder read it: the chat it holds (null for one that isn't a chat, or can't be read), the
/// account it's in, how its value was written, and why it couldn't be read, if it couldn't.
internal sealed record TeamsConversationRead(TeamsChat? Chat, string? Account, string? Format, string? Unreadable);
