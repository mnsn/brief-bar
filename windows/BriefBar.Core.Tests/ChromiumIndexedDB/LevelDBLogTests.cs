using BriefBar.Core.ChromiumIndexedDB;

namespace BriefBar.Core.Tests.ChromiumIndexedDB;

/// The Mac's `LevelDBLogTests`: reading LevelDB's write-ahead log as it's written.
public sealed class LevelDBLogTests
{
    static readonly byte[] key = Encodings.Utf8(text: "made-up key");

    [Fact]
    public void ReadsWritesAndDeletionsInOrder()
    {
        var log = new LogWriter();
        log.Add(batch: LogWriter.Batch(sequence: 7, (key, Encodings.Utf8(text: "one")), (Encodings.Utf8(text: "other"), null)));
        log.Add(batch: LogWriter.Batch(sequence: 9, (key, Encodings.Utf8(text: "two"))));
        var parsed = LevelDBLog.Parse(bytes: log.Bytes);

        Assert.Equal(
            expected:
            [
                new LevelDBEntry(Sequence: 7, Key: key, Value: Encodings.Utf8(text: "one")),
                new LevelDBEntry(Sequence: 8, Key: Encodings.Utf8(text: "other"), Value: null),
                new LevelDBEntry(Sequence: 9, Key: key, Value: Encodings.Utf8(text: "two")),
            ],
            actual: parsed.Entries);
        Assert.Equal(expected: log.Bytes.Length, actual: parsed.End);
        Assert.Equal(expected: 0, actual: parsed.Corrupt);
        Assert.Equal(
            expected: [8UL],
            actual: LevelDBLog.Parse(bytes: log.Bytes, keep: write => write.AsSpan().SequenceEqual(other: Encodings.Utf8(text: "other"))).Entries.Select(selector: entry => entry.Sequence));
    }

    [Fact]
    public void JoinsBatchesSplitAcrossBlocks()
    {
        var log = new LogWriter();
        log.Add(batch: LogWriter.Batch(sequence: 1, (key, Enumerable.Repeat(element: (byte)1, count: 32_740).ToArray())));
        var big = Enumerable.Range(start: 0, count: 80_000).Select(selector: index => (byte)index).ToArray();
        log.Add(batch: LogWriter.Batch(sequence: 2, (key, big)));
        var parsed = LevelDBLog.Parse(bytes: log.Bytes);

        Assert.Equal(expected: [1UL, 2UL], actual: parsed.Entries.Select(selector: entry => entry.Sequence));
        Assert.Equal(expected: big, actual: parsed.Entries[^1].Value);
        Assert.Equal(expected: log.Bytes.Length, actual: parsed.End);
    }

    [Fact]
    public void StopsBeforeWhatIsntWrittenYetAndGoesOnLater()
    {
        var log = new LogWriter();
        log.Add(batch: LogWriter.Batch(sequence: 1, (key, Encodings.Utf8(text: "first"))));
        var firstEnd = log.Bytes.Length;
        log.Add(batch: LogWriter.Batch(sequence: 2, (key, Enumerable.Repeat(element: (byte)2, count: 50_000).ToArray())));
        // Mid-record, and mid-batch, with its first fragment complete.
        foreach (var cut in new[] { firstEnd + 3, firstEnd + 100, 40_000 })
        {
            var parsed = LevelDBLog.Parse(bytes: log.Bytes[..cut]);
            Assert.Equal(expected: [1UL], actual: parsed.Entries.Select(selector: entry => entry.Sequence));
            Assert.Equal(expected: firstEnd, actual: parsed.End);
            Assert.Equal(expected: 0, actual: parsed.Corrupt);
        }
        var rest = LevelDBLog.Parse(bytes: log.Bytes[firstEnd..], fileOffset: firstEnd);
        Assert.Equal(expected: [2UL], actual: rest.Entries.Select(selector: entry => entry.Sequence));
        Assert.Equal(expected: log.Bytes.Length, actual: rest.End);
        // Space LevelDB hasn't written to yet.
        Assert.Equal(expected: log.Bytes.Length, actual: LevelDBLog.Parse(bytes: [.. log.Bytes, .. new byte[100]]).End);
    }

    /// A record at the end whose checksum doesn't match may be one LevelDB is still writing: a log stops before it, counting
    /// nothing, and reading on from there tries it again.
    [Fact]
    public void StopsBeforeADamagedRecordAtTheEnd()
    {
        var log = new LogWriter();
        log.Add(batch: LogWriter.Batch(sequence: 1, (key, Encodings.Utf8(text: "first"))));
        var firstEnd = log.Bytes.Length;
        log.Add(batch: LogWriter.Batch(sequence: 2, (key, Encodings.Utf8(text: "second"))));
        var bytes = log.Bytes;
        bytes[^1] ^= 0xFF;

        var parsed = LevelDBLog.Parse(bytes: bytes);

        Assert.Equal(expected: [1UL], actual: parsed.Entries.Select(selector: entry => entry.Sequence));
        Assert.Equal(expected: firstEnd, actual: parsed.End);
        Assert.Equal(expected: 0, actual: parsed.Corrupt);
    }

    [Fact]
    public void SkipsABlockWithABadChecksum()
    {
        var log = new LogWriter();
        log.Add(batch: LogWriter.Batch(sequence: 1, (key, Encodings.Utf8(text: "lost"))));
        log.Add(batch: LogWriter.Batch(sequence: 2, (key, new byte[40_000])));
        log.Add(batch: LogWriter.Batch(sequence: 3, (key, Encodings.Utf8(text: "kept"))));
        var bytes = log.Bytes;
        bytes[10] ^= 0xFF;
        var parsed = LevelDBLog.Parse(bytes: bytes);

        // The first block is dropped, so the batch that starts there is lost too.
        Assert.Equal(expected: [3UL], actual: parsed.Entries.Select(selector: entry => entry.Sequence));
        Assert.True(condition: parsed.Corrupt >= 1);
        Assert.Equal(expected: bytes.Length, actual: parsed.End);
    }
}
