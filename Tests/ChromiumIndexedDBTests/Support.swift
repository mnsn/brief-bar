import Foundation
@testable import ChromiumIndexedDB

// MARK: - The fixture

/// `Tests/Fixtures/ChromiumIndexedDB`: an IndexedDB that Microsoft Edge wrote, with made-up data shaped like Teams'
/// (see make-fixture.html there). The first run wrote every record; the second, appended to the same log, read Avery's
/// chat, added a message to Sam's and deleted the channel.
enum Fixture {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ChromiumIndexedDB", isDirectory: true)
    static let indexedDB = folder.appendingPathComponent("IndexedDB", isDirectory: true)
    static let leveldb = indexedDB.appendingPathComponent("http_teams.localhost_8766.indexeddb.leveldb", isDirectory: true)
    static let log = leveldb.appendingPathComponent("000003.log")
    /// Where the second run's writes start in the log.
    static let firstRunLength = 39_357

    static let tenant = "00000000-1111-4222-8333-444444444444"
    static let me = "99999999-ffff-4fff-8fff-999999999999"
    static let conversationsDatabase = "Teams:conversation-manager:react-web-client:\(tenant):\(me):en-us"
    static let replyChainsDatabase = "Teams:replychain-manager:react-web-client:\(tenant):\(me):en-us"

    static let avery = "19:11111111-aaaa-4aaa-8aaa-111111111111_99999999-ffff-4fff-8fff-999999999999@unq.gbl.spaces"
    static let sam = "19:22222222-bbbb-4bbb-8bbb-222222222222_99999999-ffff-4fff-8fff-999999999999@unq.gbl.spaces"
    static let crew = "19:0123456789abcdef0123456789abcdef@thread.v2"
    static let sync = "19:meeting_ZmFrZS1tZWV0aW5nLWlkLWZvci10ZXN0cw@thread.v2"
    static let channel = "19:abcdefabcdefabcdefabcdefabcdef12@thread.tacv2"
    static let big = "19:bigbigbigbigbigbigbigbigbigbig12@thread.v2"
    static let wrapped = "19:wrapwrapwrapwrapwrapwrapwrapwrap@thread.v2"
    /// 2026-10-18T10:00:00Z, in milliseconds: the made-up message IDs count from it.
    static let base: Int64 = 1_792_317_600_000
}

// MARK: - Files

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("BriefBarIndexedDBTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

func write(_ bytes: [UInt8], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes).write(to: url)
}

// MARK: - Encodings

func varint(_ value: UInt64) -> [UInt8] {
    var value = value
    var bytes: [UInt8] = []
    while value >= 0x80 {
        bytes.append(UInt8(value & 0x7F) | 0x80)
        value >>= 7
    }
    return bytes + [UInt8(value)]
}

func littleEndian(_ value: UInt64, _ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
}

/// Snappy with literals only: valid, and enough to check that compressed blocks and values are read.
func snappyLiterals(_ bytes: [UInt8]) -> [UInt8] {
    var output = varint(UInt64(bytes.count))
    var start = 0
    while start < bytes.count {
        let count = min(60_000, bytes.count - start)
        if count <= 60 {
            output.append(UInt8(count - 1) << 2)
        } else {
            output += [61 << 2] + littleEndian(UInt64(count - 1), 2)
        }
        output += bytes[start..<start + count]
        start += count
    }
    return output
}

/// Writes LevelDB logs as LevelDB does: 32 KiB blocks of checksummed records, a batch split across blocks.
struct LogWriter {
    private(set) var bytes: [UInt8] = []

    static func batch(sequence: UInt64, _ writes: [(key: [UInt8], value: [UInt8]?)]) -> [UInt8] {
        var batch = littleEndian(sequence, 8) + littleEndian(UInt64(writes.count), 4)
        for write in writes {
            batch.append(write.value == nil ? 0 : 1)
            batch += varint(UInt64(write.key.count)) + write.key
            if let value = write.value {
                batch += varint(UInt64(value.count)) + value
            }
        }
        return batch
    }

