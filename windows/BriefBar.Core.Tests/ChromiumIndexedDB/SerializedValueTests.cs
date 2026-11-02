using BriefBar.Core.ChromiumIndexedDB;

namespace BriefBar.Core.Tests.ChromiumIndexedDB;

/// The Mac's `SerializedValueTests`: Blink's envelope and V8's format.
public sealed class SerializedValueTests
{
    [Fact]
    public void ReadsPlainValues()
    {
        var bytes = V8Writer.Serialized(body: writer => writer.Members(
            ("text", value => value.Text(text: "Made-up")),
            ("snowman", value => value.Text(text: "two-byte ☃")),
            ("negative", value => value.Whole(value: -3)),
            ("fraction", value => value.Real(value: 2.5)),
            ("yes", value => value.Tag(tag: 'T')),
            ("nothing", value => value.Tag(tag: '0')),
            ("missing", value => value.Tag(tag: '_')),
            ("list", value => value.Elements(item => item.Whole(value: 1), item => item.Tag(tag: '-'), item => item.Text(text: "x"))),
            ("nested", value => value.Members(("id", id => id.Text(text: "1792317600000"))))));
        var value = Decode(bytes: bytes);

        Assert.Equal(expected: JSValue.FromString(text: "Made-up"), actual: value["text"]);
        Assert.Equal(expected: JSValue.FromString(text: "two-byte ☃"), actual: value["snowman"]);
        Assert.Equal(expected: JSValue.FromNumber(value: -3), actual: value["negative"]);
        Assert.Equal(expected: JSValue.FromNumber(value: 2.5), actual: value["fraction"]);
        Assert.Equal(expected: JSValue.FromBool(value: true), actual: value["yes"]);
        Assert.Equal(expected: JSValue.Null, actual: value["nothing"]);
        Assert.Equal(expected: JSValue.Undefined, actual: value["missing"]);
        Assert.Equal(expected: JSValue.FromArray(items: [JSValue.FromNumber(value: 1), JSValue.Undefined, JSValue.FromString(text: "x")]), actual: value["list"]);
        Assert.Equal(expected: "1792317600000", actual: value["nested"]?["id"]?.AsString);
        Assert.Equal(expected: new SerializedFormat(Blink: 21, V8: 16, Compressed: false), actual: SerializedValue.Decode(bytes: bytes).Format);
    }

    [Fact]
    public void ReadsReferencesDatesMapsSetsAndOthers()
    {
        var body = new List<byte>();
        void Put(byte[] bytes) => body.AddRange(collection: bytes);
        void Text(string text) => body.AddRange(collection: Encodings.Utf8(text: text));
        Put(bytes: [0xFF, 21, 0xFE, .. new byte[12], 0xFF, 15]);
        Text(text: "o");
        Put(bytes: [0x22, 1]);
        Text(text: "ao{"); // a: {}
        Put(bytes: [0, 0x22, 1]);
        Text(text: "b^"); // b: the same object, by reference
        Put(bytes: [1, 0x22, 1]);
        Text(text: "dD");
        Put(bytes: Encodings.LittleEndian(value: BitConverter.DoubleToUInt64Bits(value: 1_792_317_600_000.0), count: 8));
        Put(bytes: [0x22, 1]);
        Text(text: "m;");
        Put(bytes: [0x22, 1]);
        Text(text: "kI");
        Put(bytes: [2]);
        Text(text: ":");
        Put(bytes: [2, 0x22, 1]);
        Text(text: "s'");
        Put(bytes: [0x22, 1]);
        Text(text: "a,");
        Put(bytes: [1, 0x22, 1]);
        Text(text: "rR");
        Put(bytes: [0x22, 2]);
        Text(text: "a+");
        Put(bytes: [3, 0x22, 1]);
        Text(text: "zZ");
        Put(bytes: [3, 0x05, 0x22, 1]); // -5n
        Text(text: "uS");
        Put(bytes: [3]);
        Text(text: "é!");
        Put(bytes: [0x22, 1]);
        Text(text: "vB");
        Put(bytes: [4, 1, 2, 3, 4]);
        Text(text: "VB");
        Put(bytes: [1, 2, 0, 0x22, 1]);
        Text(text: "erTm");
        Put(bytes: [0x22, 2]);
        Text(text: "no.{");
        Put(bytes: [10]);
        var value = Decode(bytes: [.. body]);

        Assert.Equal(expected: JSValue.FromObject(properties: new Dictionary<string, JSValue>()), actual: value["b"]);
        Assert.Equal(expected: JSValue.FromDate(milliseconds: 1_792_317_600_000), actual: value["d"]);
        Assert.Equal(expected: JSValue.FromMap(pairs: [new JSPair(Key: JSValue.FromString(text: "k"), Value: JSValue.FromNumber(value: 1))]), actual: value["m"]);
        Assert.Equal(expected: JSValue.FromSet(items: [JSValue.FromString(text: "a")]), actual: value["s"]);
        Assert.Equal(expected: JSValue.FromRegExp(pattern: "a+", flags: 3), actual: value["r"]);
        Assert.Equal(expected: JSValue.FromBigInt(negative: true, magnitude: [0x05]), actual: value["z"]);
        Assert.Equal(expected: JSValue.FromString(text: "é!"), actual: value["u"]);
        Assert.Equal(expected: JSValue.FromBytes(bytes: [2, 3]), actual: value["v"]);
        Assert.Equal(expected: JSValue.FromError(message: "no"), actual: value["e"]);
    }

