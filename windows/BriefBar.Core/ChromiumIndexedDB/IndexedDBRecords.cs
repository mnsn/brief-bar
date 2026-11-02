namespace BriefBar.Core.ChromiumIndexedDB;

/// Records of some object stores as they are now: each record's raw value (its version, then the serialized value), the
/// external objects of the records that have any, how many keys couldn't be read, and how the folder was read. The Mac's
/// `IndexedDBFolder.Records`.
public sealed class IndexedDBRecords(LevelDBFolderRead read)
{
    public Dictionary<IndexedDBRecordKey, byte[]> Values { get; } = [];

    public Dictionary<IndexedDBRecordKey, IReadOnlyList<ExternalObject>> ExternalObjects { get; } = [];

    public int UnreadableKeys { get; set; }

    public LevelDBFolderRead Read { get; } = read;
}
