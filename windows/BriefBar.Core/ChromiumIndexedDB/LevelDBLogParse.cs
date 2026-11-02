namespace BriefBar.Core.ChromiumIndexedDB;

/// What reading a LevelDB log gave: the writes of every complete batch, in order; the file offset after the last complete
/// batch, where to go on reading once more is written; and how many records or batches were skipped because they broke
/// the format or their checksum didn't match. The Mac's `LevelDBLog.Parsed`.
public sealed record LevelDBLogParse(IReadOnlyList<LevelDBEntry> Entries, long End, int Corrupt);
