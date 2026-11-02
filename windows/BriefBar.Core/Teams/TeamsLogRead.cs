namespace BriefBar.Core.Teams;

/// What reading on in a folder's log found.
internal enum TeamsLogRead
{
    /// Nothing new about chats.
    Unchanged,

    /// A chat changed, or a message arrived in one being watched.
    Changed,

    /// The log was replaced, or databases or object stores changed: read the folder again from scratch.
    Rescan,
}
