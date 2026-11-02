namespace BriefBar.Core.ChromiumIndexedDB;

/// What a key Chromium's IndexedDB writes to LevelDB is about, of the ones read here (`Kind`): a database's name and ID,
/// an object store's name, or a record or its blob entry with the record's key. The Mac's `IndexedDBKey`.
public sealed record IndexedDBKey(IndexedDBKeyKind Kind, long Database = 0, long ObjectStore = 0, IDBKey? Key = null, string? Origin = null, string? Name = null)
{
    const byte DatabaseNameType = 201;
    const byte ObjectStoreMetadataType = 50;
    const byte ObjectStoreNameType = 0;

    /// Reads what `key` is about; throws `FormatErrorException` when it isn't an IndexedDB key, or one it can't read.
    public static IndexedDBKey Parse(byte[] key) => Parse(key: new ArraySegment<byte>(array: key));

    /// Reads what `key` is about, without copying it.
    public static IndexedDBKey Parse(ArraySegment<byte> key)
    {
        if (KeyPrefix.Decode(key: key, length: out var length) is not { } prefix)
        {
            throw FormatErrorException.Corrupt(what: "key prefix");
        }
        var reader = new ByteReader(bytes: key.Array!, start: key.Offset + length, end: key.Offset + key.Count);
        switch (prefix)
        {
            case { Database: 0, ObjectStore: 0, Index: 0 }:
                if (reader.IsAtEnd || reader.ReadByte() != DatabaseNameType)
                {
                    return new IndexedDBKey(Kind: IndexedDBKeyKind.OtherMetadata);
                }
                var origin = StringWithLength(reader: reader);
                return new IndexedDBKey(Kind: IndexedDBKeyKind.DatabaseName, Origin: origin, Name: StringWithLength(reader: reader));
            case { ObjectStore: 0, Index: 0 }:
                if (reader.IsAtEnd || reader.ReadByte() != ObjectStoreMetadataType)
                {
                    return new IndexedDBKey(Kind: IndexedDBKeyKind.OtherMetadata);
                }
                var objectStore = reader.ReadVarint();
                if (objectStore > long.MaxValue || reader.ReadByte() != ObjectStoreNameType)
                {
                    return new IndexedDBKey(Kind: IndexedDBKeyKind.OtherMetadata);
                }
                return new IndexedDBKey(Kind: IndexedDBKeyKind.ObjectStoreName, Database: prefix.Database, ObjectStore: (long)objectStore);
            case { Index: KeyPrefix.Records }:
                return new IndexedDBKey(Kind: IndexedDBKeyKind.Record, Database: prefix.Database, ObjectStore: prefix.ObjectStore, Key: ReadKey(reader: reader));
            case { Index: KeyPrefix.BlobEntries }:
                return new IndexedDBKey(Kind: IndexedDBKeyKind.BlobEntry, Database: prefix.Database, ObjectStore: prefix.ObjectStore, Key: ReadKey(reader: reader));
            default:
                return new IndexedDBKey(Kind: IndexedDBKeyKind.Other);
        }
    }

    /// A database ID: a little-endian integer of up to 8 bytes.
    public static long DatabaseId(byte[] value)
    {
        ArgumentNullException.ThrowIfNull(argument: value);
        if (value.Length is < 1 or > 8)
        {
            throw FormatErrorException.Corrupt(what: "database ID");
        }
        var id = new ByteReader(bytes: value).ReadLittleEndian(count: value.Length);
        return id <= long.MaxValue ? (long)id : throw FormatErrorException.Corrupt(what: "database ID");
    }

    /// A name stored as a value: UTF-16, big-endian, the whole value.
    public static string StringValue(byte[] value)
    {
        ArgumentNullException.ThrowIfNull(argument: value);
        return Utf16(reader: new ByteReader(bytes: value), count: value.Length / 2);
    }

    /// The external objects of a record (a blob entry's value).
    public static IReadOnlyList<ExternalObject> ExternalObjects(byte[] value)
    {
        ArgumentNullException.ThrowIfNull(argument: value);
        var reader = new ByteReader(bytes: value);
        var objects = new List<ExternalObject>();
        while (!reader.IsAtEnd)
        {
            var kind = reader.ReadByte();
            switch (kind)
            {
                case (byte)ExternalObjectKind.Blob or (byte)ExternalObjectKind.File:
                    var number = reader.ReadVarint();
                    _ = StringWithLength(reader: reader); // MIME type
                    var size = reader.ReadVarint();
                    if (kind == (byte)ExternalObjectKind.File)
                    {
                        _ = StringWithLength(reader: reader); // File name
                        _ = reader.ReadVarint(); // Last modified
                    }
                    if (number > long.MaxValue)
                    {
                        throw FormatErrorException.Corrupt(what: "blob number");
                    }
                    objects.Add(item: new ExternalObject(Kind: (ExternalObjectKind)kind, BlobNumber: (long)number, Size: size));
                    break;
                case (byte)ExternalObjectKind.FileSystemAccessHandle:
                    reader.Skip(count: reader.ReadCount());
                    objects.Add(item: new ExternalObject(Kind: ExternalObjectKind.FileSystemAccessHandle, BlobNumber: null, Size: null));
                    break;
                default:
                    throw FormatErrorException.Unsupported(what: "external object");
            }
        }
        return objects;
    }

    /// The key a record's or blob entry's LevelDB key holds after its prefix.
    internal static IDBKey ReadKey(ByteReader reader, int depth = 0)
    {
        if (depth >= 32)
        {
            throw FormatErrorException.Unsupported(what: "key nesting");
        }
        switch (reader.ReadByte())
        {
            case 0:
                return IDBKey.Null;
            case 1:
                return IDBKey.FromString(text: StringWithLength(reader: reader));
            case 2:
                return IDBKey.FromDate(milliseconds: reader.ReadDouble());
            case 3:
                return IDBKey.FromNumber(number: reader.ReadDouble());
            case 4:
                var count = reader.ReadCount();
                var keys = new List<IDBKey>(capacity: count);
                for (var index = 0; index < count; index++)
                {
                    keys.Add(item: ReadKey(reader: reader, depth: depth + 1));
                }
                return IDBKey.FromArray(items: keys);
            case 5:
                return IDBKey.MinKey;
            case 6:
                return IDBKey.FromBinary(bytes: [.. reader.ReadBytes(count: reader.ReadCount())]);
            default:
                throw FormatErrorException.Unsupported(what: "key type");
        }
    }

    internal static string StringWithLength(ByteReader reader)
    {
        var length = reader.ReadVarint();
        return length <= (ulong)(reader.Remaining / 2) ? Utf16(reader: reader, count: (int)length) : throw FormatErrorException.Truncated();
    }

    static string Utf16(ByteReader reader, int count)
    {
        var units = new char[count];
        for (var index = 0; index < count; index++)
        {
            units[index] = (char)reader.ReadBigEndian(count: 2);
        }
        return new string(value: units);
    }
}
