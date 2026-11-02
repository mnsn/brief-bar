using BriefBar.Core.ChromiumIndexedDB;

namespace BriefBar.Core.Tests.ChromiumIndexedDB;

/// Writes LevelDB logs as LevelDB does: 32 KiB blocks of checksummed records, a batch split across blocks. The Mac's test
/// support's `LogWriter`.
internal sealed class LogWriter
{
    readonly List<byte> bytes = [];

    public byte[] Bytes => [.. bytes];

    public static byte[] Batch(ulong sequence, params (byte[] Key, byte[]? Value)[] writes)
    {
        var batch = new List<byte>(collection: Encodings.LittleEndian(value: sequence, count: 8));
        batch.AddRange(collection: Encodings.LittleEndian(value: (ulong)writes.Length, count: 4));
        foreach (var (key, value) in writes)
        {
            batch.Add(item: value is null ? (byte)0 : (byte)1);
            batch.AddRange(collection: Encodings.Varint(value: (ulong)key.Length));
            batch.AddRange(collection: key);
            if (value is not null)
            {
                batch.AddRange(collection: Encodings.Varint(value: (ulong)value.Length));
                batch.AddRange(collection: value);
            }
        }
        return [.. batch];
    }

    /// Starts where a log of `count` bytes ends, so that what's added next lines up with its blocks, as when LevelDB
    /// appends to a log: those bytes are zeros, for the caller to drop.
    public void Pad(int count) => bytes.AddRange(collection: new byte[count]);

    public void Add(byte[] batch)
    {
        var rest = batch.AsMemory();
        var first = true;
        do
        {
            var left = LevelDBLog.BlockSize - (bytes.Count % LevelDBLog.BlockSize);
            if (left < LevelDBLog.HeaderSize)
            {
                bytes.AddRange(collection: new byte[left]);
                continue;
            }
            var count = Math.Min(val1: rest.Length, val2: left - LevelDBLog.HeaderSize);
            var last = count == rest.Length;
            byte type = first && last ? (byte)1 : first ? (byte)2 : last ? (byte)4 : (byte)3;
            var data = rest[..count].ToArray();
            var checksum = CRC32C.Mask(crc: CRC32C.Checksum(bytes: data, initial: CRC32C.Checksum(bytes: [type])));
            bytes.AddRange(collection: Encodings.LittleEndian(value: checksum, count: 4));
            bytes.AddRange(collection: Encodings.LittleEndian(value: (ulong)count, count: 2));
            bytes.Add(item: type);
            bytes.AddRange(collection: data);
            rest = rest[count..];
            first = false;
        }
        while (!rest.IsEmpty);
    }
}
