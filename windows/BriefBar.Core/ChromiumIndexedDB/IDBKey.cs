namespace BriefBar.Core.ChromiumIndexedDB;

/// An IndexedDB key, as an object store's records are keyed, compared and ordered as Chromium orders them: by type
/// (`IDBKeyType`), then numbers and dates by value, strings by their UTF-16 code units, binary keys byte by byte, and
/// arrays item by item. The Mac's `IDBKey`.
public sealed class IDBKey : IEquatable<IDBKey>, IComparable<IDBKey>
{
    static readonly byte[] noBytes = [];

    IDBKey(IDBKeyType type, string? text = null, double number = 0, byte[]? binary = null, IReadOnlyList<IDBKey>? items = null)
    {
        Type = type;
        Text = text;
        Number = number;
        Binary = binary ?? noBytes;
        Items = items ?? [];
    }

    public static IDBKey Null { get; } = new(type: IDBKeyType.Null);

    public static IDBKey MinKey { get; } = new(type: IDBKeyType.MinKey);

    public IDBKeyType Type { get; }

    /// A string key's text.
    public string? Text { get; }

    /// A number key's value, or a date key's, in milliseconds since 1970.
    public double Number { get; }

    /// A binary key's bytes.
    public IReadOnlyList<byte> Binary { get; }

    /// An array key's items.
    public IReadOnlyList<IDBKey> Items { get; }

    public static bool operator ==(IDBKey? left, IDBKey? right) => left is null ? right is null : left.Equals(other: right);

    public static bool operator !=(IDBKey? left, IDBKey? right) => !(left == right);

    public static bool operator <(IDBKey left, IDBKey right) => Compare(left: left, right: right) < 0;

    public static bool operator >(IDBKey left, IDBKey right) => Compare(left: left, right: right) > 0;

    public static bool operator <=(IDBKey left, IDBKey right) => Compare(left: left, right: right) <= 0;

    public static bool operator >=(IDBKey left, IDBKey right) => Compare(left: left, right: right) >= 0;

    public static IDBKey FromString(string text) => new(type: IDBKeyType.Text, text: text);

    public static IDBKey FromNumber(double number) => new(type: IDBKeyType.Number, number: number);

    public static IDBKey FromDate(double milliseconds) => new(type: IDBKeyType.Date, number: milliseconds);

    public static IDBKey FromBinary(byte[] bytes) => new(type: IDBKeyType.Binary, binary: bytes);

    public static IDBKey FromArray(IReadOnlyList<IDBKey> items) => new(type: IDBKeyType.Array, items: items);

    public int CompareTo(IDBKey? other) => other is null ? 1 : Compare(left: this, right: other);

    public bool Equals(IDBKey? other) => other is not null && Compare(left: this, right: other) == 0;

    public override bool Equals(object? obj) => obj is IDBKey other && Equals(other: other);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(value: Type);
        switch (Type)
        {
            case IDBKeyType.Text:
                hash.Add(value: Text, comparer: StringComparer.Ordinal);
                break;
            case IDBKeyType.Number or IDBKeyType.Date:
                hash.Add(value: Number);
                break;
            case IDBKeyType.Binary:
                foreach (var next in Binary)
                {
                    hash.Add(value: next);
                }
                break;
            case IDBKeyType.Array:
                foreach (var item in Items)
                {
                    hash.Add(value: item);
                }
                break;
            default:
                break;
        }
        return hash.ToHashCode();
    }

    public override string ToString() => Type.ToString();

    static int Compare(IDBKey left, IDBKey right)
    {
        if (left.Type != right.Type)
        {
            return ((int)left.Type).CompareTo(value: (int)right.Type);
        }
        switch (left.Type)
        {
            case IDBKeyType.Text:
                return Math.Sign(value: string.CompareOrdinal(strA: left.Text, strB: right.Text));
            case IDBKeyType.Number or IDBKeyType.Date:
                return left.Number.CompareTo(value: right.Number);
            case IDBKeyType.Binary:
                for (var index = 0; index < Math.Min(val1: left.Binary.Count, val2: right.Binary.Count); index++)
                {
                    if (left.Binary[index] != right.Binary[index])
                    {
                        return left.Binary[index].CompareTo(value: right.Binary[index]);
                    }
                }
                return left.Binary.Count.CompareTo(value: right.Binary.Count);
            case IDBKeyType.Array:
                for (var index = 0; index < Math.Min(val1: left.Items.Count, val2: right.Items.Count); index++)
                {
                    var byItem = Compare(left: left.Items[index], right: right.Items[index]);
                    if (byItem != 0)
                    {
                        return byItem;
                    }
                }
                return left.Items.Count.CompareTo(value: right.Items.Count);
            default:
                return 0;
        }
    }
}
