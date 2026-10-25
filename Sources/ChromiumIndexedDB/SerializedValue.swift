import Foundation

/// A JavaScript value, as V8 serialized it.
public indirect enum JSValue: Sendable, Equatable {
    case undefined
    case null
    case bool(Bool)
    case number(Double)
    case bigInt(negative: Bool, magnitude: [UInt8])
    case string(String)
    case date(Double)
    case array([JSValue])
    case object([String: JSValue])
    case map([JSPair])
    case set([JSValue])
    case regExp(pattern: String, flags: UInt32)
    case bytes([UInt8])
    case error(message: String?)

    public subscript(key: String) -> JSValue? {
        if case .object(let properties) = self { return properties[key] }
        return nil
    }

    public var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }
}

public struct JSPair: Sendable, Equatable {
    public var key: JSValue
    public var value: JSValue
}

/// How Blink stores a value in IndexedDB: a serialized script value, in Blink's envelope around V8's own format.
public enum SerializedValue {
    /// Which versions of the two formats a value was written with.
    public struct Format: Sendable, Hashable, CustomStringConvertible {
        /// Blink's version; 0 for values without Blink's envelope.
        public var blink: Int
        public var v8: Int
        /// Whether Blink compressed it.
        public var compressed: Bool

        public var description: String {
            "Blink \(blink), V8 \(v8)" + (compressed ? ", compressed" : "")
        }
    }

    public enum Decoded: Sendable, Equatable {
        case value(JSValue, Format)
        /// Too large to keep in the database, it's in a file: the record's external object at `index`.
        case inBlobFile(size: Int, index: Int)
    }

    static let versionTag: UInt8 = 0xFF
    /// Blink marks a value that needs more than deserializing with this in place of a version.
    static let needsProcessing: UInt8 = 0x11
    static let replacedWithBlob: UInt8 = 0x01
    static let compressedWithSnappy: UInt8 = 0x02
    static let trailerOffsetTag: UInt8 = 0xFE
    /// From this version, Blink's version comes before V8's header rather than being one with it.
    static let firstSeparateEnvelope = 16
    /// From this version, an offset and size of a trailer follow Blink's version.
    static let firstTrailerOffset = 21
    /// Versions before this one don't tag host objects, and aren't read.
    static let oldestV8 = 13

    /// Decodes a value Blink serialized: a record's value after its version.
    public static func decode(_ bytes: [UInt8]) throws -> Decoded {
        try decode(bytes, compressed: false)
    }

    private static func decode(_ bytes: [UInt8], compressed: Bool) throws -> Decoded {
        if bytes.count >= 3, bytes[0] == versionTag, bytes[1] == needsProcessing {
            switch bytes[2] {
            case replacedWithBlob:
                var reader = ByteReader(bytes, from: 3)
                let size = try reader.varint()
                let index = try reader.varint()
                guard size <= UInt64(Int.max), index <= UInt64(Int32.max) else { throw FormatError.corrupt("blob reference") }
                return .inBlobFile(size: Int(size), index: Int(index))
            case compressedWithSnappy:
                guard !compressed else { throw FormatError.corrupt("compressed twice") }
                return try decode(Snappy.decompress(bytes[3...]), compressed: true)
            default:
                break // Not a marker after all: read it as a value.
            }
        }
        var reader = ByteReader(bytes)
        var blink = 0
        var end = bytes.count
        if try reader.peek() == versionTag {
            _ = try reader.byte()
            blink = Int(try reader.varint32())
            if blink >= firstTrailerOffset {
                guard try reader.byte() == trailerOffsetTag else { throw FormatError.corrupt("trailer offset") }
                let offset = try reader.bigEndian(8)
                let size = try reader.bigEndian(4)
                if size > 0 {
                    guard offset >= UInt64(reader.offset), offset <= UInt64(bytes.count) else {
                        throw FormatError.corrupt("trailer offset")
                    }
                    end = Int(offset)
                }
            }
            if blink < firstSeparateEnvelope {
                // One version for both: V8's header is the same bytes.
                reader = ByteReader(bytes)
            }
        }
        var deserializer = V8Deserializer(reader: ByteReader(bytes, from: reader.offset, to: end))
        let value = try deserializer.read()
        return .value(value, Format(blink: blink, v8: deserializer.version, compressed: compressed))
    }
}

