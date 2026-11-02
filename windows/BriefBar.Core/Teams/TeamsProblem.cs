namespace BriefBar.Core.Teams;

/// What keeps BriefBar from showing your Teams chats as they are, as the panel explains it.
public enum TeamsProblem
{
    /// There's no data of Teams' on this PC: the new Teams app isn't installed, or nobody has signed in to it.
    NotFound,

    /// Teams' data was found, but not understood, as after an update that changed it.
    DataChanged,

    /// Some of Teams' data couldn't be read: some chats may be missing.
    PartlyUnreadable,

    /// Reading failed in a way BriefBar doesn't expect.
    ReadFailed,
}
