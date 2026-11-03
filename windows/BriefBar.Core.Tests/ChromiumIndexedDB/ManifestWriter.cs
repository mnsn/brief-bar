using System.Globalization;
using System.Text;

namespace BriefBar.Core.Tests.ChromiumIndexedDB;

/// Writes LevelDB's MANIFEST as LevelDB does, its version edits as the records of a log, and CURRENT, which names it. The
/// Mac's test support's `ManifestWriter`.
internal static class ManifestWriter
{
    /// A version edit: the comparator's name, as LevelDB's first edit has; the log LevelDB replays from; the next file
    /// number and the last sequence number, which every edit LevelDB writes has; and the tables it removes and adds, at
    /// `level`.
    public static byte[] Edit(
        string? comparator = null,
        ulong? logNumber = null,
        ulong? nextFile = null,
        ulong? lastSequence = null,
        IReadOnlyList<ulong>? deleted = null,
        IReadOnlyList<ulong>? added = null,
        uint level = 0)
    {
        var edit = new List<byte>();
        if (comparator is not null)
        {
            edit.AddRange(collection: [.. Encodings.Varint(value: 1), .. Encodings.Varint(value: (ulong)comparator.Length), .. Encoding.ASCII.GetBytes(s: comparator)]);
        }
        if (logNumber is { } log)
        {
            edit.AddRange(collection: [.. Encodings.Varint(value: 2), .. Encodings.Varint(value: log)]);
        }
        if (nextFile is { } next)
        {
            edit.AddRange(collection: [.. Encodings.Varint(value: 3), .. Encodings.Varint(value: next)]);
        }
        if (lastSequence is { } sequence)
        {
            edit.AddRange(collection: [.. Encodings.Varint(value: 4), .. Encodings.Varint(value: sequence)]);
        }
        foreach (var number in deleted ?? [])
        {
            edit.AddRange(collection: [.. Encodings.Varint(value: 6), .. Encodings.Varint(value: level), .. Encodings.Varint(value: number)]);
        }
        foreach (var number in added ?? [])
        {
            // Its size, and its smallest and largest keys, which reading the folder doesn't need.
            var smallest = TableWriter.InternalKey(key: [0], sequence: 1, deleted: false);
            var largest = TableWriter.InternalKey(key: [0xFF], sequence: 1, deleted: false);
            edit.AddRange(collection: [.. Encodings.Varint(value: 7), .. Encodings.Varint(value: level), .. Encodings.Varint(value: number), .. Encodings.Varint(value: 1_000)]);
            edit.AddRange(collection: [.. Encodings.Varint(value: (ulong)smallest.Length), .. smallest, .. Encodings.Varint(value: (ulong)largest.Length), .. largest]);
        }
        return [.. edit];
    }

    /// The MANIFEST holding `edits`, as LevelDB writes it.
    public static byte[] Manifest(params byte[][] edits)
    {
        var log = new LogWriter();
        foreach (var edit in edits)
        {
            log.Add(batch: edit);
        }
        return log.Bytes;
    }

    /// Writes `edits` as MANIFEST-`number` in `folder`, then CURRENT, which names it, as LevelDB does as it opens a
    /// database: through a file it renames, so that CURRENT is never seen half written. Returns the MANIFEST's name.
    public static string Save(string folder, ulong number, params byte[][] edits)
    {
        var name = "MANIFEST-" + number.ToString(format: "D6", provider: CultureInfo.InvariantCulture);
        File.WriteAllBytes(path: Path.Combine(path1: folder, path2: name), bytes: Manifest(edits: edits));
        var temporary = Path.Combine(path1: folder, path2: number.ToString(format: "D6", provider: CultureInfo.InvariantCulture) + ".dbtmp");
        File.WriteAllBytes(path: temporary, bytes: Encoding.ASCII.GetBytes(s: name + "\n"));
        File.Move(sourceFileName: temporary, destFileName: Path.Combine(path1: folder, path2: "CURRENT"), overwrite: true);
        return name;
    }
}
