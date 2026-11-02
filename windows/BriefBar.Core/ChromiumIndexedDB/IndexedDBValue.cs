namespace BriefBar.Core.ChromiumIndexedDB;

/// A record's value, how it was written, and whether it was too large for the database, and came from a blob file. The
/// Mac's `IndexedDBFolder.Value`.
public sealed record IndexedDBValue(JSValue Value, SerializedFormat Format, bool FromBlobFile);
