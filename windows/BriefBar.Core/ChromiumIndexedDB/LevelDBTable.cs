using Microsoft.Win32.SafeHandles;

namespace BriefBar.Core.ChromiumIndexedDB;

/// A LevelDB table file (`.ldb`, or `.sst` for older ones): blocks of sorted keys and their values, an index with each
/// block's last key, and a footer that says where the index is. LevelDB never changes a table once written. The Mac's
/// `LevelDBTable`.
///
/// A table is read through a handle that shares reading, writing and deleting, which closes once the table is read, so
/// the app that owns it can delete it meanwhile, as LevelDB does once compaction has moved its keys elsewhere.
public static class LevelDBTable
{
    public const ulong Magic = 0xDB4775248B80FB57;

    internal const int FooterSize = 48;
    internal const int BlockTrailerSize = 5;

    /// LevelDB's blocks are a few KiB, and Chromium keeps IndexedDB values over 64 KiB out of them.
    internal const int MaxBlockSize = 16 << 20;

    /// The entries whose keys `keep` accepts, from the blocks `mayHold` doesn't rule out. A block holds the keys after the
    /// previous block's last key (null for the first block) up to its own last key: `mayHold` gets those two user keys.
    public static LevelDBTableRead Read(
        string path,
        Func<byte[]?, byte[], bool>? mayHold = null,
        Func<ArraySegment<byte>, bool>? keep = null)
    {
        mayHold ??= (_, _) => true;
        keep ??= _ => true;
        using var file = File.OpenHandle(
            path: path, mode: FileMode.Open, access: FileAccess.Read, share: FileShare.ReadWrite | FileShare.Delete);
        var size = RandomAccess.GetLength(handle: file);
        if (size < FooterSize)
        {
            throw FormatErrorException.Corrupt(what: "table footer");
        }
        var footerBytes = ReadAt(file: file, offset: size - FooterSize, count: FooterSize);
        var footer = new ByteReader(bytes: footerBytes);
        // The metaindex: Chromium's tables have a bloom filter, which isn't needed here.
        _ = Handle(reader: footer);
        var indexHandle = Handle(reader: footer);
        if (new ByteReader(bytes: footerBytes, start: FooterSize - 8).ReadFixed64() != Magic)
        {
            throw FormatErrorException.Corrupt(what: "table magic");
        }

        var index = Block(file: file, handle: indexHandle, fileSize: size);
        var entries = new List<LevelDBEntry>();
        var blocksRead = 0;
        var blocksSkipped = 0;
        bool? separatorsExact = null;
        byte[]? lower = null;
        foreach (var (separator, value) in BlockEntries(block: index))
        {
            var dataHandle = Handle(reader: new ByteReader(bytes: [.. value]));
            if (separator.Length < 8)
            {
                throw FormatErrorException.Corrupt(what: "index key");
            }
            var upper = separator[..^8];
            var blockLower = lower;
            lower = upper;
            if (!mayHold(arg1: blockLower, arg2: upper))
            {
                blocksSkipped += 1;
                continue;
            }
            blocksRead += 1;
            var blockEntries = BlockEntries(block: Block(file: file, handle: dataHandle, fileSize: size));
            if (blockEntries.Count > 0)
            {
                separatorsExact = (separatorsExact ?? true) && blockEntries[^1].Key.AsSpan().SequenceEqual(other: separator);
            }
            foreach (var (internalKey, entryValue) in blockEntries)
            {
                if (internalKey.Length < 8)
                {
                    throw FormatErrorException.Corrupt(what: "table key");
                }
                var userKey = new ArraySegment<byte>(array: internalKey, offset: 0, count: internalKey.Length - 8);
                if (!keep(arg: userKey))
                {
                    continue;
                }
                var tag = new ByteReader(bytes: internalKey, start: internalKey.Length - 8).ReadFixed64();
                entries.Add(item: (tag & 0xFF) switch
                {
                    1 => new LevelDBEntry(Sequence: tag >> 8, Key: [.. userKey], Value: [.. entryValue]),
                    0 => new LevelDBEntry(Sequence: tag >> 8, Key: [.. userKey], Value: null),
                    _ => throw FormatErrorException.Corrupt(what: "table key kind"),
                });
            }
        }
        return new LevelDBTableRead(Entries: entries, BlocksRead: blocksRead, BlocksSkipped: blocksSkipped, SeparatorsExact: separatorsExact);
    }

