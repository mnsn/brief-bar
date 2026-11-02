namespace BriefBar.Core.ChromiumIndexedDB;

/// Reads LevelDB's and Chromium's encodings from bytes, from `start` up to `end`, throwing rather than reading past the
/// end. The Mac's `ByteReader`.
internal sealed class ByteReader
{
    public ByteReader(byte[] bytes, int start = 0, int? end = null)
    {
        ArgumentNullException.ThrowIfNull(argument: bytes);
        Bytes = bytes;
        End = Math.Min(val1: Math.Max(val1: 0, val2: end ?? bytes.Length), val2: bytes.Length);
        Offset = Math.Min(val1: Math.Max(val1: 0, val2: start), val2: End);
    }

    public byte[] Bytes { get; }

    public int Offset { get; private set; }

    public int End { get; }

    public bool IsAtEnd => Offset >= End;

    public int Remaining => End - Offset;

    public byte ReadByte()
    {
        if (Offset >= End)
        {
            throw FormatErrorException.Truncated();
        }
        return Bytes[Offset++];
    }

    public byte PeekByte() => Offset < End ? Bytes[Offset] : throw FormatErrorException.Truncated();

    /// The next `count` bytes, without copying them.
    public ArraySegment<byte> ReadBytes(int count)
    {
        if (count < 0 || count > Remaining)
        {
            throw FormatErrorException.Truncated();
        }
        var bytes = new ArraySegment<byte>(array: Bytes, offset: Offset, count: count);
        Offset += count;
        return bytes;
    }

    public void Skip(int count)
    {
        if (count < 0 || count > Remaining)
        {
            throw FormatErrorException.Truncated();
        }
        Offset += count;
    }

    /// A little-endian integer of `count` bytes, as LevelDB writes fixed-width ones.
    public ulong ReadLittleEndian(int count)
    {
        var bytes = ReadBytes(count: count);
        ulong value = 0;
        for (var shift = 0; shift < bytes.Count; shift++)
        {
            value |= (ulong)bytes[shift] << (8 * shift);
        }
        return value;
    }

    /// A big-endian integer of `count` bytes.
    public ulong ReadBigEndian(int count)
    {
        ulong value = 0;
        foreach (var next in ReadBytes(count: count))
        {
            value = (value << 8) | next;
        }
        return value;
    }

    public uint ReadFixed32() => (uint)ReadLittleEndian(count: 4);

    public ulong ReadFixed64() => ReadLittleEndian(count: 8);

    public double ReadDouble() => BitConverter.UInt64BitsToDouble(value: ReadFixed64());

    /// A base-128 varint of up to 64 bits.
    public ulong ReadVarint()
    {
        ulong value = 0;
        var shift = 0;
        while (true)
        {
            var next = ReadByte();
            if (shift >= 63 && next > 1)
            {
                throw FormatErrorException.Corrupt(what: "varint");
            }
            value |= (ulong)(next & 0x7F) << shift;
            if (next < 0x80)
            {
                return value;
            }
            shift += 7;
        }
    }

    public uint ReadVarint32()
    {
        var value = ReadVarint();
        return value <= uint.MaxValue ? (uint)value : throw FormatErrorException.Corrupt(what: "varint");
    }

    /// A varint that counts bytes or items: no more than what's left to read could hold.
    public int ReadCount()
    {
        var value = ReadVarint();
        return value <= (ulong)Remaining ? (int)value : throw FormatErrorException.Truncated();
    }
}
