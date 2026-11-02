using BriefBar.Core.ChromiumIndexedDB;

namespace BriefBar.Core.Tests.ChromiumIndexedDB;

/// Chromium's IndexedDB key encodings, for made-up data. The Mac's test support's `Keys`, with array keys too, as Teams'
/// message cache has.
internal static class IndexedDBKeys
{
    public static byte[] Prefix(long database, long objectStore, long index)
    {
        static byte[] Bytes(long value)
        {
            var bytes = Encodings.LittleEndian(value: (ulong)value, count: 8).ToList();
            while (bytes.Count > 1 && bytes[^1] == 0)
            {
                bytes.RemoveAt(index: bytes.Count - 1);
            }
            return [.. bytes];
        }
        byte[][] parts = [Bytes(value: database), Bytes(value: objectStore), Bytes(value: index)];
        var first = (byte)(((parts[0].Length - 1) << 5) | ((parts[1].Length - 1) << 2) | (parts[2].Length - 1));
        return [first, .. parts[0], .. parts[1], .. parts[2]];
    }

    public static byte[] Utf16(string text) => text.SelectMany(selector: unit => new[] { (byte)(unit >> 8), (byte)(unit & 0xFF) }).ToArray();

    public static byte[] StringWithLength(string text) => [.. Encodings.Varint(value: (ulong)text.Length), .. Utf16(text: text)];

    public static byte[] DatabaseName(string name, string origin = "made_up_origin@1") =>
        [.. Prefix(database: 0, objectStore: 0, index: 0), 201, .. StringWithLength(text: origin), .. StringWithLength(text: name)];

    public static byte[] ObjectStoreName(long database, long objectStore) =>
        [.. Prefix(database: database, objectStore: 0, index: 0), 50, .. Encodings.Varint(value: (ulong)objectStore), 0];

    public static byte[] Record(long database, long objectStore, string key) =>
        [.. Prefix(database: database, objectStore: objectStore, index: 1), 1, .. StringWithLength(text: key)];

    public static byte[] Record(long database, long objectStore, IDBKey key) =>
        [.. Prefix(database: database, objectStore: objectStore, index: 1), .. Encode(key: key)];

    public static byte[] BlobEntry(long database, long objectStore, string key) =>
        [.. Prefix(database: database, objectStore: objectStore, index: 3), 1, .. StringWithLength(text: key)];

    public static byte[] BlobEntry(long database, long objectStore, IDBKey key) =>
        [.. Prefix(database: database, objectStore: objectStore, index: 3), .. Encode(key: key)];

    /// A database ID as its name's value holds it.
    public static byte[] DatabaseId(long id) => Encodings.LittleEndian(value: (ulong)id, count: 1);

    /// An object store's name as its value holds it.
    public static byte[] Name(string name) => Utf16(text: name);

    public static byte[] Encode(IDBKey key) => key.Type switch
    {
        IDBKeyType.Text => [1, .. StringWithLength(text: key.Text!)],
        IDBKeyType.Number => [3, .. Encodings.LittleEndian(value: BitConverter.DoubleToUInt64Bits(value: key.Number), count: 8)],
        IDBKeyType.Array => [4, .. Encodings.Varint(value: (ulong)key.Items.Count), .. key.Items.SelectMany(selector: Encode)],
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(key), actualValue: key.Type, message: "Not a key these tests write."),
    };
}
