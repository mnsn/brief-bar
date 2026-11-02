using System.Globalization;

namespace BriefBar.Core.ChromiumIndexedDB;

/// A LevelDB database's folder, read as it is, without taking its lock: LevelDB never changes a table once written and
/// only appends to its log, so taking, for each key, the write with the highest sequence number gives the database as it
/// was when the read ended. Only the tables and logs its MANIFEST lists are read (`LevelDBManifest`). Nothing is
/// written, nothing copied, and no file stays open once it's read. The Mac's `LevelDBFolder`.
public sealed class LevelDBFolder(string path)
{
    /// How many times a read starts over when files vanish as it reads them.
    const int Attempts = 3;

    public string Path { get; } = path;

    /// Reads the folder's tables and logs, keeping the writes to keys that `keep` accepts, from the table blocks that
    /// `mayHold` doesn't rule out (see `LevelDBTable.Read`). A table that compaction removes while it's read, or adds,
    /// makes it start over, since its keys are in another table then, up to three times; after that, the read says files
    /// vanished (`LevelDBFolderRead.Vanished`). Where there's no CURRENT, as in made-up data, it reads every table and
    /// log; so it does when the MANIFEST can't be read, or LevelDB would refuse it, which it says: as when, at the last
    /// attempt, CURRENT still names a MANIFEST that isn't there, or the MANIFEST a table that isn't. Throws
    /// `IOException` when the folder can't be listed, as when it's gone.
    public LevelDBFolderRead Read(Func<byte[]?, byte[], bool>? mayHold = null, Func<ArraySegment<byte>, bool>? keep = null)
    {
        mayHold ??= (_, _) => true;
        keep ??= _ => true;
        var read = new LevelDBFolderRead();
        for (var attempt = 1; attempt <= Attempts; attempt++)
        {
            (read, var vanished) = Attempt(mayHold: mayHold, keep: keep, isLastAttempt: attempt == Attempts);
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

    (LevelDBFolderRead Read, bool Vanished) Attempt(Func<byte[]?, byte[], bool> mayHold, Func<ArraySegment<byte>, bool> keep, bool isLastAttempt)
    {
        var names = Names(folder: Path);
        var read = new LevelDBFolderRead();
        var (version, vanished) = Version(names: names, read: read, isLastAttempt: isLastAttempt);
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

        var tableNames = names.Where(predicate: IsTable).ToList();
        var logs = Logs(names: names);
        if (version is not null)
        {
            var liveTables = tableNames.Where(predicate: name => Number(name: name) is { } number && version.Tables.Contains(item: number)).ToList();
            var liveLogs = logs.Where(predicate: log => version.IsLiveLog(number: log.Number)).ToList();
            read.Unlisted = tableNames.Count - liveTables.Count + logs.Count - liveLogs.Count;
            (tableNames, logs) = (liveTables, liveLogs);
        }
        foreach (var name in tableNames)
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

    /// What the folder's MANIFEST says the database is, and whether files vanished as it was read: the MANIFEST that
    /// CURRENT names, as when LevelDB replaced it, or a table it lists that the folder didn't have as it was listed, as
    /// when LevelDB wrote one since. Null, to read every table and log, when the folder has no CURRENT, or when the
    /// MANIFEST can't be read or LevelDB would refuse it, which `read` says: as when, at the last attempt, either is still
    /// missing, since LevelDB refuses a database with files missing.
    (LevelDBVersion? Version, bool Vanished) Version(List<string> names, LevelDBFolderRead read, bool isLastAttempt)
    {
        if (!names.Contains(item: LevelDBManifest.CurrentFile))
        {
            return (null, false);
        }
        var file = LevelDBManifest.CurrentFile;
        try
        {
            var (current, _) = Contents(path: System.IO.Path.Combine(path1: Path, path2: file));
            file = LevelDBManifest.Name(current: current);
            var (manifest, _) = Contents(path: System.IO.Path.Combine(path1: Path, path2: file));
            var version = LevelDBManifest.Parse(bytes: manifest);
            if (version.Tables.IsSubsetOf(other: names.Where(predicate: IsTable).Select(selector: Number).OfType<ulong>()))
            {
                return (version, false);
            }
            if (!isLastAttempt)
            {
                return (version, true);
            }
            read.Unreadable[file] = FormatError.Corrupt(what: "manifest");
        }
        catch (FormatErrorException error)
        {
            read.Unreadable[file] = error.Error;
        }
        catch (IOException error) when (error is FileNotFoundException or DirectoryNotFoundException)
        {
            if (!isLastAttempt)
            {
                return (null, true);
            }
            read.Unreadable[LevelDBManifest.CurrentFile] = FormatError.Corrupt(what: LevelDBManifest.CurrentFile);
        }
        catch (IOException)
        {
            read.Unreadable[file] = FormatError.Unsupported(what: "file");
        }
        catch (UnauthorizedAccessException)
        {
            read.Unreadable[file] = FormatError.Unsupported(what: "file");
        }
        return (null, false);
    }

    /// The names of the files in `folder`, in order.
    static List<string> Names(string folder) => Directory.EnumerateFiles(path: folder)
        .Select(selector: file => System.IO.Path.GetFileName(path: file))
        .Order(comparer: StringComparer.Ordinal)
        .ToList();

    static bool IsTable(string name) => name.EndsWith(value: ".ldb", comparisonType: StringComparison.Ordinal)
        || name.EndsWith(value: ".sst", comparisonType: StringComparison.Ordinal);

    /// The number LevelDB named a table or a log with, as `000005.ldb`; null for a name without one.
    static ulong? Number(string name) => ulong.TryParse(
        s: System.IO.Path.GetFileNameWithoutExtension(path: name),
        style: NumberStyles.None,
        provider: CultureInfo.InvariantCulture,
        result: out var number) ? number : null;

    /// The logs among `names`, by number, oldest first.
    static List<(ulong Number, string Name)> Logs(IReadOnlyList<string> names)
    {
        var logs = new List<(ulong Number, string Name)>();
        foreach (var name in names)
        {
            if (name.EndsWith(value: ".log", comparisonType: StringComparison.Ordinal) && Number(name: name) is { } number)
            {
                logs.Add(item: (number, name));
            }
        }
        return logs.OrderBy(keySelector: log => log.Number).ToList();
    }
}
