using System.Globalization;
using System.Text;

namespace BriefBar.Core.ChromiumIndexedDB;

/// V8's serialization format, version 13 and later (`v8/src/objects/value-serializer.cc`). Reads what plain objects
/// hold; host objects, shared memory and WebAssembly aren't read. The Mac's `V8Deserializer`.
internal sealed class V8Deserializer(ByteReader reader)
{
    public const int MaxDepth = 64;

    /// Elements of sparse arrays so far: their length isn't bounded by the bytes that hold them, so a value has a budget.
    public const int MaxSparseElements = 1 << 16;

    /// Objects, arrays and other values that later ones may refer to, by the ID V8 gave them in order.
    readonly Dictionary<uint, JSValue> objects = [];
    uint nextId;
    int depth;
    long sparseElements;

    public int Version { get; private set; }

    public JSValue Read()
    {
        if (Tag() != SerializedValue.VersionTag)
        {
            throw FormatErrorException.Unsupported(what: "V8 header");
        }
        Version = (int)reader.ReadVarint32();
        return Version >= SerializedValue.OldestV8 ? Value() : throw FormatErrorException.Unsupported(what: "V8 version");
    }

    /// The next tag, past any padding.
    byte Tag()
    {
        var tag = reader.ReadByte();
        while (tag == 0)
        {
            tag = reader.ReadByte();
        }
        return tag;
    }

    byte PeekTag()
    {
        while (reader.PeekByte() == 0)
        {
            _ = reader.ReadByte();
        }
        return reader.PeekByte();
    }

    uint NewId() => unchecked(nextId++);

    JSValue Remember(JSValue value, uint id)
    {
        objects[id] = value;
        return value;
    }

    JSValue Value()
    {
        depth += 1;
        try
        {
            if (depth > MaxDepth)
            {
                throw FormatErrorException.Unsupported(what: "nesting");
            }
            var tag = Tag();
            switch ((char)tag)
            {
                case '?':
                    _ = reader.ReadVarint32();
                    return Value();
                case '_':
                    return JSValue.Undefined;
                case '0':
                    return JSValue.Null;
                case 'T':
                    return JSValue.FromBool(value: true);
                case 'F':
                    return JSValue.FromBool(value: false);
                case 'I':
                    var zigzag = reader.ReadVarint32();
                    return JSValue.FromNumber(value: unchecked((int)((zigzag >> 1) ^ (0u - (zigzag & 1)))));
                case 'U':
                    return JSValue.FromNumber(value: reader.ReadVarint32());
                case 'N':
                    return JSValue.FromNumber(value: reader.ReadDouble());
                case 'Z':
                    return BigInt();
                case '"' or 'c' or 'S':
                    return JSValue.FromString(text: String(tag: tag));
                case '^':
                    var reference = reader.ReadVarint32();
                    if (reference >= nextId)
                    {
                        throw FormatErrorException.Corrupt(what: "object reference");
                    }
                    // An object that isn't finished yet is a cycle, which a value can't hold.
                    return objects.TryGetValue(key: reference, value: out var known) ? known : JSValue.Undefined;
                case 'o':
                    return Object();
                case 'A':
                    return DenseArray();
                case 'a':
                    return SparseArray();
                case 'D':
                    return Remember(id: NewId(), value: JSValue.FromDate(milliseconds: reader.ReadDouble()));
                case 'y' or 'x':
                    return Remember(id: NewId(), value: JSValue.FromBool(value: tag == (byte)'y'));
                case 'n':
                    return Remember(id: NewId(), value: JSValue.FromNumber(value: reader.ReadDouble()));
                case 'z':
                    var bigIntId = NewId();
                    return Remember(id: bigIntId, value: BigInt());
                case 's':
                    var stringId = NewId();
                    return Remember(id: stringId, value: JSValue.FromString(text: String(tag: Tag())));
                case 'R':
                    var regExpId = NewId();
                    var pattern = String(tag: Tag());
                    return Remember(id: regExpId, value: JSValue.FromRegExp(pattern: pattern, flags: reader.ReadVarint32()));
                case ';':
                    return Map();
                case '\'':
                    return Set();
                case 'B' or '~':
                    return ArrayBuffer(resizable: tag == (byte)'~');
                case 'r':
                    return Error();
                default:
                    throw FormatErrorException.Unsupported(what: "V8 tag " + tag.ToString(provider: CultureInfo.InvariantCulture));
            }
        }
        finally
        {
            depth -= 1;
        }
    }

    string String(byte tag)
    {
        var length = reader.ReadCount();
        var bytes = reader.ReadBytes(count: length);
        return (char)tag switch
        {
            // Latin-1: each byte is the code point.
            '"' => Encoding.Latin1.GetString(bytes: bytes),
            'c' => length % 2 == 0 ? Encoding.Unicode.GetString(bytes: bytes) : throw FormatErrorException.Corrupt(what: "two-byte string"),
            'S' => Encoding.UTF8.GetString(bytes: bytes),
            _ => throw FormatErrorException.Corrupt(what: "string tag"),
        };
    }

    JSValue BigInt()
    {
        var bitfield = reader.ReadVarint();
        var length = bitfield >> 1;
        return length <= (ulong)reader.Remaining
            ? JSValue.FromBigInt(negative: (bitfield & 1) == 1, magnitude: [.. reader.ReadBytes(count: (int)length)])
            : throw FormatErrorException.Truncated();
    }

