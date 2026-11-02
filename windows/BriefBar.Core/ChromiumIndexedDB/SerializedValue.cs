namespace BriefBar.Core.ChromiumIndexedDB;

/// How Blink stores a value in IndexedDB: a serialized script value, in Blink's envelope around V8's own format. The
/// Mac's `SerializedValue`.
public static class SerializedValue
{
    internal const byte VersionTag = 0xFF;

    /// Blink marks a value that needs more than deserializing with this in place of a version.
    internal const byte NeedsProcessing = 0x11;
    internal const byte ReplacedWithBlob = 0x01;
    internal const byte CompressedWithSnappy = 0x02;
    internal const byte TrailerOffsetTag = 0xFE;

    /// From this version, Blink's version comes before V8's header rather than being one with it.
    internal const int FirstSeparateEnvelope = 16;

    /// From this version, an offset and size of a trailer follow Blink's version.
    internal const int FirstTrailerOffset = 21;

    /// Versions before this one don't tag host objects, and aren't read.
    internal const int OldestV8 = 13;

    /// Decodes a value Blink serialized: a record's value after its version. Throws `FormatErrorException` for one it
    /// can't read.
    public static DecodedValue Decode(byte[] bytes)
    {
        ArgumentNullException.ThrowIfNull(argument: bytes);
        return Decode(bytes: bytes, compressed: false);
    }

    static DecodedValue Decode(byte[] bytes, bool compressed)
    {
        if (bytes.Length >= 3 && bytes[0] == VersionTag && bytes[1] == NeedsProcessing)
        {
            switch (bytes[2])
            {
                case ReplacedWithBlob:
                    var marker = new ByteReader(bytes: bytes, start: 3);
                    var size = marker.ReadVarint();
                    var index = marker.ReadVarint();
                    return size <= int.MaxValue && index <= int.MaxValue
                        ? DecodedValue.InBlobFile(size: (int)size, index: (int)index)
                        : throw FormatErrorException.Corrupt(what: "blob reference");
                case CompressedWithSnappy:
                    return compressed
                        ? throw FormatErrorException.Corrupt(what: "compressed twice")
                        : Decode(bytes: Snappy.Decompress(compressed: bytes.AsSpan(start: 3)), compressed: true);
                default:
                    // Not a marker after all: read it as a value.
                    break;
            }
        }
        var reader = new ByteReader(bytes: bytes);
        var blink = 0;
        var end = bytes.Length;
        if (reader.PeekByte() == VersionTag)
        {
            _ = reader.ReadByte();
            blink = (int)reader.ReadVarint32();
            if (blink >= FirstTrailerOffset)
            {
                if (reader.ReadByte() != TrailerOffsetTag)
                {
                    throw FormatErrorException.Corrupt(what: "trailer offset");
                }
                var offset = reader.ReadBigEndian(count: 8);
                var trailerSize = reader.ReadBigEndian(count: 4);
                if (trailerSize > 0)
                {
                    if (offset < (ulong)reader.Offset || offset > (ulong)bytes.Length)
                    {
                        throw FormatErrorException.Corrupt(what: "trailer offset");
                    }
                    end = (int)offset;
                }
            }
            if (blink < FirstSeparateEnvelope)
            {
                // One version for both: V8's header is the same bytes.
                reader = new ByteReader(bytes: bytes);
            }
        }
        var deserializer = new V8Deserializer(reader: new ByteReader(bytes: bytes, start: reader.Offset, end: end));
        var value = deserializer.Read();
        return DecodedValue.Of(value: value, format: new SerializedFormat(Blink: blink, V8: deserializer.Version, Compressed: compressed));
    }
}