/// V8's serialization format, version 13 and later (`v8/src/objects/value-serializer.cc`). Reads what plain objects
/// hold; host objects, shared memory and WebAssembly aren't read.
struct V8Deserializer {
    private var reader: ByteReader
    private(set) var version = 0
    /// Objects, arrays and other values that later ones may refer to, by the ID V8 gave them in order.
    private var objects: [UInt32: JSValue] = [:]
    private var nextID: UInt32 = 0
    private var depth = 0
    /// Elements of sparse arrays so far: their length isn't bounded by the bytes that hold them, so a value has a budget.
    private var sparseElements = 0
    static let maxDepth = 64
    static let maxSparseElements = 1 << 16

    init(reader: ByteReader) {
        self.reader = reader
    }

    mutating func read() throws -> JSValue {
        guard try tag() == SerializedValue.versionTag else { throw FormatError.unsupported("V8 header") }
        version = Int(try reader.varint32())
        guard version >= SerializedValue.oldestV8 else { throw FormatError.unsupported("V8 version") }
        return try value()
    }

    /// The next tag, past any padding.
    private mutating func tag() throws -> UInt8 {
        var tag = try reader.byte()
        while tag == 0 {
            tag = try reader.byte()
        }
        return tag
    }

    private mutating func peekTag() throws -> UInt8 {
        while try reader.peek() == 0 {
            _ = try reader.byte()
        }
        return try reader.peek()
    }

    private mutating func newID() -> UInt32 {
        defer { nextID &+= 1 }
        return nextID
    }

    private mutating func value() throws -> JSValue {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxDepth else { throw FormatError.unsupported("nesting") }
        let tag = try tag()
        switch Character(Unicode.Scalar(tag)) {
        case "?":
            _ = try reader.varint32()
            return try value()
        case "_": return .undefined
        case "0": return .null
        case "T": return .bool(true)
        case "F": return .bool(false)
        case "I":
            let zigzag = try reader.varint32()
            return .number(Double(Int32(bitPattern: (zigzag >> 1) ^ (0 &- (zigzag & 1)))))
        case "U": return .number(Double(try reader.varint32()))
        case "N": return .number(try reader.double())
        case "Z": return try bigInt()
        case "\"", "c", "S": return .string(try string(tag))
        case "^":
            let id = try reader.varint32()
            guard id < nextID else { throw FormatError.corrupt("object reference") }
            // An object that isn't finished yet is a cycle, which a value type can't hold.
            return objects[id] ?? .undefined
        case "o": return try object()
        case "A": return try denseArray()
        case "a": return try sparseArray()
        case "D":
            let id = newID()
            return remember(.date(try reader.double()), id)
        case "y", "x":
            let id = newID()
            return remember(.bool(tag == UInt8(ascii: "y")), id)
        case "n":
            let id = newID()
            return remember(.number(try reader.double()), id)
        case "z":
            let id = newID()
            return remember(try bigInt(), id)
        case "s":
            let id = newID()
            return remember(.string(try string(try self.tag())), id)
        case "R":
            let id = newID()
            let pattern = try string(try self.tag())
            return remember(.regExp(pattern: pattern, flags: try reader.varint32()), id)
        case ";": return try map()
        case "'": return try set()
        case "B", "~": return try arrayBuffer(resizable: tag == UInt8(ascii: "~"))
        case "r": return try error()
        default:
            throw FormatError.unsupported("V8 tag \(tag)")
        }
    }

    private mutating func remember(_ value: JSValue, _ id: UInt32) -> JSValue {
        objects[id] = value
        return value
    }

