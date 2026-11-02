using BriefBar.Core.ChromiumIndexedDB;

namespace BriefBar.Core.Tests.ChromiumIndexedDB;

/// Writes LevelDB tables: data blocks of `perBlock` entries, an index of their last keys, an empty metaindex, and the
/// footer. The Mac's test support's `TableWriter`.
internal static class TableWriter
{
    public static byte[] Table(
        IReadOnlyList<TableEntry> entries,
        int perBlock = 2,
        bool compress = false,
        int restartInterval = 16,
        Func<byte[], byte[]>? indexKey = null)
    {
        indexKey ??= key => key;
        var file = new List<byte>();
        byte[] AddBlock(byte[] contents)
        {
            var stored = compress ? Encodings.SnappyLiterals(bytes: contents) : contents;
            var type = compress ? (byte)1 : (byte)0;
            byte[] handle = [.. Encodings.Varint(value: (ulong)file.Count), .. Encodings.Varint(value: (ulong)stored.Length)];
            var checksum = CRC32C.Mask(crc: CRC32C.Checksum(bytes: [type], initial: CRC32C.Checksum(bytes: stored)));
            file.AddRange(collection: stored);
            file.Add(item: type);
            file.AddRange(collection: Encodings.LittleEndian(value: checksum, count: 4));
            return handle;
        }
        var index = new List<(byte[] Key, byte[] Value)>();
        for (var start = 0; start < entries.Count; start += perBlock)
        {
            var pairs = entries.Skip(count: start).Take(count: perBlock)
                .Select(selector: entry => (Key: InternalKey(key: entry.Key, sequence: entry.Sequence, deleted: entry.Value is null), Value: entry.Value ?? []))
                .ToList();
            var handle = AddBlock(contents: Block(pairs: pairs, restartInterval: restartInterval));
            index.Add(item: (indexKey(arg: pairs[^1].Key), handle));
        }
        var metaindex = AddBlock(contents: Block(pairs: [], restartInterval: 1));
        var indexHandle = AddBlock(contents: Block(pairs: index, restartInterval: 1));
        var footer = new List<byte>(collection: metaindex);
        footer.AddRange(collection: indexHandle);
        footer.AddRange(collection: new byte[40 - footer.Count]);
        file.AddRange(collection: footer);
        file.AddRange(collection: Encodings.LittleEndian(value: LevelDBTable.Magic, count: 8));
        return [.. file];
    }

    public static byte[] InternalKey(byte[] key, ulong sequence, bool deleted) =>
        [.. key, .. Encodings.LittleEndian(value: (sequence << 8) | (deleted ? 0UL : 1UL), count: 8)];

    static byte[] Block(List<(byte[] Key, byte[] Value)> pairs, int restartInterval)
    {
        var block = new List<byte>();
        var restarts = new List<uint>();
        byte[] previous = [];
        for (var index = 0; index < pairs.Count; index++)
        {
            var (key, value) = pairs[index];
            var shared = 0;
            if (index % restartInterval == 0)
            {
                restarts.Add(item: (uint)block.Count);
            }
            else
            {
                while (shared < Math.Min(val1: key.Length, val2: previous.Length) && key[shared] == previous[shared])
                {
                    shared += 1;
                }
            }
            block.AddRange(collection: Encodings.Varint(value: (ulong)shared));
            block.AddRange(collection: Encodings.Varint(value: (ulong)(key.Length - shared)));
            block.AddRange(collection: Encodings.Varint(value: (ulong)value.Length));
            block.AddRange(collection: key[shared..]);
            block.AddRange(collection: value);
            previous = key;
        }
        if (restarts.Count == 0)
        {
            restarts.Add(item: 0);
        }
        foreach (var restart in restarts)
        {
            block.AddRange(collection: Encodings.LittleEndian(value: restart, count: 4));
        }
        block.AddRange(collection: Encodings.LittleEndian(value: (ulong)restarts.Count, count: 4));
        return [.. block];
    }
}