    /// A block's keys and values. Keys share a prefix with the one before, except at the restart points listed at the end
    /// of the block. Shared prefixes can't make the keys add up to much more than the block.
    internal static List<(byte[] Key, ArraySegment<byte> Value)> BlockEntries(byte[] block)
    {
        if (block.Length < 4)
        {
            throw FormatErrorException.Corrupt(what: "block");
        }
        var restarts = (long)new ByteReader(bytes: block, start: block.Length - 4).ReadFixed32();
        if (restarts > (block.Length - 4) / 4)
        {
            throw FormatErrorException.Corrupt(what: "block restarts");
        }
        var reader = new ByteReader(bytes: block, start: 0, end: block.Length - 4 - (4 * (int)restarts));
        var entries = new List<(byte[] Key, ArraySegment<byte> Value)>();
        var key = new List<byte>();
        long keyBytes = 0;
        var maxKeyBytes = (64L * block.Length) + (64 << 10);
        while (!reader.IsAtEnd)
        {
            var shared = (int)reader.ReadVarint32();
            var unshared = (int)reader.ReadVarint32();
            var valueLength = (int)reader.ReadVarint32();
            if (shared < 0 || shared > key.Count)
            {
                throw FormatErrorException.Corrupt(what: "block key");
            }
            key.RemoveRange(index: shared, count: key.Count - shared);
            key.AddRange(collection: reader.ReadBytes(count: unshared));
            keyBytes += key.Count;
            if (keyBytes > maxKeyBytes)
            {
                throw FormatErrorException.Corrupt(what: "block keys");
            }
            entries.Add(item: ([.. key], reader.ReadBytes(count: valueLength)));
        }
        return entries;
    }

    static LevelDBBlockHandle Handle(ByteReader reader)
    {
        var offset = reader.ReadVarint();
        var size = reader.ReadVarint();
        return offset <= long.MaxValue / 2 && size <= int.MaxValue / 2
            ? new LevelDBBlockHandle(Offset: (long)offset, Size: (int)size)
            : throw FormatErrorException.Corrupt(what: "block handle");
    }

    /// A block's contents, checked against its checksum and uncompressed.
    static byte[] Block(SafeFileHandle file, LevelDBBlockHandle handle, long fileSize)
    {
        // Blocks come before the footer; a handle that says otherwise is corrupt, and mustn't overflow saying so.
        var limit = fileSize - FooterSize - BlockTrailerSize;
        if (handle.Size > limit || handle.Offset > limit - handle.Size)
        {
            throw FormatErrorException.Corrupt(what: "block handle");
        }
        if (handle.Size > MaxBlockSize)
        {
            throw FormatErrorException.Unsupported(what: "block size");
        }
        var bytes = ReadAt(file: file, offset: handle.Offset, count: handle.Size + BlockTrailerSize);
        var trailer = new ByteReader(bytes: bytes, start: handle.Size);
        var compression = trailer.ReadByte();
        var checksum = trailer.ReadFixed32();
        var contents = bytes.AsSpan(start: 0, length: handle.Size);
        if (CRC32C.Unmask(masked: checksum) != CRC32C.Checksum(bytes: [compression], initial: CRC32C.Checksum(bytes: contents)))
        {
            throw FormatErrorException.Corrupt(what: "block checksum");
        }
        return compression switch
        {
            0 => contents.ToArray(),
            1 => Snappy.Decompress(compressed: contents, limit: MaxBlockSize),
            _ => throw FormatErrorException.Unsupported(what: "block compression " + compression.ToString(provider: System.Globalization.CultureInfo.InvariantCulture)),
        };
    }

    static byte[] ReadAt(SafeFileHandle file, long offset, int count)
    {
        var bytes = new byte[count];
        var read = 0;
        while (read < count)
        {
            var got = RandomAccess.Read(handle: file, buffer: bytes.AsSpan(start: read), fileOffset: offset + read);
            if (got == 0)
            {
                throw FormatErrorException.Truncated();
            }
            read += got;
        }
        return bytes;
    }
}
