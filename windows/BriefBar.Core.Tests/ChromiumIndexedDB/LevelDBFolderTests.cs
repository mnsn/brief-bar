using BriefBar.Core.ChromiumIndexedDB;
using BriefBar.Core.Tests.Copilot;

namespace BriefBar.Core.Tests.ChromiumIndexedDB;

/// The Mac's `LevelDBFolderTests`: a folder of tables and logs, read as it is.
public sealed class LevelDBFolderTests
{
    [Fact]
    public void TakesTheNewestWriteOfEachKey()
    {
        using var folder = new TemporaryFolder();
        List<TableEntry> older =
        [
            new(Key: Encodings.Utf8(text: "a"), Sequence: 1, Value: Encodings.Utf8(text: "a1")),
            new(Key: Encodings.Utf8(text: "b"), Sequence: 2, Value: Encodings.Utf8(text: "b1")),
            new(Key: Encodings.Utf8(text: "c"), Sequence: 3, Value: Encodings.Utf8(text: "c1")),
        ];
        File.WriteAllBytes(path: folder.Combine("000004.ldb"), bytes: TableWriter.Table(entries: older));
        var log = new LogWriter();
        log.Add(batch: LogWriter.Batch(sequence: 5, (Encodings.Utf8(text: "b"), Encodings.Utf8(text: "b2")), (Encodings.Utf8(text: "c"), null)));
        File.WriteAllBytes(path: folder.Combine("000006.log"), bytes: log.Bytes);
        // An older log, which a flush hasn't removed yet.
        var stale = new LogWriter();
        stale.Add(batch: LogWriter.Batch(sequence: 4, (Encodings.Utf8(text: "a"), Encodings.Utf8(text: "a0"))));
        File.WriteAllBytes(path: folder.Combine("000003.log"), bytes: stale.Bytes);

        var read = new LevelDBFolder(path: folder.Path).Read();

        var values = read.Values.ToDictionary(keySelector: pair => System.Text.Encoding.UTF8.GetString(bytes: pair.Key), elementSelector: pair => System.Text.Encoding.UTF8.GetString(bytes: pair.Value));
        Assert.Equal(expected: new Dictionary<string, string> { ["a"] = "a0", ["b"] = "b2" }, actual: values);
        Assert.Null(@object: read.Latest[Encodings.Utf8(text: "c")].Value);
        Assert.Equal(expected: 1, actual: read.Tables);
        Assert.Equal(expected: 2, actual: read.Logs);
        Assert.Equal(expected: "000006.log", actual: Path.GetFileName(path: read.Log?.Path));
        Assert.Equal(expected: log.Bytes.Length, actual: read.Log?.Offset);
        Assert.Empty(collection: read.Unreadable);
        Assert.False(condition: read.Vanished);
    }

    [Fact]
    public void ReadsEveryBlockWhenIndexKeysArentTheLastKeys()
    {
        using var folder = new TemporaryFolder();
        var entries = Enumerable.Range(start: 0, count: 6)
            .Select(selector: index => new TableEntry(Key: [(byte)(index * 10)], Sequence: (ulong)(index + 1), Value: [(byte)index]))
            .ToList();
        // Index keys past each block's last key, as a comparator that shortens them could leave: [15], [35], [55].
        var table = TableWriter.Table(entries: entries, perBlock: 2, indexKey: last => [(byte)(last[0] + 5), .. last[1..]]);
        File.WriteAllBytes(path: folder.Combine("000004.ldb"), bytes: table);

        // Skips the second block by its index key alone.
        var read = new LevelDBFolder(path: folder.Path).Read(mayHold: (_, upper) => !upper.AsSpan().SequenceEqual(other: new byte[] { 35 }));

        Assert.Equal(expected: 6, actual: read.Values.Count);
    }

    [Fact]
    public void ReportsATableItCantRead()
    {
        using var folder = new TemporaryFolder();
        File.WriteAllBytes(path: folder.Combine("000004.ldb"), bytes: [0, 1, 2]);
        var log = new LogWriter();
        log.Add(batch: LogWriter.Batch(sequence: 1, ([1], [2])));
        File.WriteAllBytes(path: folder.Combine("000005.log"), bytes: log.Bytes);

        var read = new LevelDBFolder(path: folder.Path).Read();

        Assert.Equal(expected: new Dictionary<string, FormatError> { ["000004.ldb"] = FormatError.Corrupt(what: "table footer") }, actual: read.Unreadable);
        Assert.Equal(expected: [2], actual: read.Values[[1]]);
        Assert.Single(collection: read.Values);
    }

