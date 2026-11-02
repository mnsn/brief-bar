using BriefBar.Core.ChromiumIndexedDB;
using BriefBar.Core.Tests.Copilot;

namespace BriefBar.Core.Tests.ChromiumIndexedDB;

/// The Mac's `LevelDBTableTests`: reading LevelDB's tables, and only the blocks asked for.
public sealed class LevelDBTableTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ReadsEveryBlock(bool compressed)
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("000005.ldb");
        File.WriteAllBytes(path: path, bytes: TableWriter.Table(entries: Entries(count: 7), perBlock: 3, compress: compressed, restartInterval: 2));
        var read = LevelDBTable.Read(path: path);

        Assert.Equal(expected: Entries(count: 7).Select(selector: entry => entry.Key), actual: read.Entries.Select(selector: entry => entry.Key));
        Assert.Equal(expected: Enumerable.Range(start: 1, count: 7).Select(selector: number => (ulong)number), actual: read.Entries.Select(selector: entry => entry.Sequence));
        Assert.Null(@object: read.Entries[3].Value);
        Assert.Equal(expected: Encodings.Utf8(text: "value 6"), actual: read.Entries[6].Value);
        Assert.Equal(expected: 3, actual: read.BlocksRead);
        Assert.Equal(expected: 0, actual: read.BlocksSkipped);
        Assert.True(condition: read.SeparatorsExact);
    }

    [Fact]
    public void SkipsBlocksOutsideTheRange()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("000005.ldb");
        File.WriteAllBytes(path: path, bytes: TableWriter.Table(entries: Entries(count: 7), perBlock: 3));
        var bounds = new List<(string? Lower, string Upper)>();
        var read = LevelDBTable.Read(path: path, mayHold: (lower, upper) =>
        {
            bounds.Add(item: (lower is null ? null : System.Text.Encoding.UTF8.GetString(bytes: lower), System.Text.Encoding.UTF8.GetString(bytes: upper)));
            return lower is not null && !upper.AsSpan().SequenceEqual(other: Encodings.Utf8(text: "key-106"));
        });

        Assert.Equal(expected: [null, "key-102", "key-105"], actual: bounds.Select(selector: bound => bound.Lower));
        Assert.Equal(expected: ["key-102", "key-105", "key-106"], actual: bounds.Select(selector: bound => bound.Upper));
        Assert.Equal(expected: [4UL, 5UL, 6UL], actual: read.Entries.Select(selector: entry => entry.Sequence));
        Assert.Equal(expected: 1, actual: read.BlocksRead);
        Assert.Equal(expected: 2, actual: read.BlocksSkipped);
    }

    [Fact]
    public void SurvivesHandlesThatWouldOverflow()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("000005.ldb");
        // Int.max / 2 for both the index block's offset and size.
        byte[] huge = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x3F];
        var footer = new List<byte> { 0, 0 };
        footer.AddRange(collection: huge);
        footer.AddRange(collection: huge);
        footer.AddRange(collection: new byte[40 - footer.Count]);
        File.WriteAllBytes(path: path, bytes: [.. new byte[100], .. footer, .. Encodings.LittleEndian(value: LevelDBTable.Magic, count: 8)]);

        AssertRefuses(path: path, error: FormatError.Corrupt(what: "block handle"));
    }

    [Fact]
    public void RefusesKeysThatAddUpToFarMoreThanTheBlock()
    {
        // One long key, then many that share all of it: each a full copy.
        var block = new List<byte>();
        block.AddRange(collection: Encodings.Varint(value: 0));
        block.AddRange(collection: Encodings.Varint(value: 100_000));
        block.AddRange(collection: Encodings.Varint(value: 0));
        block.AddRange(collection: Enumerable.Repeat(element: (byte)1, count: 100_000));
        for (var index = 0; index < 10_000; index++)
        {
            block.AddRange(collection: Encodings.Varint(value: 100_000));
            block.AddRange(collection: Encodings.Varint(value: 1));
            block.AddRange(collection: Encodings.Varint(value: 0));
            block.Add(item: 2);
        }
        block.AddRange(collection: Encodings.LittleEndian(value: 0, count: 4));
        block.AddRange(collection: Encodings.LittleEndian(value: 1, count: 4));

        var thrown = Assert.Throws<FormatErrorException>(testCode: () => LevelDBTable.BlockEntries(block: [.. block]));
        Assert.Equal(expected: FormatError.Corrupt(what: "block keys"), actual: thrown.Error);
    }

    [Fact]
    public void RefusesWhatIsntATable()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("000005.ldb");
        var table = TableWriter.Table(entries: Entries(count: 4));
        table[^1] ^= 0xFF;
        File.WriteAllBytes(path: path, bytes: table);
        AssertRefuses(path: path, error: FormatError.Corrupt(what: "table magic"));

        table[^1] ^= 0xFF;
        table[2] ^= 0xFF;
        File.WriteAllBytes(path: path, bytes: table);
        AssertRefuses(path: path, error: FormatError.Corrupt(what: "block checksum"));

        File.WriteAllBytes(path: path, bytes: [1, 2, 3]);
        AssertRefuses(path: path, error: FormatError.Corrupt(what: "table footer"));
    }

    /// While a table is read, the app that owns it can delete it, as LevelDB does after compaction.
    [Fact]
    public void LetsItsOwnerDeleteItWhileItsRead()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("000005.ldb");
        File.WriteAllBytes(path: path, bytes: TableWriter.Table(entries: Entries(count: 7), perBlock: 3));
        var deleted = false;
        var read = LevelDBTable.Read(path: path, mayHold: (_, _) =>
        {
            if (!deleted)
            {
                File.Delete(path: path);
                deleted = true;
            }
            return true;
        });

        Assert.True(condition: deleted);
        Assert.False(condition: File.Exists(path: path));
        Assert.Equal(expected: 7, actual: read.Entries.Count);
    }

    static List<TableEntry> Entries(int count) => Enumerable.Range(start: 0, count: count)
        .Select(selector: index => new TableEntry(
            Key: Encodings.Utf8(text: "key-" + (100 + index).ToString(provider: System.Globalization.CultureInfo.InvariantCulture)),
            Sequence: (ulong)(index + 1),
            Value: index == 3 ? null : Encodings.Utf8(text: "value " + index.ToString(provider: System.Globalization.CultureInfo.InvariantCulture))))
        .ToList();

    static void AssertRefuses(string path, FormatError error)
    {
        var thrown = Assert.Throws<FormatErrorException>(testCode: () => LevelDBTable.Read(path: path));
        Assert.Equal(expected: error, actual: thrown.Error);
    }
}
