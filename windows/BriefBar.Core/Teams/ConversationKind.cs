namespace BriefBar.Core.Teams;

/// What kind of chat a conversation is. The Mac's `ConversationKind`, without channels, which BriefBar doesn't show.
public enum ConversationKind
{
    OneOnOne,
    Group,
    Meeting,
}
