namespace BriefBar.Core.ChromiumIndexedDB;

/// An object store, by its database's ID and its own. The Mac's `IndexedDBFolder.StoreID`.
public readonly record struct IndexedDBStoreId(long Database, long ObjectStore) : IComparable<IndexedDBStoreId>
{
    public static bool operator <(IndexedDBStoreId left, IndexedDBStoreId right) => left.CompareTo(other: right) < 0;

    public static bool operator >(IndexedDBStoreId left, IndexedDBStoreId right) => left.CompareTo(other: right) > 0;

    public static bool operator <=(IndexedDBStoreId left, IndexedDBStoreId right) => left.CompareTo(other: right) <= 0;

    public static bool operator >=(IndexedDBStoreId left, IndexedDBStoreId right) => left.CompareTo(other: right) >= 0;

    /// Its records' key prefix.
    public KeyPrefix Records => new(Database: Database, ObjectStore: ObjectStore, Index: KeyPrefix.Records);

    /// The key prefix of its records' blob entries.
    public KeyPrefix BlobEntries => new(Database: Database, ObjectStore: ObjectStore, Index: KeyPrefix.BlobEntries);

    public int CompareTo(IndexedDBStoreId other)
    {
        var byDatabase = Database.CompareTo(value: other.Database);
        return byDatabase != 0 ? byDatabase : ObjectStore.CompareTo(value: other.ObjectStore);
    }
}