    /// A property's key: a string, or an array index.
    static string Key(JSValue value) => value.Kind switch
    {
        JSValueKind.Text => value.Text!,
        JSValueKind.Number when Math.Round(a: value.Number) == value.Number && Math.Abs(value: value.Number) < 1e15 =>
            ((long)value.Number).ToString(provider: CultureInfo.InvariantCulture),
        JSValueKind.Number => value.Number.ToString(provider: CultureInfo.InvariantCulture),
        _ => throw FormatErrorException.Corrupt(what: "property key"),
    };

    /// Properties up to `end`, then their count.
    List<(string Name, JSValue Value)> Properties(char end)
    {
        var properties = new List<(string Name, JSValue Value)>();
        while (PeekTag() != (byte)end)
        {
            var name = Key(value: Value());
            properties.Add(item: (name, Value()));
        }
        _ = Tag();
        return reader.ReadVarint32() == properties.Count ? properties : throw FormatErrorException.Corrupt(what: "property count");
    }

    JSValue Object()
    {
        var id = NewId();
        var properties = new Dictionary<string, JSValue>(comparer: StringComparer.Ordinal);
        foreach (var (name, value) in Properties(end: '{'))
        {
            properties[name] = value;
        }
        return Remember(id: id, value: JSValue.FromObject(properties: properties));
    }

    JSValue DenseArray()
    {
        var id = NewId();
        var length = reader.ReadCount();
        var elements = new List<JSValue>(capacity: length);
        for (var index = 0; index < length; index++)
        {
            if (PeekTag() == (byte)'-')
            {
                _ = Tag();
                elements.Add(item: JSValue.Undefined);
            }
            else
            {
                elements.Add(item: Value());
            }
        }
        foreach (var (name, value) in Properties(end: '$'))
        {
            if (int.TryParse(s: name, style: NumberStyles.None, provider: CultureInfo.InvariantCulture, result: out var index) && index < elements.Count)
            {
                elements[index] = value;
            }
        }
        return reader.ReadVarint32() == length
            ? Remember(id: id, value: JSValue.FromArray(items: elements))
            : throw FormatErrorException.Corrupt(what: "array length");
    }

    JSValue SparseArray()
    {
        var id = NewId();
        var length = (long)reader.ReadVarint32();
        sparseElements += length;
        if (sparseElements > MaxSparseElements)
        {
            throw FormatErrorException.Unsupported(what: "sparse array length");
        }
        var elements = Enumerable.Repeat(element: JSValue.Undefined, count: (int)length).ToList();
        foreach (var (name, value) in Properties(end: '@'))
        {
            if (int.TryParse(s: name, style: NumberStyles.None, provider: CultureInfo.InvariantCulture, result: out var index) && index < elements.Count)
            {
                elements[index] = value;
            }
        }
        return reader.ReadVarint32() == length
            ? Remember(id: id, value: JSValue.FromArray(items: elements))
            : throw FormatErrorException.Corrupt(what: "array length");
    }

    JSValue Map()
    {
        var id = NewId();
        var items = new List<JSValue>();
        while (PeekTag() != (byte)':')
        {
            items.Add(item: Value());
        }
        _ = Tag();
        if (reader.ReadVarint32() != items.Count || items.Count % 2 != 0)
        {
            throw FormatErrorException.Corrupt(what: "map length");
        }
        var pairs = Enumerable.Range(start: 0, count: items.Count / 2)
            .Select(selector: index => new JSPair(Key: items[2 * index], Value: items[(2 * index) + 1]))
            .ToList();
        return Remember(id: id, value: JSValue.FromMap(pairs: pairs));
    }

    JSValue Set()
    {
        var id = NewId();
        var items = new List<JSValue>();
        while (PeekTag() != (byte)',')
        {
            items.Add(item: Value());
        }
        _ = Tag();
        return reader.ReadVarint32() == items.Count
            ? Remember(id: id, value: JSValue.FromSet(items: items))
            : throw FormatErrorException.Corrupt(what: "set length");
    }

    /// An ArrayBuffer, or the typed array or DataView that follows one.
    JSValue ArrayBuffer(bool resizable)
    {
        var id = NewId();
        var length = reader.ReadCount();
        if (resizable)
        {
            _ = reader.ReadVarint();
        }
        byte[] bytes = [.. reader.ReadBytes(count: length)];
        var buffer = Remember(id: id, value: JSValue.FromBytes(bytes: bytes));
        if (reader.IsAtEnd || PeekTag() != (byte)'V')
        {
            return buffer;
        }
        _ = Tag();
        var viewId = NewId();
        _ = reader.ReadByte(); // Which kind of view.
        var offset = reader.ReadVarint();
        var viewLength = reader.ReadVarint();
        if (Version >= 14)
        {
            _ = reader.ReadVarint(); // Flags.
        }
        if (offset > (ulong)length || viewLength > (ulong)length - offset)
        {
            throw FormatErrorException.Corrupt(what: "array buffer view");
        }
        return Remember(id: viewId, value: JSValue.FromBytes(bytes: bytes[(int)offset..(int)(offset + viewLength)]));
    }

    JSValue Error()
    {
        var id = NewId();
        string? message = null;
        while (true)
        {
            switch ((char)reader.ReadByte())
            {
                case 'E' or 'R' or 'F' or 'S' or 'T' or 'U':
                    // The prototype: which kind of error.
                    continue;
                case 'm':
                    message = String(tag: Tag());
                    break;
                case 's':
                    _ = String(tag: Tag()); // The stack.
                    break;
                case 'c':
                    _ = Value(); // The cause.
                    break;
                case '.':
                    return Remember(id: id, value: JSValue.FromError(message: message));
                default:
                    throw FormatErrorException.Corrupt(what: "error");
            }
        }
    }
}
