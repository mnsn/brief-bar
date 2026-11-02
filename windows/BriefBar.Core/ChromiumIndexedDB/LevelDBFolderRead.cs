namespace BriefBar.Core.ChromiumIndexedDB;

/// What reading a LevelDB folder gave: the newest write to each key read (a value, or null once the key was deleted),
/// what was read and skipped, the files that couldn't be read, by name, and why, and where reading the newest log
/// stopped. The Mac's `LevelDBFolder.Read`.
public sealed class LevelDBFolderRead
{
    public Dictionary<byte[], LevelDBEntry> Latest { get; } = new(comparer: ByteSequenceComparer.Instance);

    public int Tables { get; set; }

    public int Logs { get; set; }

    public int BlocksRead { get; set; }

    public int BlocksSkipped { get; set; }

    public int CorruptLogRecords { get; set; }

    public Dictionary<string, FormatError> Unreadable { get; } = new(comparer: StringComparer.Ordinal);

    public LevelDBLogPosition? Log { get; set; }

    /// Files vanished as they were read, on every attempt, as when compaction kept replacing them: what they held may be
    /// missing.
    public bool Vanished { get; set; }

    /// The keys that have a value, with it.
    public Dictionary<byte[], byte[]> Values => Latest
        .Where(predicate: pair => pair.Value.Value is not null)
        .ToDictionary(keySelector: pair => pair.Key, elementSelector: pair => pair.Value.Value!, comparer: ByteSequenceComparer.Instance);

    /// Takes in writes, keeping the newest of each key.
    public void Take(IEnumerable<LevelDBEntry> entries)
    {
        ArgumentNullException.ThrowIfNull(argument: entries);
        foreach (var entry in entries)
        {
            if (!Latest.TryGetValue(key: entry.Key, value: out var known) || entry.Sequence >= known.Sequence)
            {
                Latest[entry.Key] = entry;
            }
        }
    }
}
