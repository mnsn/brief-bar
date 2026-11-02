namespace BriefBar.Core.ChromiumIndexedDB;

/// One write to a LevelDB database: a key's new value, or its deletion (`Value` null). LevelDB numbers every write; of
/// two writes to a key, the higher `Sequence` is the newer. The Mac's `LevelDBEntry`.
public sealed record LevelDBEntry(ulong Sequence, byte[] Key, byte[]? Value)
{
    public bool Equals(LevelDBEntry? other) =>
        other is not null
        && Sequence == other.Sequence
        && Key.AsSpan().SequenceEqual(other: other.Key)
        && (Value is null ? other.Value is null : other.Value is not null && Value.AsSpan().SequenceEqual(other: other.Value));

    public override int GetHashCode() => HashCode.Combine(value1: Sequence, value2: ByteSequenceComparer.Instance.GetHashCode(obj: Key));
}
