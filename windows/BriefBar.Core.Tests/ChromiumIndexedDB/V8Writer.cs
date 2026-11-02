namespace BriefBar.Core.Tests.ChromiumIndexedDB;

/// Writes V8's serialization format, version 16, inside Blink's version 21 envelope, for made-up values. The Mac's test
/// support's `V8Writer`.
internal sealed class V8Writer
{
    readonly List<byte> bytes = [];

    /// Blink's version 21 envelope, with an empty trailer, and V8's version 16 header.
    public static byte[] Header { get; } = [0xFF, 21, 0xFE, .. new byte[12], 0xFF, 16];

    /// A record's value: its version, Blink's envelope and V8's header, then `body`.
    public static byte[] Record(Action<V8Writer> body, ulong version = 1) => [.. Encodings.Varint(value: version), .. Serialized(body: body)];

    public static byte[] Serialized(Action<V8Writer> body)
    {
        ArgumentNullException.ThrowIfNull(argument: body);
        var writer = new V8Writer();
        writer.bytes.AddRange(collection: Header);
        body(obj: writer);
        return [.. writer.bytes];
    }

    public void Tag(char tag) => bytes.Add(item: (byte)tag);

    public void Text(string text)
    {
        if (text.All(predicate: unit => unit < 256))
        {
            Tag(tag: '"');
            bytes.AddRange(collection: Encodings.Varint(value: (ulong)text.Length));
            bytes.AddRange(collection: text.Select(selector: unit => (byte)unit));
        }
        else
        {
            // Padding, as V8 aligns two-byte strings.
            bytes.Add(item: 0);
            Tag(tag: 'c');
            bytes.AddRange(collection: Encodings.Varint(value: (ulong)(text.Length * 2)));
            bytes.AddRange(collection: text.SelectMany(selector: unit => new[] { (byte)(unit & 0xFF), (byte)(unit >> 8) }));
        }
    }

    public void Whole(int value)
    {
        Tag(tag: 'I');
        var zigzag = (uint)((value << 1) ^ (value >> 31));
        bytes.AddRange(collection: Encodings.Varint(value: zigzag));
    }

    public void Real(double value)
    {
        Tag(tag: 'N');
        bytes.AddRange(collection: Encodings.LittleEndian(value: BitConverter.DoubleToUInt64Bits(value: value), count: 8));
    }

    public void Flag(bool value) => Tag(tag: value ? 'T' : 'F');

    /// An object with `properties`, in order.
    public void Members(params (string Name, Action<V8Writer> Value)[] properties)
    {
        Tag(tag: 'o');
        foreach (var (name, value) in properties)
        {
            Text(text: name);
            value(obj: this);
        }
        Tag(tag: '{');
        bytes.AddRange(collection: Encodings.Varint(value: (ulong)properties.Length));
    }

    /// A dense array of `elements`.
    public void Elements(params Action<V8Writer>[] elements)
    {
        Tag(tag: 'A');
        bytes.AddRange(collection: Encodings.Varint(value: (ulong)elements.Length));
        foreach (var element in elements)
        {
            element(obj: this);
        }
        Tag(tag: '$');
        bytes.AddRange(collection: Encodings.Varint(value: 0));
        bytes.AddRange(collection: Encodings.Varint(value: (ulong)elements.Length));
    }
}
