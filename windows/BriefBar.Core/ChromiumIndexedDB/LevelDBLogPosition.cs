namespace BriefBar.Core.ChromiumIndexedDB;

/// Where reading the newest log stopped, to go on from there as LevelDB appends to it: the log's path, which file it was
/// (when it was created, as `FileStamp` tells files apart), and the offset after the last complete batch. The Mac's
/// `LevelDBFolder.LogPosition`.
public sealed record LevelDBLogPosition(string Path, long FileId, long Offset);
