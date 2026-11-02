using System.Globalization;

namespace BriefBar.Core.ChromiumIndexedDB;

/// A Chromium IndexedDB backing store on LevelDB: an origin's `<origin>.indexeddb.leveldb` folder, with
/// `<origin>.indexeddb.blob` next to it for values too large for the database. Read-only, without its lock. The Mac's
/// `IndexedDBFolder`.
public sealed class IndexedDBFolder(string path)
{
    /// Far more than any record BriefBar reads.
    const long MaxBlobFileSize = 64 << 20;

    public string Path { get; } = path;

    public LevelDBFolder LevelDB => new(path: Path);

    /// Where values too large for the database are: `<origin>.indexeddb.blob`, beside the folder.
    public string BlobFolder
    {
        get
        {
            var trimmed = System.IO.Path.TrimEndingDirectorySeparator(path: Path);
            var name = System.IO.Path.GetFileName(path: trimmed);
            var stem = name.EndsWith(value: ".leveldb", comparisonType: StringComparison.Ordinal) ? name[..^".leveldb".Length] : name;
            return System.IO.Path.Combine(path1: System.IO.Path.GetDirectoryName(path: trimmed) ?? string.Empty, path2: stem + ".blob");
        }
    }

    /// Whether a record's raw value is in a blob file, rather than in the database. Chromium writes the record's blob
    /// entry, which says which file, after the record itself.
    public static bool IsInBlobFile(byte[] raw)
    {
        ArgumentNullException.ThrowIfNull(argument: raw);
        var reader = new ByteReader(bytes: raw);
        try
        {
            _ = reader.ReadVarint();
        }
        catch (FormatErrorException)
        {
            return false;
        }
        return reader.Remaining >= 3
            && raw[reader.Offset] == SerializedValue.VersionTag
            && raw[reader.Offset + 1] == SerializedValue.NeedsProcessing
            && raw[reader.Offset + 2] == SerializedValue.ReplacedWithBlob;
    }

    /// Global metadata, and each database's: their key prefixes have no object store.
    public static bool IsMetadata(ArraySegment<byte> key) => KeyPrefix.Of(key: key) is { } prefix && (prefix.Database == 0 || prefix.ObjectStore == 0);

    /// Whether keys from `lower` to `upper` may include metadata. Keys sort by prefix first, so a database's metadata, with
    /// object store 0, comes before its object stores, and the global metadata, with database 0, before all.
    public static bool MayHoldMetadata(byte[]? lower, byte[] upper)
    {
        if (lower is null)
        {
            return true;
        }
        if (KeyPrefix.Of(key: lower) is not { } low || KeyPrefix.Of(key: upper) is not { } high)
        {
            return true;
        }
        return low.Database == 0 || low.Database < high.Database || low.ObjectStore == 0;
    }

    /// Whether keys from `lower` to `upper` may include ones with any of `prefixes`.
    public static Func<byte[]?, byte[], bool> MayHold(IReadOnlySet<KeyPrefix> prefixes)
    {
        ArgumentNullException.ThrowIfNull(argument: prefixes);
        return (lower, upper) =>
        {
            if (KeyPrefix.Of(key: upper) is not { } high)
            {
                return true;
            }
            KeyPrefix? low = null;
            if (lower is not null)
            {
                if (KeyPrefix.Of(key: lower) is not { } decoded)
                {
                    return true;
                }
                low = decoded;
            }
            return prefixes.Any(predicate: prefix => (low is not { } bottom || bottom <= prefix) && prefix <= high);
        };
    }

    /// The databases and object stores, from the blocks that hold metadata only.
    public (IndexedDBCatalog Catalog, LevelDBFolderRead Read) Catalog()
    {
        var read = LevelDB.Read(mayHold: MayHoldMetadata, keep: IsMetadata);
        var catalog = new IndexedDBCatalog();
        foreach (var (key, value) in read.Values)
        {
            if (TryParse(key: key) is { } parsed)
            {
                catalog.Take(key: parsed, value: value);
            }
        }
        return (catalog, read);
    }

    /// The records of `stores` as they are now, from only the blocks that may hold them.
    public IndexedDBRecords Records(IReadOnlySet<IndexedDBStoreId> stores)
    {
        ArgumentNullException.ThrowIfNull(argument: stores);
        var prefixes = stores.SelectMany(selector: store => new[] { store.Records, store.BlobEntries }).ToHashSet();
        var read = LevelDB.Read(
            mayHold: MayHold(prefixes: prefixes),
            keep: key => KeyPrefix.Of(key: key) is { } prefix && prefixes.Contains(item: prefix));
        return Collect(read: read);
    }

    /// The records of `store` whose keys `wanted` accepts, and their blob entries, from only the blocks that may hold them:
    /// `mayHoldKeys` gets the keys a block holds of the store after (null when it starts before the store) and up to (null
    /// when it ends after the store), and rules out the blocks that can't hold a wanted key. Reads only what's asked, as
    /// the messages of a few chats are, among all the chats' messages.
    public IndexedDBRecords Records(IndexedDBStoreId store, Func<IDBKey, bool> wanted, Func<IDBKey?, IDBKey?, bool> mayHoldKeys)
    {
        ArgumentNullException.ThrowIfNull(argument: wanted);
        ArgumentNullException.ThrowIfNull(argument: mayHoldKeys);
        KeyPrefix[] prefixes = [store.Records, store.BlobEntries];
        var read = LevelDB.Read(
            mayHold: (lower, upper) => prefixes.Any(predicate: prefix => MayHoldKeys(prefix: prefix, lower: lower, upper: upper, mayHoldKeys: mayHoldKeys)),
            keep: key => KeyPrefix.Decode(key: key, length: out var length) is { } prefix
                && prefixes.Contains(value: prefix)
                && RecordKey(key: key, prefixLength: length) is { } recordKey
                && wanted(arg: recordKey));
        return Collect(read: read);
    }

