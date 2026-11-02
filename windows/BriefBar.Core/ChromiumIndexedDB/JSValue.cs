using System.Globalization;

namespace BriefBar.Core.ChromiumIndexedDB;

/// A JavaScript value, as V8 serialized it, compared by value. The Mac's `JSValue`.
public sealed class JSValue : IEquatable<JSValue>
{
    static readonly IReadOnlyDictionary<string, JSValue> noProperties = new Dictionary<string, JSValue>(comparer: StringComparer.Ordinal);

    JSValue(
        JSValueKind kind,
        bool flag = false,
        double number = 0,
        string? text = null,
        IReadOnlyList<JSValue>? items = null,
        IReadOnlyDictionary<string, JSValue>? properties = null,
        IReadOnlyList<JSPair>? pairs = null,
        IReadOnlyList<byte>? bytes = null,
        uint flags = 0)
    {
        Kind = kind;
        Flag = flag;
        Number = number;
        Text = text;
        Items = items ?? [];
        Properties = properties ?? noProperties;
        Pairs = pairs ?? [];
        Bytes = bytes ?? [];
        Flags = flags;
    }

    public static JSValue Undefined { get; } = new(kind: JSValueKind.Undefined);

    public static JSValue Null { get; } = new(kind: JSValueKind.Null);

    public JSValueKind Kind { get; }

    /// A boolean's value, or whether a big integer is negative.
    public bool Flag { get; }

    /// A number's value, or a date's, in milliseconds since 1970.
    public double Number { get; }

    /// A string's text, a regular expression's pattern, or an error's message.
    public string? Text { get; }

    /// An array's or a set's items.
    public IReadOnlyList<JSValue> Items { get; }

    /// An object's properties.
    public IReadOnlyDictionary<string, JSValue> Properties { get; }

    /// A map's entries.
    public IReadOnlyList<JSPair> Pairs { get; }

    /// A buffer's bytes, or a big integer's magnitude, little-endian.
    public IReadOnlyList<byte> Bytes { get; }

    /// A regular expression's flags.
    public uint Flags { get; }

    /// The text of a string, or null for anything else.
    public string? AsString => Kind == JSValueKind.Text ? Text : null;

    /// An object's property, or null for one it doesn't have, or a value that isn't an object.
    public JSValue? this[string key] => Kind == JSValueKind.PlainObject && Properties.TryGetValue(key: key, value: out var value) ? value : null;

    public static bool operator ==(JSValue? left, JSValue? right) => left is null ? right is null : left.Equals(other: right);

    public static bool operator !=(JSValue? left, JSValue? right) => !(left == right);

    public static JSValue FromBool(bool value) => new(kind: JSValueKind.Bool, flag: value);

    public static JSValue FromNumber(double value) => new(kind: JSValueKind.Number, number: value);

    public static JSValue FromString(string text) => new(kind: JSValueKind.Text, text: text);

    public static JSValue FromDate(double milliseconds) => new(kind: JSValueKind.Date, number: milliseconds);

    public static JSValue FromBigInt(bool negative, IReadOnlyList<byte> magnitude) => new(kind: JSValueKind.BigInt, flag: negative, bytes: magnitude);

    public static JSValue FromArray(IReadOnlyList<JSValue> items) => new(kind: JSValueKind.Array, items: items);

    public static JSValue FromObject(IReadOnlyDictionary<string, JSValue> properties) => new(kind: JSValueKind.PlainObject, properties: properties);

    public static JSValue FromMap(IReadOnlyList<JSPair> pairs) => new(kind: JSValueKind.Map, pairs: pairs);

    public static JSValue FromSet(IReadOnlyList<JSValue> items) => new(kind: JSValueKind.Set, items: items);

    public static JSValue FromRegExp(string pattern, uint flags) => new(kind: JSValueKind.RegExp, text: pattern, flags: flags);

    public static JSValue FromBytes(IReadOnlyList<byte> bytes) => new(kind: JSValueKind.Bytes, bytes: bytes);

    public static JSValue FromError(string? message) => new(kind: JSValueKind.Error, text: message);

    public bool Equals(JSValue? other)
    {
        if (other is null || other.Kind != Kind)
        {
            return false;
        }
        if (ReferenceEquals(objA: this, objB: other))
        {
            return true;
        }
        return Kind switch
        {
            JSValueKind.Undefined or JSValueKind.Null => true,
            JSValueKind.Bool => Flag == other.Flag,
            JSValueKind.Number or JSValueKind.Date => Number.Equals(obj: other.Number),
            JSValueKind.BigInt => Flag == other.Flag && Bytes.SequenceEqual(second: other.Bytes),
            JSValueKind.Text or JSValueKind.Error => string.Equals(a: Text, b: other.Text, comparisonType: StringComparison.Ordinal),
            JSValueKind.RegExp => string.Equals(a: Text, b: other.Text, comparisonType: StringComparison.Ordinal) && Flags == other.Flags,
            JSValueKind.Array or JSValueKind.Set => Items.SequenceEqual(second: other.Items),
            JSValueKind.Map => Pairs.SequenceEqual(second: other.Pairs),
            JSValueKind.Bytes => Bytes.SequenceEqual(second: other.Bytes),
            _ => Properties.Count == other.Properties.Count
                && Properties.All(predicate: pair => other.Properties.TryGetValue(key: pair.Key, value: out var value) && pair.Value.Equals(other: value)),
        };
    }

    public override bool Equals(object? obj) => obj is JSValue other && Equals(other: other);

    public override int GetHashCode() => Kind switch
    {
        JSValueKind.Bool => HashCode.Combine(value1: Kind, value2: Flag),
        JSValueKind.Number or JSValueKind.Date => HashCode.Combine(value1: Kind, value2: Number),
        JSValueKind.Text or JSValueKind.Error or JSValueKind.RegExp => HashCode.Combine(value1: Kind, value2: Text),
        JSValueKind.Array or JSValueKind.Set => HashCode.Combine(value1: Kind, value2: Items.Count),
        JSValueKind.PlainObject => HashCode.Combine(value1: Kind, value2: Properties.Count),
        JSValueKind.Map => HashCode.Combine(value1: Kind, value2: Pairs.Count),
        JSValueKind.Bytes or JSValueKind.BigInt => HashCode.Combine(value1: Kind, value2: Bytes.Count),
        _ => Kind.GetHashCode(),
    };

    /// Its kind, and for a number, its value: never a string's text, which can be anything.
    public override string ToString() => Kind == JSValueKind.Number
        ? Number.ToString(provider: CultureInfo.InvariantCulture)
        : Kind.ToString();
}
