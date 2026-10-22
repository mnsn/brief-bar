import Foundation

/// A Chromium IndexedDB backing store on LevelDB: an origin's `<origin>.indexeddb.leveldb` folder, with
/// `<origin>.indexeddb.blob` next to it for values too large for the database. Read-only, without its lock.
public struct IndexedDBFolder: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var leveldb: LevelDBFolder { LevelDBFolder(url: url) }

    public var blobFolder: URL {
        let name = url.lastPathComponent
        let base = name.hasSuffix(".leveldb") ? String(name.dropLast(".leveldb".count)) : name
        return url.deletingLastPathComponent().appendingPathComponent(base + ".blob", isDirectory: true)
    }

    public struct StoreID: Hashable, Sendable, Comparable {
        public var database: Int64
        public var objectStore: Int64

        public init(database: Int64, objectStore: Int64) {
            self.database = database
            self.objectStore = objectStore
        }

        public static func < (a: StoreID, b: StoreID) -> Bool {
            (a.database, a.objectStore) < (b.database, b.objectStore)
        }
    }

    public struct RecordKey: Hashable, Sendable {
        public var store: StoreID
        public var key: IDBKey

        public init(store: StoreID, key: IDBKey) {
            self.store = store
            self.key = key
        }
    }

    /// Which databases and object stores there are, by ID.
    public struct Catalog: Sendable, Equatable {
        public var databases: [Int64: String] = [:]
        public var objectStores: [StoreID: String] = [:]

        public init() {}

        public func stores(where matches: (_ database: String, _ objectStore: String) -> Bool) -> Set<StoreID> {
            Set(objectStores.compactMap { id, name in
                databases[id.database].map { matches($0, name) } == true ? id : nil
            })
        }

        /// Takes in a write to a metadata key; returns whether it named or renamed something.
        @discardableResult
        public mutating func take(_ key: IndexedDBKey, value: [UInt8]?) -> Bool {
            switch key {
            case .databaseName(_, let name):
                guard let value, let id = try? IndexedDBKey.databaseID(value) else { return false }
                defer { databases[id] = name }
                return databases[id] != name
            case .objectStoreName(let database, let objectStore):
                let id = StoreID(database: database, objectStore: objectStore)
                let name = value.flatMap { try? IndexedDBKey.string($0) }
                defer { objectStores[id] = name }
                return objectStores[id] != name
            default:
                return false
            }
        }
    }

    /// The databases and object stores, from the blocks that hold metadata only.
    public func catalog() throws -> (Catalog, LevelDBFolder.Read) {
        let read = try leveldb.read(mayHold: Self.mayHoldMetadata, keep: Self.isMetadata)
        var catalog = Catalog()
        for (key, value) in read.values {
            if let key = try? IndexedDBKey(key) {
                catalog.take(key, value: value)
            }
        }
        return (catalog, read)
    }

    public struct Records: Sendable {
        /// Each record's raw value: its version, then the serialized value.
        public var values: [RecordKey: [UInt8]] = [:]
        /// The external objects of the records that have any.
        public var externalObjects: [RecordKey: [ExternalObject]] = [:]
        public var unreadableKeys = 0
        public var read: LevelDBFolder.Read
    }

    /// The records of `stores` as they are now, from only the blocks that may hold them.
    public func records(in stores: Set<StoreID>) throws -> Records {
        let prefixes = Set(stores.flatMap { store in
            [KeyPrefix.records, KeyPrefix.blobEntries].map {
                KeyPrefix(database: store.database, objectStore: store.objectStore, index: $0)
            }
        })
        let read = try leveldb.read(mayHold: Self.mayHold(prefixes)) { key in
            KeyPrefix(key).map(prefixes.contains) ?? false
        }
        var records = Records(read: read)
        for (key, value) in read.values {
            switch try? IndexedDBKey(key) {
            case .record(let database, let objectStore, let id)?:
                records.values[RecordKey(store: StoreID(database: database, objectStore: objectStore), key: id)] = value
            case .blobEntry(let database, let objectStore, let id)?:
                if let objects = try? IndexedDBKey.externalObjects(value) {
                    records.externalObjects[RecordKey(store: StoreID(database: database, objectStore: objectStore), key: id)] = objects
                }
            default:
                records.unreadableKeys += 1
            }
        }
        return records
    }

    public struct Value: Sendable, Equatable {
        public var value: JSValue
        public var format: SerializedValue.Format
        /// Whether it was too large for the database, and came from a blob file.
        public var fromBlobFile: Bool
    }

    /// A record's value: after its version, the serialized value, or where in a blob file it is.
    public func value(of raw: [UInt8], key: RecordKey, externalObjects: [ExternalObject]?) throws -> Value {
        var reader = ByteReader(raw)
        _ = try reader.varint() // The record's version.
        switch try SerializedValue.decode(Array(raw[reader.offset...])) {
        case .value(let value, let format):
            return Value(value: value, format: format, fromBlobFile: false)
        case .inBlobFile(_, let index):
            guard let objects = externalObjects, objects.indices.contains(index),
                  let number = objects[index].blobNumber
            else { throw FormatError.corrupt("blob reference") }
            let (bytes, _) = try LevelDBFolder.contents(of: blobFile(database: key.store.database, number: number))
            guard case .value(let value, let format) = try SerializedValue.decode(bytes) else {
                throw FormatError.corrupt("blob file")
            }
            return Value(value: value, format: format, fromBlobFile: true)
        }
    }

    /// Where Chromium keeps a blob: in a folder per database, and one per 256 blobs, each named in hexadecimal.
    public func blobFile(database: Int64, number: Int64) -> URL {
        blobFolder
            .appendingPathComponent(String(database, radix: 16), isDirectory: true)
            .appendingPathComponent(String(format: "%02x", UInt32((number >> 8) & 0xFF)), isDirectory: true)
            .appendingPathComponent(String(number, radix: 16))
    }

    /// Global metadata, and each database's: their key prefixes have no object store.
    public static func isMetadata(_ key: ArraySlice<UInt8>) -> Bool {
        guard let prefix = KeyPrefix(key) else { return false }
        return prefix.database == 0 || prefix.objectStore == 0
    }

    /// Whether keys from `lower` to `upper` may include metadata. Keys sort by prefix first, so a database's metadata,
    /// with object store 0, comes before its object stores, and the global metadata, with database 0, before all.
    public static func mayHoldMetadata(_ lower: [UInt8]?, _ upper: [UInt8]) -> Bool {
        guard let lower else { return true }
        guard let low = KeyPrefix(lower), let high = KeyPrefix(upper) else { return true }
        return low.database == 0 || low.database < high.database || low.objectStore == 0
    }

    /// Whether keys from `lower` to `upper` may include ones with any of `prefixes`.
    public static func mayHold(_ prefixes: Set<KeyPrefix>) -> ([UInt8]?, [UInt8]) -> Bool {
        { lower, upper in
            guard let high = KeyPrefix(upper) else { return true }
            var low: KeyPrefix?
            if let lower {
                guard let decoded = KeyPrefix(lower) else { return true }
                low = decoded
            }
            return prefixes.contains { prefix in (low.map { $0 <= prefix } ?? true) && prefix <= high }
        }
    }
}
