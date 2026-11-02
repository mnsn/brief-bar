namespace BriefBar.Core.Teams;

/// A chat you marked read in BriefBar: up to which message, and when. It reads the chat up to that message, and a Mark as
/// unread that Teams had then, until Teams' own marker gets there and the chat isn't marked unread before it anymore.
public sealed record TeamsReadMark(long UpTo, DateTimeOffset At)
{
    /// Whether it reads `markedUnread`, Teams' Mark as unread: one made before it was. One without a time, which Teams
    /// doesn't write, counts as made before.
    public bool Dismisses(ReadMarker markedUnread)
    {
        ArgumentNullException.ThrowIfNull(argument: markedUnread);
        return (markedUnread.ReadAt ?? DateTimeOffset.MinValue) <= At;
    }
}
