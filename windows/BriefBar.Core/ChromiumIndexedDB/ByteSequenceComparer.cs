namespace BriefBar.Core.ChromiumIndexedDB;

/// Compares byte arrays by their contents, for dictionaries keyed by LevelDB keys.
internal sealed class ByteSequenceComparer : IEqualityComparer<byte[]>
{
    public static ByteSequenceComparer Instance { get; } = new();

    public bool Equals(byte[]? x, byte[]? y) =>
        ReferenceEquals(objA: x, objB: y) || (x is not null && y is not null && x.AsSpan().SequenceEqual(other: y));

    public int GetHashCode(byte[] obj)
    {
        ArgumentNullException.ThrowIfNull(argument: obj);
        var hash = new HashCode();
        hash.AddBytes(value: obj);
        return hash.ToHashCode();
    }
}