    /// Reading the log leaves it open for nobody: LevelDB can delete or rename it right after.
    [Fact]
    public void HoldsNoFileOpenOnceItsRead()
    {
        using var folder = new TemporaryFolder();
        File.WriteAllBytes(path: folder.Combine("000004.ldb"), bytes: TableWriter.Table(entries: [new TableEntry(Key: [1], Sequence: 1, Value: [1])]));
        var log = new LogWriter();
        log.Add(batch: LogWriter.Batch(sequence: 2, ([2], [2])));
        File.WriteAllBytes(path: folder.Combine("000005.log"), bytes: log.Bytes);

        _ = new LevelDBFolder(path: folder.Path).Read();

        // Opening a file for writing without sharing fails while anything else holds it open.
        using (File.Open(path: folder.Combine("000004.ldb"), mode: FileMode.Open, access: FileAccess.ReadWrite, share: FileShare.None))
        {
        }
        using (File.Open(path: folder.Combine("000005.log"), mode: FileMode.Open, access: FileAccess.ReadWrite, share: FileShare.None))
        {
        }
    }

    /// Of the tables and logs in the folder, the database's are those its MANIFEST lists. LevelDB removes the others once
    /// it no longer needs them, but one it couldn't remove yet holds writes that compaction has since dropped, deletions
    /// included: read, it would bring back a key that was deleted.
    [Fact]
    public void ReadsOnlyTheTablesAndLogsTheManifestLists()
    {
        using var folder = new TemporaryFolder();
        // Log 3 wrote "a", "b" and "x", and a flush put them in table 5; log 6 then deleted "a" and "x" and wrote "c", and a
        // flush put that in table 7. Compaction merged tables 5 and 7 into table 9 and, at the last level, dropped the
        // deleted keys. Log 3 and table 5 are left behind; log 8 is the one LevelDB writes to now.
        var flushed = new LogWriter();
        flushed.Add(batch: LogWriter.Batch(sequence: 1, (Encodings.Utf8(text: "a"), Encodings.Utf8(text: "a1")), (Encodings.Utf8(text: "b"), Encodings.Utf8(text: "b1")), (Encodings.Utf8(text: "x"), Encodings.Utf8(text: "x1"))));
        File.WriteAllBytes(path: folder.Combine("000003.log"), bytes: flushed.Bytes);
        File.WriteAllBytes(path: folder.Combine("000005.ldb"), bytes: TableWriter.Table(entries: Entries(("a", 1), ("b", 2), ("x", 3))));
        File.WriteAllBytes(path: folder.Combine("000009.ldb"), bytes: TableWriter.Table(entries: Entries(("b", 2), ("c", 6))));
        var current = new LogWriter();
        current.Add(batch: LogWriter.Batch(sequence: 7, (Encodings.Utf8(text: "d"), Encodings.Utf8(text: "d1"))));
        File.WriteAllBytes(path: folder.Combine("000008.log"), bytes: current.Bytes);
        ManifestWriter.Save(
            folder: folder.Path,
            number: 2,
            ManifestWriter.Edit(comparator: "idb_cmp1", logNumber: 3, nextFile: 4, lastSequence: 0),
            ManifestWriter.Edit(logNumber: 6, nextFile: 7, lastSequence: 3, added: [5]),
            ManifestWriter.Edit(logNumber: 8, nextFile: 9, lastSequence: 6, added: [7]),
            ManifestWriter.Edit(logNumber: 8, nextFile: 10, lastSequence: 7, deleted: [5, 7], added: [9]));

        var read = new LevelDBFolder(path: folder.Path).Read();

        Assert.Equal(expected: new Dictionary<string, string> { ["b"] = "b1", ["c"] = "c1", ["d"] = "d1" }, actual: Texts(read: read));
        Assert.Equal(expected: (1, 1, 2), actual: (read.Tables, read.Logs, read.Unlisted));
        Assert.Equal(expected: "000008.log", actual: Path.GetFileName(path: read.Log?.Path));
        Assert.Empty(collection: read.Unreadable);
        Assert.False(condition: read.Vanished);
    }

