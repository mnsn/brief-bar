namespace BriefBar.Core.ChromiumIndexedDB;

/// Where a block is in a table file, and how long it is, without its trailer.
internal readonly record struct LevelDBBlockHandle(long Offset, int Size);
