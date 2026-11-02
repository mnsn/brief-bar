namespace BriefBar.Core.Teams;

/// A chat as BriefBar reads it from Teams' own data: its ID and kind; its name, and a longer one when Teams has one, such
/// as all its members' names; how far you've read it in Teams; its newest message; whether you've muted it; and, when
/// you marked it unread in Teams, the message it was marked unread after, and when (Teams' `consumptionHorizonBookmark`,
/// which Mark as unread sets, leaving the read marker as it was).
public sealed record TeamsChat(
    string Id,
    ConversationKind Kind,
    string Title,
    string? FullTitle,
    ReadMarker? Marker,
    TeamsMessage? Newest,
    bool IsMuted,
    ReadMarker? MarkedUnread = null);
