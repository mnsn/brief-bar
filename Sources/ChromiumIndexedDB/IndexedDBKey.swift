/// The start of every key Chromium's IndexedDB writes to LevelDB: the database, object store and index it's about.
/// Chromium's comparator orders keys by it first, so all the keys of one object store are together.
public struct KeyPrefix: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var database: Int64
    public var objectStore: Int64
    public var index: Int64

    /// `index` for an object store's records, and for the files that hold values too large for the database.
    public static let records: Int64 = 1
    public static let blobEntries: Int64 = 3

    public init(database: Int64, objectStore: Int64, index: Int64) {
        self.database = database
        self.objectStore = objectStore
        self.index = index
    }

    /// The prefix of `key`, and how many bytes it takes; nil when `key` doesn't start with one.
    public static func decode<Bytes: Collection<UInt8>>(_ key: Bytes) -> (prefix: KeyPrefix, length: Int)? {
        guard let first = key.first else { return nil }
        let lengths = [Int((first >> 5) & 7) + 1, Int((first >> 2) & 7) + 1, Int(first & 3) + 1]
        let total = 1 + lengths.reduce(0, +)
        guard key.count >= total else { return nil }
        var values: [Int64] = []
        var index = key.index(after: key.startIndex)
        for length in lengths {
            var value: UInt64 = 0
            for shift in 0..<length {
                value |= UInt64(key[index]) << (8 * UInt64(shift))
                index = key.index(after: index)
            }
            guard value <= UInt64(Int64.max) else { return nil }
            values.append(Int64(value))
        }
        return (KeyPrefix(database: values[0], objectStore: values[1], index: values[2]), total)
    }

    public init?<Bytes: Collection<UInt8>>(_ key: Bytes) {
        guard let decoded = Self.decode(key) else { return nil }
        self = decoded.prefix
    }

    public static func < (a: KeyPrefix, b: KeyPrefix) -> Bool {
        (a.database, a.objectStore, a.index) < (b.database, b.objectStore, b.index)
    }

    public var description: String { "\(database).\(objectStore).\(index)" }
}

/// An IndexedDB key, as the object store's records are keyed.
public indirect enum IDBKey: Hashable, Sendable {
    case string(String)
    case number(Double)
    case date(Double)
    case binary([UInt8])
    case array([IDBKey])
    case minKey
    case null

    public var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }
}

/// One of an object store's external objects: a file next to the database that holds a value too large for it.
public struct ExternalObject: Sendable, Equatable {
    public enum Kind: UInt8, Sendable {
        case blob = 0, file, fileSystemAccessHandle
    }

    public var kind: Kind
    /// Which file: its name is the number in hexadecimal.
    public var blobNumber: Int64?
    public var size: UInt64?
}

/// What a key Chromium's IndexedDB writes to LevelDB is about, of the ones read here.
public enum IndexedDBKey: Sendable, Equatable {
    /// Which ID the database has that this origin calls `name`.
    case databaseName(origin: String, name: String)
    /// An object store's name.
    case objectStoreName(database: Int64, objectStore: Int64)
    /// A record of an object store: its value is the record's version, then the value Blink serialized.
    case record(database: Int64, objectStore: Int64, key: IDBKey)
    /// The external objects of a record: the files with its values too large for the database.
    case blobEntry(database: Int64, objectStore: Int64, key: IDBKey)
    /// Other metadata, which doesn't say which databases and object stores there are.
    case otherMetadata
    /// Index entries, and the keys that only say that a record exists.
    case other

    static let databaseNameType: UInt8 = 201
    static let objectStoreMetadataType: UInt8 = 50
    static let objectStoreNameType: UInt8 = 0