    /// LevelDB writes a table, then lists it: one it's still writing reads as broken, but isn't the database's yet.
    [Fact]
    public void LeavesOutATableLevelDBIsStillWriting()
    {
        using var folder = new TemporaryFolder();
        File.WriteAllBytes(path: folder.Combine("000005.ldb"), bytes: TableWriter.Table(entries: Entries(("a", 1))));
        File.WriteAllBytes(path: folder.Combine("000007.ldb"), bytes: Enumerable.Repeat(element: (byte)7, count: 100).ToArray());
        ManifestWriter.Save(folder: folder.Path, number: 2, ManifestWriter.Edit(logNumber: 6, nextFile: 8, lastSequence: 1, added: [5]));

        var read = new LevelDBFolder(path: folder.Path).Read();

        Assert.Equal(expected: new Dictionary<string, string> { ["a"] = "a1" }, actual: Texts(read: read));
        Assert.Equal(expected: (1, 1), actual: (read.Tables, read.Unlisted));
        Assert.Empty(collection: read.Unreadable);
    }

    /// A table the MANIFEST lists, missing as the folder is read, as when compaction writes it and removes others
    /// meanwhile, makes it start over; still missing, the read says what it holds may be missing.
    [Fact]
    public void SaysWhenATableTheManifestListsIsMissing()
    {
        using var folder = new TemporaryFolder();
        File.WriteAllBytes(path: folder.Combine("000005.ldb"), bytes: TableWriter.Table(entries: Entries(("a", 1))));
        ManifestWriter.Save(folder: folder.Path, number: 2, ManifestWriter.Edit(logNumber: 6, nextFile: 10, lastSequence: 1, added: [5, 9]));

        var read = new LevelDBFolder(path: folder.Path).Read();

        Assert.True(condition: read.Vanished);
        Assert.Equal(expected: new Dictionary<string, string> { ["a"] = "a1" }, actual: Texts(read: read));
    }

    /// Without the MANIFEST, it can't tell which files are the database's: it reads them all, and says the MANIFEST
    /// couldn't be read, or that it vanished.
    [Fact]
    public void ReadsEveryFileWhenTheManifestCantBeRead()
    {
        using var folder = new TemporaryFolder();
        File.WriteAllBytes(path: folder.Combine("000005.ldb"), bytes: TableWriter.Table(entries: Entries(("a", 1))));
        File.WriteAllBytes(path: folder.Combine("000009.ldb"), bytes: TableWriter.Table(entries: Entries(("b", 2))));
        var name = ManifestWriter.Save(
            folder: folder.Path,
            number: 2,
            ManifestWriter.Edit(logNumber: 6, nextFile: 10, lastSequence: 2, added: [9]),
            [.. Encodings.Varint(value: 8), .. Encodings.Varint(value: 1)]);
        var everything = new Dictionary<string, string> { ["a"] = "a1", ["b"] = "b1" };

        var unknown = new LevelDBFolder(path: folder.Path).Read();
        Assert.Equal(expected: new Dictionary<string, FormatError> { [name] = FormatError.Corrupt(what: "version edit") }, actual: unknown.Unreadable);
        Assert.Equal(expected: everything, actual: Texts(read: unknown));
        Assert.Equal(expected: 0, actual: unknown.Unlisted);

        File.WriteAllBytes(path: folder.Combine(LevelDBManifest.CurrentFile), bytes: Encodings.Utf8(text: "../" + name + "\n"));
        var elsewhere = new LevelDBFolder(path: folder.Path).Read();
        Assert.Equal(expected: new Dictionary<string, FormatError> { [LevelDBManifest.CurrentFile] = FormatError.Corrupt(what: "CURRENT") }, actual: elsewhere.Unreadable);
        Assert.Equal(expected: everything, actual: Texts(read: elsewhere));

        File.WriteAllBytes(path: folder.Combine(LevelDBManifest.CurrentFile), bytes: Encodings.Utf8(text: "MANIFEST-000003\n"));
        var vanished = new LevelDBFolder(path: folder.Path).Read();
        Assert.True(condition: vanished.Vanished);
        Assert.Empty(collection: vanished.Unreadable);
        Assert.Equal(expected: everything, actual: Texts(read: vanished));
    }

    /// Made-up writes, each key's value its name and "1".
    static List<TableEntry> Entries(params (string Key, ulong Sequence)[] writes) => writes
        .Select(selector: write => new TableEntry(Key: Encodings.Utf8(text: write.Key), Sequence: write.Sequence, Value: Encodings.Utf8(text: write.Key + "1")))
        .ToList();

    static Dictionary<string, string> Texts(LevelDBFolderRead read) => read.Values.ToDictionary(
        keySelector: pair => System.Text.Encoding.UTF8.GetString(bytes: pair.Key),
        elementSelector: pair => System.Text.Encoding.UTF8.GetString(bytes: pair.Value));
}
