namespace BriefBar.Core.Teams;

/// How long a message stays unread when you haven't read it in Teams or marked it read in BriefBar. The Mac's
/// `AppSettings.KeepUnread`.
public enum KeepUnread
{
    FourHours,
    OneDay,
    ThreeDays,
    UntilRead,
}
