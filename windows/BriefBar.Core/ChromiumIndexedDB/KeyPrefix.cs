using System.Globalization;

namespace BriefBar.Core.ChromiumIndexedDB;

/// The start of every key Chromium's IndexedDB writes to LevelDB: the database, object store and index it's about.
/// Chromium's comparator orders keys by it first, so all the keys of one object store are together. The Mac's
/// `KeyPrefix`.
public readonly record struct KeyPrefix(long Database, long ObjectStore, long Index) : IComparable<KeyPrefix>
{
    /// `Index` for an object store's records.
    public const long Records = 1;

    /// `Index` for the files that hold values too large for the database.
    public const long BlobEntries = 3;

    public static bool operator <(KeyPrefix left, KeyPrefix right) => left.CompareTo(other: right) < 0;

    public static bool operator >(KeyPrefix left, KeyPrefix right) => left.CompareTo(other: right) > 0;

    public static bool operator <=(KeyPrefix left, KeyPrefix right) => left.CompareTo(other: right) <= 0;

    public static bool operator >=(KeyPrefix left, KeyPrefix right) => left.CompareTo(other: right) >= 0;

    /// The prefix of `key`, and how many bytes it takes; null when `key` doesn't start with one.
    public static KeyPrefix? Decode(ReadOnlySpan<byte> key, out int length)
    {
        length = 0;
        if (key.IsEmpty)
        {
            return null;
        }
        var first = key[0];
        ReadOnlySpan<int> lengths = [((first >> 5) & 7) + 1, ((first >> 2) & 7) + 1, (first & 3) + 1];
        var total = 1 + lengths[0] + lengths[1] + lengths[2];
        if (key.Length < total)
        {
            return null;
        }
        Span<long> values = stackalloc long[3];
        var index = 1;
        for (var part = 0; part < 3; part++)
        {
            ulong value = 0;
            for (var shift = 0; shift < lengths[part]; shift++)
            {
                value |= (ulong)key[index++] << (8 * shift);
            }
            if (value > long.MaxValue)
            {
                return null;
            }
            values[part] = (long)value;
        }
        length = total;
        return new KeyPrefix(Database: values[0], ObjectStore: values[1], Index: values[2]);
    }

    /// The prefix of `key`, or null when it doesn't start with one.
    public static KeyPrefix? Of(ReadOnlySpan<byte> key) => Decode(key: key, length: out _);

    public int CompareTo(KeyPrefix other)
    {
        var byDatabase = Database.CompareTo(value: other.Database);
        if (byDatabase != 0)
        {
            return byDatabase;
        }
        var byStore = ObjectStore.CompareTo(value: other.ObjectStore);
        return byStore != 0 ? byStore : Index.CompareTo(value: other.Index);
    }

    public override string ToString() =>
        string.Create(provider: CultureInfo.InvariantCulture, handler: $"{Database}.{ObjectStore}.{Index}");
}
