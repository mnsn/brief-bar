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
}
