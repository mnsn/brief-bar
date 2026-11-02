namespace BriefBar.Core.ChromiumIndexedDB;

/// One of an object store's external objects: a file next to the database that holds a value too large for it, named by
/// `BlobNumber` in hexadecimal. The Mac's `ExternalObject`.
public sealed record ExternalObject(ExternalObjectKind Kind, long? BlobNumber, ulong? Size);
