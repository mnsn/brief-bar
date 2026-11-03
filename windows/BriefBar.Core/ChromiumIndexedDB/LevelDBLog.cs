namespace BriefBar.Core.ChromiumIndexedDB;

/// LevelDB's write-ahead log: every write goes there first, in 32 KiB blocks of checksummed records, each a write batch or
/// a fragment of one. LevelDB only ever appends to it, so it can be read while it's written, and read on from where the
/// last complete batch ended. Its MANIFEST is in the same format (`LevelDBManifest`). The Mac's `LevelDBLog`.
public static class LevelDBLog
{
    public const int BlockSize = 32_768;

    public const int HeaderSize = 7;

    const byte FullRecord = 1;
    const byte FirstRecord = 2;
    const byte MiddleRecord = 3;
    const byte LastRecord = 4;

    /// Parses `bytes`, which start at `fileOffset` in the log: 0, or a previous `End`. Stops before a record or a batch
    /// that isn't all there yet, before zeros that run to the end, and before a record at the end whose checksum doesn't
    /// match: LevelDB may still be writing any of them, and reading on from `End` tries them again. Only writes to keys
    /// that `keep` accepts are kept.
    public static LevelDBLogParse Parse(byte[] bytes, long fileOffset = 0, Func<ArraySegment<byte>, bool>? keep = null)
    {
        ArgumentNullException.ThrowIfNull(argument: bytes);
        keep ??= _ => true;
        var entries = new List<LevelDBEntry>();
        var corruptBatches = 0;
        var (end, corrupt) = Records(bytes: bytes, fileOffset: fileOffset, damagedEndIsCorrupt: false, record: batch =>
        {
            try
            {
                entries.AddRange(collection: Writes(batch: batch.ToArray(), keep: keep));
            }
            catch (FormatErrorException)
            {
                corruptBatches += 1;
            }
        });
        return new LevelDBLogParse(Entries: entries, End: end, Corrupt: corrupt + corruptBatches);
    }

    /// Hands each record of `bytes`, which start at `fileOffset` in a file in the log's format, to `record`, in order:
    /// whole, where it was split across blocks. A log's records are write batches, and a MANIFEST's version edits. Stops
    /// before a record that isn't all there yet, before zeros that run to the end, which LevelDB may not have written yet,
    /// and before a record at the end whose checksum doesn't match. With `damagedEndIsCorrupt`, as LevelDB has it for a
    /// MANIFEST, that record counts as damaged, and so does one those zeros break off. Returns the file offset after the
    /// last whole record, and how many records or blocks were skipped because they broke the format or their checksum
    /// didn't match.
    internal static (long End, int Corrupt) Records(byte[] bytes, long fileOffset, bool damagedEndIsCorrupt, Action<ReadOnlySpan<byte>> record)
    {
        var end = fileOffset;
        var corrupt = 0;
        var position = 0;
        List<byte>? pending = null;

        // Drops the rest of a block, as LevelDB does with a record it can't trust, or one it never wrote, when that's only
        // damaged if it broke off a record.
        void SkipBlock(int left, bool damaged = true)
        {
            if (damaged)
            {
                corrupt += 1;
            }
            pending = null;
            position += left;
            if (position <= bytes.Length)
            {
                end = fileOffset + position;
            }
        }

        while (position < bytes.Length)
        {
            var left = BlockSize - (int)((fileOffset + position) % BlockSize);
            if (left < HeaderSize)
            {
                // A block's last few bytes are zeros when no header fits.
                position += left;
                continue;
            }
            if (bytes.Length - position < HeaderSize)
            {
                break;
            }
            var header = new ByteReader(bytes: bytes, start: position, end: position + HeaderSize);
            var checksum = header.ReadFixed32();
            var size = (int)header.ReadLittleEndian(count: 2);
            var type = header.ReadByte();
            if (type == 0 && size == 0)
            {
                // Zeros that run to the end may be space LevelDB hasn't written yet: reading on from `End` reads what it
                // writes there. LevelDB never leaves a record broken off there as it writes, since a record's first
                // fragment fills its block: as it opens the database, it counts one as damaged.
                if (bytes.AsSpan(start: position).IndexOfAnyExcept(value: (byte)0) < 0)
                {
                    if (damagedEndIsCorrupt && pending is not null)
                    {
                        corrupt += 1;
                    }
                    break;
                }
                // With more after them, the rest of the block was never written: LevelDB skips it, and counts a record it
                // breaks off as damaged.
                SkipBlock(left: left, damaged: pending is not null);
                continue;
            }
            if (HeaderSize + size > left)
            {
                SkipBlock(left: left);
                continue;
            }
            if (bytes.Length - position - HeaderSize < size)
            {
                break;
            }
            var data = bytes.AsSpan(start: position + HeaderSize, length: size);
            if (CRC32C.Unmask(masked: checksum) != CRC32C.Checksum(bytes: data, initial: CRC32C.Checksum(bytes: [type])))
            {
                // At the end of a log, it may still be being written: try again later.
                if (!damagedEndIsCorrupt && position + HeaderSize + size >= bytes.Length)
                {
                    break;
                }
                SkipBlock(left: left);
                continue;
            }
            position += HeaderSize + size;
            switch (type)
            {
                case FullRecord:
                    if (pending is not null)
                    {
                        corrupt += 1;
                    }
                    pending = null;
                    record(obj: data);
                    end = fileOffset + position;
                    break;
                case FirstRecord:
                    if (pending is not null)
                    {
                        corrupt += 1;
                    }
                    pending = [.. data];
                    break;
                case MiddleRecord:
                    if (pending is null)
                    {
                        corrupt += 1;
                    }
                    else
                    {
                        pending.AddRange(collection: data.ToArray());
                    }
                    break;
                case LastRecord:
                    if (pending is not null)
                    {
                        pending.AddRange(collection: data.ToArray());
                        record(obj: pending.ToArray());
                        end = fileOffset + position;
                    }
                    else
                    {
                        corrupt += 1;
                    }
                    pending = null;
                    break;
                default:
                    corrupt += 1;
                    break;
            }
        }
        return (end, corrupt);
    }

    /// A write batch: its first sequence number, how many writes it holds, then each write.
    internal static List<LevelDBEntry> Writes(byte[] batch, Func<ArraySegment<byte>, bool> keep)
    {
        var reader = new ByteReader(bytes: batch);
        var sequence = reader.ReadFixed64();
        var count = reader.ReadFixed32();
        var entries = new List<LevelDBEntry>();
        for (ulong index = 0; index < count; index++)
        {
            var kind = reader.ReadByte();
            var key = reader.ReadBytes(count: reader.ReadCount());
            switch (kind)
            {
                case 1:
                    var value = reader.ReadBytes(count: reader.ReadCount());
                    if (keep(arg: key))
                    {
                        entries.Add(item: new LevelDBEntry(Sequence: unchecked(sequence + index), Key: [.. key], Value: [.. value]));
                    }
                    break;
                case 0:
                    if (keep(arg: key))
                    {
                        entries.Add(item: new LevelDBEntry(Sequence: unchecked(sequence + index), Key: [.. key], Value: null));
                    }
                    break;
                default:
                    throw FormatErrorException.Corrupt(what: "write kind");
            }
        }
        return reader.IsAtEnd ? entries : throw FormatErrorException.Corrupt(what: "write batch");
    }
}
