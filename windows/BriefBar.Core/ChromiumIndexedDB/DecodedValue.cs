namespace BriefBar.Core.ChromiumIndexedDB;

/// A value Blink serialized, decoded: the value and how it was written, or, for one too large to keep in the database,
/// which of the record's external objects holds it, and how large it is. The Mac's `SerializedValue.Decoded`.
public sealed record DecodedValue
{
    DecodedValue(JSValue? value, SerializedFormat format, int blobSize, int blobIndex)
    {
        Value = value;
        Format = format;
        BlobSize = blobSize;
        BlobIndex = blobIndex;
    }

    public JSValue? Value { get; }

    public SerializedFormat Format { get; }

    public int BlobSize { get; }

    public int BlobIndex { get; }

    public bool IsInBlobFile => Value is null;

    public static DecodedValue Of(JSValue value, SerializedFormat format) => new(value: value, format: format, blobSize: 0, blobIndex: 0);

    public static DecodedValue InBlobFile(int size, int index) => new(value: null, format: default, blobSize: size, blobIndex: index);
}
