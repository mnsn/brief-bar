namespace BriefBar.Core.ChromiumIndexedDB;

/// A record of an object store, by its store and its key. The Mac's `IndexedDBFolder.RecordKey`.
public sealed record IndexedDBRecordKey(IndexedDBStoreId Store, IDBKey Key);