    private mutating func string(_ tag: UInt8) throws -> String {
        let length = try reader.count()
        let bytes = try reader.bytes(length)
        switch tag {
        case UInt8(ascii: "\""):
            // Latin-1: each byte is the code point.
            return String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
        case UInt8(ascii: "c"):
            guard length % 2 == 0 else { throw FormatError.corrupt("two-byte string") }
            var units: [UInt16] = []
            units.reserveCapacity(length / 2)
            var index = bytes.startIndex
            while index < bytes.endIndex {
                units.append(UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
                index += 2
            }
            return String(decoding: units, as: UTF16.self)
        case UInt8(ascii: "S"):
            return String(decoding: bytes, as: UTF8.self)
        default:
            throw FormatError.corrupt("string tag")
        }
    }

    private mutating func bigInt() throws -> JSValue {
        let bitfield = try reader.varint()
        let length = bitfield >> 1
        guard length <= UInt64(reader.remaining) else { throw FormatError.truncated }
        return .bigInt(negative: bitfield & 1 == 1, magnitude: Array(try reader.bytes(Int(length))))
    }

    /// A property's key: a string, or an array index.
    private func key(_ value: JSValue) throws -> String {
        switch value {
        case .string(let text):
            return text
        case .number(let number) where number.rounded() == number && abs(number) < 1e15:
            return String(Int64(number))
        case .number(let number):
            return String(number)
        default:
            throw FormatError.corrupt("property key")
        }
    }

    /// Properties up to `end`, then their count.
    private mutating func properties(until end: Character) throws -> [(String, JSValue)] {
        var properties: [(String, JSValue)] = []
        while try peekTag() != UInt8(ascii: end.unicodeScalars.first!) {
            let name = try key(try value())
            properties.append((name, try value()))
        }
        _ = try tag()
        guard try reader.varint32() == properties.count else { throw FormatError.corrupt("property count") }
        return properties
    }

    private mutating func object() throws -> JSValue {
        let id = newID()
        var object: [String: JSValue] = [:]
        for (name, value) in try properties(until: "{") {
            object[name] = value
        }
        return remember(.object(object), id)
    }

    private mutating func denseArray() throws -> JSValue {
        let id = newID()
        let length = try reader.count()
        var elements: [JSValue] = []
        elements.reserveCapacity(length)
        for _ in 0..<length {
            if try peekTag() == UInt8(ascii: "-") {
                _ = try tag()
                elements.append(.undefined)
            } else {
                elements.append(try value())
            }
        }
        for (name, value) in try properties(until: "$") {
            if let index = Int(name), elements.indices.contains(index) {
                elements[index] = value
            }
        }
        guard try reader.varint32() == length else { throw FormatError.corrupt("array length") }
        return remember(.array(elements), id)
    }

    private mutating func sparseArray() throws -> JSValue {
        let id = newID()
        let length = Int(try reader.varint32())
        sparseElements += length
        guard sparseElements <= Self.maxSparseElements else { throw FormatError.unsupported("sparse array length") }
        var elements = [JSValue](repeating: .undefined, count: length)
        for (name, value) in try properties(until: "@") {
            if let index = Int(name), elements.indices.contains(index) {
                elements[index] = value
            }
        }
        guard try reader.varint32() == length else { throw FormatError.corrupt("array length") }
        return remember(.array(elements), id)
    }

    private mutating func map() throws -> JSValue {
        let id = newID()
        var items: [JSValue] = []
        while try peekTag() != UInt8(ascii: ":") {
            items.append(try value())
        }
        _ = try tag()
        guard try reader.varint32() == items.count, items.count % 2 == 0 else { throw FormatError.corrupt("map length") }
        let pairs = stride(from: 0, to: items.count, by: 2).map { JSPair(key: items[$0], value: items[$0 + 1]) }
        return remember(.map(pairs), id)
    }

    private mutating func set() throws -> JSValue {
        let id = newID()
        var items: [JSValue] = []
        while try peekTag() != UInt8(ascii: ",") {
            items.append(try value())
        }
        _ = try tag()
        guard try reader.varint32() == items.count else { throw FormatError.corrupt("set length") }
        return remember(.set(items), id)
    }

    /// An ArrayBuffer, or the typed array or DataView that follows one.
    private mutating func arrayBuffer(resizable: Bool) throws -> JSValue {
        let id = newID()
        let length = try reader.count()
        if resizable {
            _ = try reader.varint()
        }
        let buffer = remember(.bytes(Array(try reader.bytes(length))), id)
        guard !reader.isAtEnd, try peekTag() == UInt8(ascii: "V") else { return buffer }
        _ = try tag()
        let viewID = newID()
        _ = try reader.byte() // Which kind of view.
        let offset = try reader.varint()
        let viewLength = try reader.varint()
        if version >= 14 {
            _ = try reader.varint() // Flags.
        }
        guard offset <= UInt64(length), viewLength <= UInt64(length) - offset, case .bytes(let bytes) = buffer else {
            throw FormatError.corrupt("array buffer view")
        }
        return remember(.bytes(Array(bytes[Int(offset)..<Int(offset + viewLength)])), viewID)
    }

    private mutating func error() throws -> JSValue {
        let id = newID()
        var message: String?
        while true {
            switch Character(Unicode.Scalar(try reader.byte())) {
            case "E", "R", "F", "S", "T", "U":
                continue // The prototype: which kind of error.
            case "m":
                message = try string(try tag())
            case "s":
                _ = try string(try tag()) // The stack.
            case "c":
                _ = try value() // The cause.
            case ".":
                return remember(.error(message: message), id)
            default:
                throw FormatError.corrupt("error")
            }
        }
    }
}