    [Fact]
    public void ReadsCompressedValuesAndOlderEnvelopes()
    {
        var plain = V8Writer.Serialized(body: writer => writer.Members(("id", id => id.Text(text: "19:made-up@thread.v2"))));
        var compressed = SerializedValue.Decode(bytes: [0xFF, 0x11, 0x02, .. Encodings.SnappyLiterals(bytes: plain)]);

        Assert.Equal(expected: "19:made-up@thread.v2", actual: compressed.Value?["id"]?.AsString);
        Assert.True(condition: compressed.Format.Compressed);
        // Blink 15: one version for both formats.
        Assert.Equal(expected: JSValue.FromBool(value: true), actual: Decode(bytes: [0xFF, 0x0F, (byte)'T']));
        // Blink 18: its own version, then V8's, without a trailer offset.
        Assert.Equal(expected: JSValue.FromBool(value: false), actual: Decode(bytes: [0xFF, 18, 0xFF, 15, (byte)'F']));
        // A trailer after the value.
        byte[] trailed = [0xFF, 21, 0xFE, 0, 0, 0, 0, 0, 0, 0, 18, 0, 0, 0, 3, 0xFF, 16, (byte)'T', 9, 9, 9];
        Assert.Equal(expected: JSValue.FromBool(value: true), actual: Decode(bytes: trailed));
    }

    [Fact]
    public void PointsToBlobFiles()
    {
        var decoded = SerializedValue.Decode(bytes: [0xFF, 0x11, 0x01, .. Encodings.Varint(value: 70_814), 0]);

        Assert.True(condition: decoded.IsInBlobFile);
        Assert.Equal(expected: 70_814, actual: decoded.BlobSize);
        Assert.Equal(expected: 0, actual: decoded.BlobIndex);
    }

    [Fact]
    public void RefusesWhatItDoesntRead()
    {
        var header = V8Writer.Header;
        AssertRefuses(bytes: [.. header, (byte)'\\'], error: FormatError.Unsupported(what: "V8 tag 92"));
        AssertRefuses(bytes: [0xFF, 21, 0xFE, .. new byte[12], 0xFF, 12, 0x54], error: FormatError.Unsupported(what: "V8 version"));
        AssertRefuses(bytes: [.. header, (byte)'o', 0x22, 9, .. Encodings.Utf8(text: "short")], error: FormatError.Truncated);
        AssertRefuses(bytes: [.. header, (byte)'o', (byte)'{', 3], error: FormatError.Corrupt(what: "property count"));
        AssertRefuses(bytes: [.. header, (byte)'^', 0], error: FormatError.Corrupt(what: "object reference"));
        var nested = new List<byte>(collection: header);
        nested.AddRange(collection: Enumerable.Repeat(element: (byte)'o', count: 300));
        for (var index = 0; index < 300; index++)
        {
            nested.AddRange(collection: [(byte)'{', 0]);
        }
        AssertRefuses(bytes: [.. nested], error: FormatError.Unsupported(what: "nesting"));
        // Sparse arrays' lengths aren't bounded by their bytes: a value has a budget for them.
        byte[] sparse = [(byte)'a', .. Encodings.Varint(value: 40_000), (byte)'@', .. Encodings.Varint(value: 0), .. Encodings.Varint(value: 40_000)];
        byte[] twoSparse = [.. header, (byte)'o', 0x22, 1, (byte)'a', .. sparse, 0x22, 1, (byte)'b', .. sparse, (byte)'{', 2];
        AssertRefuses(bytes: twoSparse, error: FormatError.Unsupported(what: "sparse array length"));
        Assert.Equal(expected: JSValue.FromArray(items: Enumerable.Repeat(element: JSValue.Undefined, count: 40_000).ToList()), actual: Decode(bytes: [.. header, .. sparse]));
    }

    static JSValue Decode(byte[] bytes) => SerializedValue.Decode(bytes: bytes).Value ?? throw new FormatErrorException(error: FormatError.Corrupt(what: "not a value"));

    static void AssertRefuses(byte[] bytes, FormatError error)
    {
        var thrown = Assert.Throws<FormatErrorException>(testCode: () => SerializedValue.Decode(bytes: bytes));
        Assert.Equal(expected: error, actual: thrown.Error);
    }
}