    mutating func add(_ batch: [UInt8]) {
        var rest = batch[...]
        var first = true
        repeat {
            let left = LevelDBLog.blockSize - bytes.count % LevelDBLog.blockSize
            if left < LevelDBLog.headerSize {
                bytes += [UInt8](repeating: 0, count: left)
                continue
            }
            let count = min(rest.count, left - LevelDBLog.headerSize)
            let last = count == rest.count
            let type: UInt8 = first && last ? 1 : first ? 2 : last ? 4 : 3
            let data = rest.prefix(count)
            let checksum = CRC32C.mask(CRC32C.checksum(data, extending: CRC32C.checksum([type])))
            bytes += littleEndian(UInt64(checksum), 4) + littleEndian(UInt64(count), 2) + [type] + data
            rest = rest.dropFirst(count)
            first = false
        } while !rest.isEmpty
    }
}

/// Writes LevelDB tables: data blocks of `perBlock` entries, an index of their last keys, an empty metaindex, and the
/// footer.
enum TableWriter {
    struct Entry {
        var key: [UInt8]
        var sequence: UInt64
        var value: [UInt8]?
    }

    static func table(
        _ entries: [Entry], perBlock: Int = 2, compress: Bool = false, restartInterval: Int = 16,
        indexKey: ([UInt8]) -> [UInt8] = { $0 }
    ) -> [UInt8] {
        var file: [UInt8] = []
        func addBlock(_ contents: [UInt8]) -> [UInt8] {
            let stored = compress ? snappyLiterals(contents) : contents
            let type: UInt8 = compress ? 1 : 0
            let handle = varint(UInt64(file.count)) + varint(UInt64(stored.count))
            let checksum = CRC32C.mask(CRC32C.checksum([type], extending: CRC32C.checksum(stored)))
            file += stored + [type] + littleEndian(UInt64(checksum), 4)
            return handle
        }
        var index: [(key: [UInt8], value: [UInt8])] = []
        for start in stride(from: 0, to: entries.count, by: perBlock) {
            let slice = entries[start..<min(start + perBlock, entries.count)]
            let pairs = slice.map { entry in
                (internalKey(entry.key, entry.sequence, deleted: entry.value == nil), entry.value ?? [])
            }
            let handle = addBlock(block(pairs, restartInterval: restartInterval))
            index.append((indexKey(pairs.last!.0), handle))
        }
        let metaindex = addBlock(block([], restartInterval: 1))
        let indexHandle = addBlock(block(index, restartInterval: 1))
        var footer = metaindex + indexHandle
        footer += [UInt8](repeating: 0, count: 40 - footer.count)
        file += footer + littleEndian(LevelDBTable.magic, 8)
        return file
    }

    static func internalKey(_ key: [UInt8], _ sequence: UInt64, deleted: Bool) -> [UInt8] {
        key + littleEndian(sequence << 8 | (deleted ? 0 : 1), 8)
    }

    static func block(_ pairs: [([UInt8], [UInt8])], restartInterval: Int) -> [UInt8] {
        var block: [UInt8] = []
        var restarts: [UInt32] = []
        var previous: [UInt8] = []
        for (index, (key, value)) in pairs.enumerated() {
            var shared = 0
            if index % restartInterval == 0 {
                restarts.append(UInt32(block.count))
            } else {
                while shared < min(key.count, previous.count), key[shared] == previous[shared] {
                    shared += 1
                }
            }
            block += varint(UInt64(shared)) + varint(UInt64(key.count - shared)) + varint(UInt64(value.count))
            block += key[shared...] + value
            previous = key
        }
        if restarts.isEmpty { restarts = [0] }
        for restart in restarts {
            block += littleEndian(UInt64(restart), 4)
        }
        return block + littleEndian(UInt64(restarts.count), 4)
    }
}