    /// A record's value: after its version, the serialized value, or the blob file it's in. Throws `FormatErrorException`
    /// for one it can't read, or whose blob file it can't.
    public IndexedDBValue Value(byte[] raw, IndexedDBRecordKey key, IReadOnlyList<ExternalObject>? externalObjects)
    {
        ArgumentNullException.ThrowIfNull(argument: raw);
        ArgumentNullException.ThrowIfNull(argument: key);
        var reader = new ByteReader(bytes: raw);
        _ = reader.ReadVarint(); // The record's version.
        var decoded = SerializedValue.Decode(bytes: raw[reader.Offset..]);
        if (!decoded.IsInBlobFile)
        {
            return new IndexedDBValue(Value: decoded.Value!, Format: decoded.Format, FromBlobFile: false);
        }
        if (externalObjects is null || decoded.BlobIndex >= externalObjects.Count || externalObjects[decoded.BlobIndex].BlobNumber is not { } number)
        {
            throw FormatErrorException.Corrupt(what: "blob reference");
        }
        var file = BlobFile(database: key.Store.Database, number: number);
        var stamp = FileStamp.Of(path: file) ?? throw FormatErrorException.Corrupt(what: "blob file");
        if (stamp.Size > MaxBlobFileSize)
        {
            throw FormatErrorException.Unsupported(what: "blob file size");
        }
        byte[] bytes;
        try
        {
            (bytes, _) = LevelDBFolder.Contents(path: file);
        }
        catch (IOException)
        {
            throw FormatErrorException.Corrupt(what: "blob file");
        }
        catch (UnauthorizedAccessException)
        {
            throw FormatErrorException.Corrupt(what: "blob file");
        }
        var fromFile = SerializedValue.Decode(bytes: bytes);
        return fromFile.IsInBlobFile
            ? throw FormatErrorException.Corrupt(what: "blob file")
            : new IndexedDBValue(Value: fromFile.Value!, Format: fromFile.Format, FromBlobFile: true);
    }

    /// Where Chromium keeps a blob: in a folder per database, and one per 256 blobs, each named in hexadecimal.
    public string BlobFile(long database, long number) => System.IO.Path.Combine(
        path1: BlobFolder,
        path2: database.ToString(format: "x", provider: CultureInfo.InvariantCulture),
        path3: ((number >> 8) & 0xFF).ToString(format: "x2", provider: CultureInfo.InvariantCulture),
        path4: number.ToString(format: "x", provider: CultureInfo.InvariantCulture));

    /// What `key` is about, or null when it can't be read.
    internal static IndexedDBKey? TryParse(byte[] key)
    {
        try
        {
            return IndexedDBKey.Parse(key: key);
        }
        catch (FormatErrorException)
        {
            return null;
        }
    }

    static IndexedDBRecords Collect(LevelDBFolderRead read)
    {
        var records = new IndexedDBRecords(read: read);
        foreach (var (key, value) in read.Values)
        {
            var parsed = TryParse(key: key);
            switch (parsed?.Kind)
            {
                case IndexedDBKeyKind.Record:
                    records.Values[new IndexedDBRecordKey(Store: new IndexedDBStoreId(Database: parsed.Database, ObjectStore: parsed.ObjectStore), Key: parsed.Key!)] = value;
                    break;
                case IndexedDBKeyKind.BlobEntry:
                    try
                    {
                        records.ExternalObjects[new IndexedDBRecordKey(Store: new IndexedDBStoreId(Database: parsed.Database, ObjectStore: parsed.ObjectStore), Key: parsed.Key!)] =
                            IndexedDBKey.ExternalObjects(value: value);
                    }
                    catch (FormatErrorException)
                    {
                        records.UnreadableKeys += 1;
                    }
                    break;
                default:
                    records.UnreadableKeys += 1;
                    break;
            }
        }
        return records;
    }

    /// The record key after `prefixLength` bytes of `key`, or null when it can't be read.
    static IDBKey? RecordKey(ReadOnlySpan<byte> key, int prefixLength)
    {
        try
        {
            return IndexedDBKey.ReadKey(reader: new ByteReader(bytes: key[prefixLength..].ToArray()));
        }
        catch (FormatErrorException)
        {
            return null;
        }
    }

    /// Whether a block from `lower` to `upper` may hold keys with `prefix` that `mayHoldKeys` doesn't rule out.
    static bool MayHoldKeys(KeyPrefix prefix, byte[]? lower, byte[] upper, Func<IDBKey?, IDBKey?, bool> mayHoldKeys)
    {
        if (KeyPrefix.Decode(key: upper, length: out var upperLength) is not { } high)
        {
            return true;
        }
        KeyPrefix? low = null;
        var lowerLength = 0;
        if (lower is not null)
        {
            if (KeyPrefix.Decode(key: lower, length: out lowerLength) is not { } decoded)
            {
                return true;
            }
            low = decoded;
        }
        if ((low is { } bottom && bottom > prefix) || high < prefix)
        {
            return false;
        }
        var from = low == prefix ? RecordKey(key: lower, prefixLength: lowerLength) : null;
        var to = high == prefix ? RecordKey(key: upper, prefixLength: upperLength) : null;
        // A bound inside the store that can't be read rules nothing out.
        if ((low == prefix && from is null) || (high == prefix && to is null))
        {
            return true;
        }
        return mayHoldKeys(arg1: from, arg2: to);
    }
}
