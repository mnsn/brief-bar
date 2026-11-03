namespace BriefBar.Core.ChromiumIndexedDB;

/// The database as LevelDB's MANIFEST says it is: the numbers of the tables it holds, and the log it replays from, the
/// oldest it hasn't put in a table yet, with an older one it may still need (0 when there's none). The Mac's
/// `LevelDBManifest.Version`.
public sealed record LevelDBVersion(IReadOnlySet<ulong> Tables, ulong LogNumber, ulong PrevLogNumber)
{
    /// Whether the log `number` is one LevelDB replays as it opens the database, and so keeps.
    public bool IsLiveLog(ulong number) => number >= LogNumber || number == PrevLogNumber;
}
