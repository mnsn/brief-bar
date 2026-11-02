using System.Globalization;

namespace BriefBar.Core.ChromiumIndexedDB;

/// A LevelDB database's folder, read as it is, without taking its lock: LevelDB never changes a table once written and
/// only appends to its log, so taking, for each key, the write with the highest sequence number gives the database as it
/// was when the read ended. Nothing is written, nothing copied, and no file stays open once it's read. The Mac's
/// `LevelDBFolder`.
public sealed class LevelDBFolder(string path)
{
    public string Path { get; } = path;

    /// Reads the folder's tables and logs, keeping the writes to keys that `keep` accepts, from the table blocks that
    /// `mayHold` doesn't rule out (see `LevelDBTable.Read`). A table that compaction removes while it's read makes it start
    /// over, since its keys are in a new table then, up to three times; after that, the read says files vanished
    /// (`LevelDBFolderRead.Vanished`). Throws `IOException` when the folder can't be listed, as when it's gone.
    public LevelDBFolderRead Read(Func<byte[]?, byte[], bool>? mayHold = null, Func<ArraySegment<byte>, bool>? keep = null)
    {
        mayHold ??= (_, _) => true;
        keep ??= _ => true;
        var read = new LevelDBFolderRead();
        for (var attempt = 0; attempt < 3; attempt++)
        {
            (read, var vanished) = Attempt(mayHold: mayHold, keep: keep);
            read.Vanished = vanished;
            if (!vanished)
            {
                break;
            }
        }
        return read;
    }

    /// A file's bytes from `offset` to its end, and which file they came from, as when it was created, from one handle, so
    /// a file put in its place meanwhile can't mix in. Throws `IOException` when it can't be read, as when it's gone.
    public static (byte[] Bytes, long FileId) Contents(string path, long offset = 0)
    {
        using var file = File.OpenHandle(
            path: path, mode: FileMode.Open, access: FileAccess.Read, share: FileShare.ReadWrite | FileShare.Delete);
        var id = File.GetCreationTimeUtc(fileHandle: file).Ticks;
        var size = RandomAccess.GetLength(handle: file);
        if (offset >= size)
        {
            return ([], id);
        }
        var bytes = new byte[size - offset];
        var read = 0;
        while (read < bytes.Length)
        {
            var got = RandomAccess.Read(handle: file, buffer: bytes.AsSpan(start: read), fileOffset: offset + read);
            if (got == 0)
            {
                break;
            }
            read += got;
        }
        return (read == bytes.Length ? bytes : bytes[..read], id);
    }

    /// The log LevelDB writes to now: the one with the highest number.
    public static string? NewestLog(string folder) => Logs(names: Names(folder: folder)).LastOrDefault().Name;

    (LevelDBFolderRead Read, bool Vanished) Attempt(Func<byte[]?, byte[], bool> mayHold, Func<ArraySegment<byte>, bool> keep)
    {
        var names = Names(folder: Path);
        var read = new LevelDBFolderRead();
        var vanished = false;
        var tables = new Dictionary<string, LevelDBTableRead>(comparer: StringComparer.Ordinal);

        void ReadTable(string name, bool skipping)
        {
            try
            {
                tables[name] = LevelDBTable.Read(
                    path: System.IO.Path.Combine(path1: Path, path2: name),
                    mayHold: (lower, upper) => !skipping || mayHold(arg1: lower, arg2: upper),
                    keep: keep);
            }
            catch (FormatErrorException error)
            {
                read.Unreadable[name] = error.Error;
            }
            catch (FileNotFoundException)
            {
                vanished = true;
            }
            catch (DirectoryNotFoundException)
            {
                vanished = true;
            }
            catch (IOException)
            {
                read.Unreadable[name] = FormatError.Unsupported(what: "file");
            }
            catch (UnauthorizedAccessException)
            {
                read.Unreadable[name] = FormatError.Unsupported(what: "file");
            }
        }

        foreach (var name in names.Where(predicate: name => name.EndsWith(value: ".ldb", comparisonType: StringComparison.Ordinal)
            || name.EndsWith(value: ".sst", comparisonType: StringComparison.Ordinal)))
        {
            ReadTable(name: name, skipping: true);
        }
        // Skipping blocks relies on index keys being the blocks' last keys. Where one isn't, read every block.
        if (tables.Values.Any(predicate: table => table.SeparatorsExact == false))
        {
            foreach (var name in tables.Where(predicate: pair => pair.Value.BlocksSkipped > 0).Select(selector: pair => pair.Key).ToList())
            {
                ReadTable(name: name, skipping: false);
            }
        }
        foreach (var table in tables.Values)
        {
            read.Tables += 1;
            read.BlocksRead += table.BlocksRead;
            read.BlocksSkipped += table.BlocksSkipped;
            read.Take(entries: table.Entries);
        }
        var logs = Logs(names: names);
        for (var index = 0; index < logs.Count; index++)
        {
            var logPath = System.IO.Path.Combine(path1: Path, path2: logs[index].Name);
            try
            {
                var (bytes, id) = Contents(path: logPath);
                var parsed = LevelDBLog.Parse(bytes: bytes, keep: keep);
                read.Logs += 1;
                read.CorruptLogRecords += parsed.Corrupt;
                read.Take(entries: parsed.Entries);
                if (index == logs.Count - 1)
                {
                    read.Log = new LevelDBLogPosition(Path: logPath, FileId: id, Offset: parsed.End);
                }
            }
            catch (FileNotFoundException)
            {
                vanished = true;
            }
            catch (DirectoryNotFoundException)
            {
                vanished = true;
            }
            catch (IOException)
            {
                read.Unreadable[logs[index].Name] = FormatError.Unsupported(what: "file");
            }
            catch (UnauthorizedAccessException)
            {
                read.Unreadable[logs[index].Name] = FormatError.Unsupported(what: "file");
            }
        }
        return (read, vanished);
    }

    /// The names of the files in `folder`, in order.
    static List<string> Names(string folder) => Directory.EnumerateFiles(path: folder)
        .Select(selector: file => System.IO.Path.GetFileName(path: file))
        .Order(comparer: StringComparer.Ordinal)
        .ToList();

    /// The logs among `names`, by number, oldest first.
    static List<(ulong Number, string Name)> Logs(IReadOnlyList<string> names)
    {
        var logs = new List<(ulong Number, string Name)>();
        foreach (var name in names)
        {
            if (name.EndsWith(value: ".log", comparisonType: StringComparison.Ordinal)
                && ulong.TryParse(s: name[..^4], style: NumberStyles.None, provider: CultureInfo.InvariantCulture, result: out var number))
            {
                logs.Add(item: (number, name));
            }
        }
        return logs.OrderBy(keySelector: log => log.Number).ToList();
    }
}
