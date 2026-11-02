namespace BriefBar.Core.Tests.ChromiumIndexedDB;

/// The encodings LevelDB and Chromium write, for made-up data. The Mac's test support's `varint`, `littleEndian` and
/// `snappyLiterals`.
internal static class Encodings
{
    public static byte[] Varint(ulong value)
    {
        var bytes = new List<byte>();
        while (value >= 0x80)
        {
            bytes.Add(item: (byte)((value & 0x7F) | 0x80));
            value >>= 7;
        }
        bytes.Add(item: (byte)value);
        return [.. bytes];
    }

    public static byte[] LittleEndian(ulong value, int count) =>
        Enumerable.Range(start: 0, count: count).Select(selector: index => (byte)(value >> (8 * index))).ToArray();

    /// Snappy with literals only: valid, and enough to check that compressed blocks and values are read.
    public static byte[] SnappyLiterals(byte[] bytes)
    {
        var output = new List<byte>(collection: Varint(value: (ulong)bytes.Length));
        var start = 0;
        while (start < bytes.Length)
        {
            var count = Math.Min(val1: 60_000, val2: bytes.Length - start);
            if (count <= 60)
            {
                output.Add(item: (byte)((count - 1) << 2));
            }
            else
            {
                output.Add(item: 61 << 2);
                output.AddRange(collection: LittleEndian(value: (ulong)(count - 1), count: 2));
            }
            output.AddRange(collection: bytes.AsSpan(start: start, length: count).ToArray());
            start += count;
        }
        return [.. output];
    }

    public static byte[] Utf8(string text) => System.Text.Encoding.UTF8.GetBytes(s: text);
}