    public init<Bytes: Collection<UInt8>>(_ key: Bytes) throws {
        let bytes = Array(key)
        guard let (prefix, length) = KeyPrefix.decode(bytes) else { throw FormatError.corrupt("key prefix") }
        var reader = ByteReader(bytes, from: length)
        switch (prefix.database, prefix.objectStore, prefix.index) {
        case (0, 0, 0):
            guard !reader.isAtEnd, try reader.byte() == Self.databaseNameType else {
                self = .otherMetadata
                return
            }
            let origin = try Self.stringWithLength(&reader)
            self = .databaseName(origin: origin, name: try Self.stringWithLength(&reader))
        case (_, 0, 0):
            guard !reader.isAtEnd, try reader.byte() == Self.objectStoreMetadataType else {
                self = .otherMetadata
                return
            }
            let objectStore = try reader.varint()
            guard objectStore <= UInt64(Int64.max), try reader.byte() == Self.objectStoreNameType else {
                self = .otherMetadata
                return
            }
            self = .objectStoreName(database: prefix.database, objectStore: Int64(objectStore))
        case (_, _, KeyPrefix.records):
            self = .record(database: prefix.database, objectStore: prefix.objectStore, key: try Self.idbKey(&reader))
        case (_, _, KeyPrefix.blobEntries):
            self = .blobEntry(database: prefix.database, objectStore: prefix.objectStore, key: try Self.idbKey(&reader))
        default:
            self = .other
        }
    }

    /// A database ID: a little-endian integer of up to 8 bytes.
    public static func databaseID(_ value: [UInt8]) throws -> Int64 {
        guard (1...8).contains(value.count) else { throw FormatError.corrupt("database ID") }
        var reader = ByteReader(value)
        let id = try reader.littleEndian(value.count)
        guard id <= UInt64(Int64.max) else { throw FormatError.corrupt("database ID") }
        return Int64(id)
    }

    /// A name stored as a value: UTF-16, big-endian, the whole value.
    public static func string(_ value: [UInt8]) throws -> String {
        var reader = ByteReader(value)
        return try utf16(&reader, count: value.count / 2)
    }

    /// The external objects of a record (a blob entry's value).
    public static func externalObjects(_ value: [UInt8]) throws -> [ExternalObject] {
        var reader = ByteReader(value)
        var objects: [ExternalObject] = []
        while !reader.isAtEnd {
            guard let kind = ExternalObject.Kind(rawValue: try reader.byte()) else {
                throw FormatError.unsupported("external object")
            }
            switch kind {
            case .blob, .file:
                let number = try reader.varint()
                _ = try stringWithLength(&reader) // MIME type
                let size = try reader.varint()
                if kind == .file {
                    _ = try stringWithLength(&reader) // File name
                    _ = try reader.varint() // Last modified
                }
                guard number <= UInt64(Int64.max) else { throw FormatError.corrupt("blob number") }
                objects.append(ExternalObject(kind: kind, blobNumber: Int64(number), size: size))
            case .fileSystemAccessHandle:
                try reader.skip(reader.count())
                objects.append(ExternalObject(kind: kind, blobNumber: nil, size: nil))
            }
        }
        return objects
    }

    static func stringWithLength(_ reader: inout ByteReader) throws -> String {
        let length = try reader.varint()
        guard length <= UInt64(reader.remaining / 2) else { throw FormatError.truncated }
        return try utf16(&reader, count: Int(length))
    }

    static func utf16(_ reader: inout ByteReader, count: Int) throws -> String {
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0..<count {
            units.append(UInt16(try reader.bigEndian(2)))
        }
        return String(decoding: units, as: UTF16.self)
    }

    static func idbKey(_ reader: inout ByteReader, depth: Int = 0) throws -> IDBKey {
        guard depth < 32 else { throw FormatError.unsupported("key nesting") }
        switch try reader.byte() {
        case 0: return .null
        case 1: return .string(try stringWithLength(&reader))
        case 2: return .date(try reader.double())
        case 3: return .number(try reader.double())
        case 4:
            let count = try reader.count()
            var keys: [IDBKey] = []
            for _ in 0..<count {
                keys.append(try idbKey(&reader, depth: depth + 1))
            }
            return .array(keys)
        case 5: return .minKey
        case 6: return .binary(Array(try reader.bytes(reader.count())))
        default: throw FormatError.unsupported("key type")
        }
    }
}
