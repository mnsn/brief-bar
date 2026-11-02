using BriefBar.Core.ChromiumIndexedDB;

namespace BriefBar.Core.Tests.ChromiumIndexedDB;

/// The Mac's `CompressionTests`: LevelDB's checksums and Snappy.
public sealed class CompressionTests
{
    [Fact]
    public void ChecksumsAsLevelDBDoes()
    {
        Assert.Equal(expected: 0xE3069283u, actual: CRC32C.Checksum(bytes: Encodings.Utf8(text: "123456789")));
        Assert.Equal(expected: 0xE3069283u, actual: CRC32C.Checksum(bytes: Encodings.Utf8(text: "56789"), initial: CRC32C.Checksum(bytes: Encodings.Utf8(text: "1234"))));
        var crc = CRC32C.Checksum(bytes: Encodings.Utf8(text: "made-up"));
        Assert.NotEqual(expected: crc, actual: CRC32C.Mask(crc: crc));
        Assert.Equal(expected: crc, actual: CRC32C.Unmask(masked: CRC32C.Mask(crc: crc)));
    }

    [Fact]
    public void DecompressesLiteralsAndCopies()
    {
        // "ab", then 6 bytes copied from 2 back: a run.
        Assert.Equal(expected: Encodings.Utf8(text: "abababab"), actual: Snappy.Decompress(compressed: [0x08, 0x04, 0x61, 0x62, 0x09, 0x02]));
        // "xyz", then 3 bytes from 3 back with a 2-byte offset.
        Assert.Equal(expected: Encodings.Utf8(text: "xyzxyz"), actual: Snappy.Decompress(compressed: [0x06, 0x08, 0x78, 0x79, 0x7A, 0x0A, 0x03, 0x00]));
        // A 4-byte offset.
        Assert.Equal(expected: Encodings.Utf8(text: "qqqq"), actual: Snappy.Decompress(compressed: [0x04, 0x00, 0x71, 0x0B, 0x01, 0x00, 0x00, 0x00]));
        var longer = Enumerable.Range(start: 0, count: 70_000).Select(selector: index => (byte)(index * 7)).ToArray();
        Assert.Equal(expected: longer, actual: Snappy.Decompress(compressed: Encodings.SnappyLiterals(bytes: longer)));
    }

    [Fact]
    public void RefusesWhatIsntSnappy()
    {
        AssertRefuses(compressed: [0x04, 0x09, 0x00], error: FormatError.Corrupt(what: "Snappy copy"));
        AssertRefuses(compressed: [0x08, 0x04, 0x61, 0x62, 0x09, 0x03], error: FormatError.Corrupt(what: "Snappy copy"));
        AssertRefuses(compressed: [0x05, 0x04, 0x61, 0x62], error: FormatError.Corrupt(what: "Snappy length"));
        AssertRefuses(compressed: [0x05, 0x10, 0x61], error: FormatError.Corrupt(what: "Snappy literal"));
        AssertRefuses(compressed: [0x80], error: FormatError.Truncated);
    }

    static void AssertRefuses(byte[] compressed, FormatError error)
    {
        var thrown = Assert.Throws<FormatErrorException>(testCode: () => Snappy.Decompress(compressed: compressed));
        Assert.Equal(expected: error, actual: thrown.Error);
    }
}
