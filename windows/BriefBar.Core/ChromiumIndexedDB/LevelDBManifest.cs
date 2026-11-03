using System.Text;

namespace BriefBar.Core.ChromiumIndexedDB;

/// LevelDB's MANIFEST, which CURRENT names: the version edits that made the database what it is, as the records of a log
/// (`LevelDBLog`). Applied in order, they say which tables the database holds, and which logs it hasn't put in a table
/// yet: the files LevelDB reads as it opens the database. It removes the others once it no longer needs them, but one it
/// couldn't remove yet holds writes that compaction has since dropped, deletions included. The Mac's `LevelDBManifest`.
public static class LevelDBManifest
{
    public const string CurrentFile = "CURRENT";

    const string NamePrefix = "MANIFEST-";
    /// LevelDB's levels, 0 to 6.
    const uint Levels = 7;

    const uint Comparator = 1;
    const uint LogNumber = 2;
    const uint NextFileNumber = 3;
    const uint LastSequence = 4;
    const uint CompactPointer = 5;
    const uint DeletedFile = 6;
    const uint NewFile = 7;
    const uint PrevLogNumber = 9;

    /// The MANIFEST's name from CURRENT, which holds it then a newline. Throws `FormatErrorException` for anything but
    /// `MANIFEST-<number>`, which LevelDB writes, so that it can't name a file elsewhere.
    public static string Name(byte[] current)
    {
        ArgumentNullException.ThrowIfNull(argument: current);
        if (current is not [.. var name, (byte)'\n']
            || name.Length <= NamePrefix.Length
            || Encoding.ASCII.GetString(bytes: name, index: 0, count: NamePrefix.Length) != NamePrefix
            || !name[NamePrefix.Length..].All(predicate: digit => digit is >= (byte)'0' and <= (byte)'9'))
        {
            throw FormatErrorException.Corrupt(what: "CURRENT");
        }
        return Encoding.ASCII.GetString(bytes: name);
    }

    /// The version that `bytes`, a MANIFEST, leaves the database at. An edit at the end that isn't all there yet, as one
    /// LevelDB is still writing, is left out. Throws `FormatErrorException` where LevelDB would refuse to open the
    /// database: for a damaged record, the last one included, an edit it doesn't understand, or no log, next file or last
    /// sequence number.
    public static LevelDBVersion Parse(byte[] bytes)
    {
        ArgumentNullException.ThrowIfNull(argument: bytes);
        var files = new HashSet<(uint Level, ulong Number)>();
        ulong? logNumber = null;
        ulong prevLogNumber = 0;
        var hasNextFile = false;
        var hasLastSequence = false;

        // Deletions first, then additions, as LevelDB applies an edit: a table moved to the next level is both.
        void Apply(ByteReader edit)
        {
            var deleted = new List<(uint Level, ulong Number)>();
            var added = new List<(uint Level, ulong Number)>();
            while (!edit.IsAtEnd)
            {
                switch (edit.ReadVarint32())
                {
                    case Comparator:
                        edit.Skip(count: edit.ReadCount());
                        break;
                    case LogNumber:
                        logNumber = edit.ReadVarint();
                        break;
                    case NextFileNumber:
                        _ = edit.ReadVarint();
                        hasNextFile = true;
                        break;
                    case LastSequence:
                        _ = edit.ReadVarint();
                        hasLastSequence = true;
                        break;
                    case CompactPointer:
                        _ = Level(edit: edit);
                        SkipInternalKey(edit: edit);
                        break;
                    case DeletedFile:
                        deleted.Add(item: (Level(edit: edit), edit.ReadVarint()));
                        break;
                    case NewFile:
                        var level = Level(edit: edit);
                        var number = edit.ReadVarint();
                        _ = edit.ReadVarint(); // Its size,
                        SkipInternalKey(edit: edit); // its smallest key
                        SkipInternalKey(edit: edit); // and its largest.
                        added.Add(item: (level, number));
                        break;
                    case PrevLogNumber:
                        prevLogNumber = edit.ReadVarint();
                        break;
                    default:
                        throw FormatErrorException.Corrupt(what: "version edit");
                }
            }
            files.ExceptWith(other: deleted);
            files.UnionWith(other: added);
        }

        // As LevelDB does, a damaged last record counts as one, rather than one that may still be being written: going by
        // the version before it would read tables that edit removed, perhaps only some of them. One LevelDB is still
        // writing changes as it finishes it, so a later read gets past it.
        var (_, corrupt) = LevelDBLog.Records(
            bytes: bytes,
            fileOffset: 0,
            damagedEndIsCorrupt: true,
            record: edit => Apply(edit: new ByteReader(bytes: edit.ToArray())));
        if (corrupt > 0 || logNumber is not { } log || !hasNextFile || !hasLastSequence)
        {
            throw FormatErrorException.Corrupt(what: "manifest");
        }
        return new LevelDBVersion(
            Tables: files.Select(selector: file => file.Number).ToHashSet(),
            LogNumber: log,
            PrevLogNumber: prevLogNumber);
    }

    static uint Level(ByteReader edit)
    {
        var level = edit.ReadVarint32();
        return level < Levels ? level : throw FormatErrorException.Corrupt(what: "version edit");
    }

    /// A key with its sequence number and kind, which LevelDB requires not to be empty.
    static void SkipInternalKey(ByteReader edit)
    {
        var count = edit.ReadCount();
        if (count == 0)
        {
            throw FormatErrorException.Corrupt(what: "version edit");
        }
        edit.Skip(count: count);
    }
}