/// Chromium's IndexedDB key encodings.
enum Keys {
    static func prefix(_ database: Int64, _ objectStore: Int64, _ index: Int64) -> [UInt8] {
        func bytes(_ value: Int64) -> [UInt8] {
            var bytes = littleEndian(UInt64(value), 8)
            while bytes.count > 1, bytes.last == 0 { bytes.removeLast() }
            return bytes
        }
        let parts = [bytes(database), bytes(objectStore), bytes(index)]
        let first = UInt8(parts[0].count - 1) << 5 | UInt8(parts[1].count - 1) << 2 | UInt8(parts[2].count - 1)
        return [first] + parts.joined()
    }

    static func utf16(_ text: String) -> [UInt8] {
        text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }

    static func stringWithLength(_ text: String) -> [UInt8] {
        varint(UInt64(text.utf16.count)) + utf16(text)
    }

    static func databaseName(_ name: String, origin: String = "made_up_origin@1") -> [UInt8] {
        prefix(0, 0, 0) + [201] + stringWithLength(origin) + stringWithLength(name)
    }

    static func objectStoreName(_ database: Int64, _ objectStore: Int64) -> [UInt8] {
        prefix(database, 0, 0) + [50] + varint(UInt64(objectStore)) + [0]
    }

    static func record(_ database: Int64, _ objectStore: Int64, _ key: String) -> [UInt8] {
        prefix(database, objectStore, 1) + [1] + stringWithLength(key)
    }

    static func blobEntry(_ database: Int64, _ objectStore: Int64, _ key: String) -> [UInt8] {
        prefix(database, objectStore, 3) + [1] + stringWithLength(key)
    }
}

/// Writes V8's serialization format, version 16, inside Blink's version 21 envelope, for made-up values.
struct V8Writer {
    private(set) var bytes: [UInt8] = []

    /// A record's value: its version, Blink's envelope and V8's header, then `body`.
    static func record(version: UInt64 = 1, _ body: (inout V8Writer) -> Void) -> [UInt8] {
        varint(version) + serialized(body)
    }

    static func serialized(_ body: (inout V8Writer) -> Void) -> [UInt8] {
        var writer = V8Writer()
        writer.bytes = [0xFF, 21, 0xFE] + [UInt8](repeating: 0, count: 12) + [0xFF, 16]
        body(&writer)
        return writer.bytes
    }

    mutating func tag(_ tag: Character) {
        bytes.append(UInt8(ascii: tag.unicodeScalars.first!))
    }

    mutating func string(_ text: String) {
        if text.unicodeScalars.allSatisfy({ $0.value < 256 }) {
            tag("\"")
            bytes += varint(UInt64(text.unicodeScalars.count)) + text.unicodeScalars.map { UInt8($0.value) }
        } else {
            bytes.append(0) // Padding, as V8 aligns two-byte strings.
            tag("c")
            let units = Array(text.utf16)
            bytes += varint(UInt64(units.count * 2)) + units.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        }
    }

    mutating func int(_ value: Int32) {
        tag("I")
        let zigzag = UInt32(bitPattern: (value << 1) ^ (value >> 31))
        bytes += varint(UInt64(zigzag))
    }

    mutating func double(_ value: Double) {
        tag("N")
        bytes += littleEndian(value.bitPattern, 8)
    }

    mutating func object(_ properties: [(String, (inout V8Writer) -> Void)]) {
        tag("o")
        for (key, value) in properties {
            string(key)
            value(&self)
        }
        tag("{")
        bytes += varint(UInt64(properties.count))
    }

    mutating func array(_ elements: [(inout V8Writer) -> Void]) {
        tag("A")
        bytes += varint(UInt64(elements.count))
        for element in elements {
            element(&self)
        }
        tag("$")
        bytes += varint(0) + varint(UInt64(elements.count))
    }
}

/// A made-up Teams conversation: its ID and read marker, and its newest message's ID.
func conversation(_ id: String, horizon: String, lastMessage: Int64) -> (inout V8Writer) -> Void {
    { writer in
        writer.object([
            ("id", { $0.string(id) }),
            ("properties", { $0.object([("consumptionhorizon", { $0.string(horizon) })]) }),
            ("lastMessage", { $0.object([("id", { $0.string(String(lastMessage)) })]) }),
        ])
    }
}
