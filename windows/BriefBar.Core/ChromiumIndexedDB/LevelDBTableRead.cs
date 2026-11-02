namespace BriefBar.Core.ChromiumIndexedDB;

/// What reading a LevelDB table gave: the entries kept, how many blocks were read and skipped, and whether each block
/// read ended at the key its index entry names, as LevelDB's own comparator leaves it (null when no block was read):
/// skipping blocks by their index keys relies on it. The Mac's `LevelDBTable.Read`.
public sealed record LevelDBTableRead(IReadOnlyList<LevelDBEntry> Entries, int BlocksRead, int BlocksSkipped, bool? SeparatorsExact);
