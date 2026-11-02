namespace BriefBar.Core.ChromiumIndexedDB;

/// Snappy's raw format, without framing: LevelDB compresses table blocks with it, and Chromium large IndexedDB values. The
/// Mac's `Snappy`.
internal static class Snappy
{
    /// No value BriefBar reads comes near this; a length beyond it is corrupt.
    public const int Limit = 64 << 20;

    public static byte[] Decompress(ReadOnlySpan<byte> compressed, int limit = Limit)
    {
        var position = 0;
        var length = 0;
        var shift = 0;
        while (true)
        {
            if (position >= compressed.Length)
            {
                throw FormatErrorException.Truncated();
            }
            if (shift > 28)
            {
                throw FormatErrorException.Corrupt(what: "Snappy length");
            }
            var next = compressed[position++];
            length |= (next & 0x7F) << shift;
            if (next < 0x80)
            {
                break;
            }
            shift += 7;
        }
        if (length < 0 || length > limit)
        {
            throw FormatErrorException.Unsupported(what: "Snappy length");
        }

        var output = new byte[length];
        var written = 0;
        while (position < compressed.Length)
        {
            var tag = compressed[position++];
            switch (tag & 3)
            {
                case 0:
                    var count = tag >> 2;
                    if (count >= 60)
                    {
                        count = Little(source: compressed, position: ref position, count: count - 59);
                    }
                    count += 1;
                    if (count <= 0 || count > compressed.Length - position || count > length - written)
                    {
                        throw FormatErrorException.Corrupt(what: "Snappy literal");
                    }
                    compressed.Slice(start: position, length: count).CopyTo(destination: output.AsSpan(start: written));
                    position += count;
                    written += count;
                    break;
                case 1:
                    var offset = ((tag >> 5) << 8) | Little(source: compressed, position: ref position, count: 1);
                    written = Copy(output: output, written: written, offset: offset, count: 4 + ((tag >> 2) & 7));
                    break;
                case 2:
                    written = Copy(output: output, written: written, offset: Little(source: compressed, position: ref position, count: 2), count: 1 + (tag >> 2));
                    break;
                default:
                    written = Copy(output: output, written: written, offset: Little(source: compressed, position: ref position, count: 4), count: 1 + (tag >> 2));
                    break;
            }
        }
        return written == length ? output : throw FormatErrorException.Corrupt(what: "Snappy length");
    }

    /// Copies `count` bytes from `offset` back, byte by byte: a copy may overlap what it writes, repeating a run.
    static int Copy(byte[] output, int written, int offset, int count)
    {
        if (offset <= 0 || offset > written || count > output.Length - written)
        {
            throw FormatErrorException.Corrupt(what: "Snappy copy");
        }
        for (var index = 0; index < count; index++)
        {
            output[written + index] = output[written - offset + index];
        }
        return written + count;
    }

    static int Little(ReadOnlySpan<byte> source, ref int position, int count)
    {
        if (count > source.Length - position)
        {
            throw FormatErrorException.Truncated();
        }
        long value = 0;
        for (var index = 0; index < count; index++)
        {
            value |= (long)source[position + index] << (8 * index);
        }
        position += count;
        // A 4-byte offset past what an int holds is past anything written.
        return value <= int.MaxValue ? (int)value : int.MaxValue;
    }
}
