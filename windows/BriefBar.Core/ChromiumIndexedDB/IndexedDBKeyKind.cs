namespace BriefBar.Core.ChromiumIndexedDB;

/// What a key Chromium's IndexedDB writes to LevelDB is about, of the ones read here.
public enum IndexedDBKeyKind
{
    /// Which ID the database has that an origin calls by a name.
    DatabaseName,

    /// An object store's name.
    ObjectStoreName,

    /// A record of an object store: its value is the record's version, then the value Blink serialized.
    Record,

    /// The external objects of a record: the files with its values too large for the database.
    BlobEntry,

    /// Other metadata, which doesn't say which databases and object stores there are.
    OtherMetadata,

    /// Index entries, and the keys that only say that a record exists.
    Other,
}
