import Foundation

/// A LevelDB table file (`.ldb`, or `.sst` for older ones): blocks of sorted keys and their values, an index with
/// each block's last key, and a footer that says where the index is. LevelDB never changes a table once written.
public enum LevelDBTable {
    static let footerSize = 48
    static let magic: UInt64 = 0xDB47_7524_8B80_FB57
    static let blockTrailerSize = 5

    public struct Read: Sendable {
        public var entries: [LevelDBEntry]
        public var blocksRead = 0
        public var blocksSkipped = 0
        /// Whether a block read ended at the key its index entry names, as LevelDB's own comparator leaves it; nil
        /// when no block was read. Skipping blocks by their index keys relies on it.
        public var separatorsExact: Bool?
    }

    /// The entries whose keys `keep` accepts, from the blocks `mayHold` doesn't rule out. A block holds the keys
    /// after the previous block's last key (nil for the first block) up to its own last key: `mayHold` gets those
    /// two user keys.
    public static func read(
        _ url: URL,
        mayHold: ([UInt8]?, [UInt8]) -> Bool = { _, _ in true },
        keep: (ArraySlice<UInt8>) -> Bool = { _ in true }
    ) throws -> Read {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = Int(try file.seekToEnd())
        guard size >= footerSize else { throw FormatError.corrupt("table footer") }
        var footer = ByteReader(try readBytes(file, at: size - footerSize, count: footerSize))
        _ = try handle(&footer) // The metaindex: Chromium's tables have a bloom filter, which isn't needed here.
        let indexHandle = try handle(&footer)
        var magicReader = ByteReader(footer.bytes, from: footerSize - 8)
        guard try magicReader.fixed64() == magic else { throw FormatError.corrupt("table magic") }

        let index = try block(file, indexHandle, fileSize: size)
        var read = Read(entries: [])
        var lower: [UInt8]?
        for (separator, value) in try blockEntries(index) {
            var reader = ByteReader(Array(value))
            let dataHandle = try handle(&reader)
            guard separator.count >= 8 else { throw FormatError.corrupt("index key") }
            let upper = Array(separator.dropLast(8))
            defer { lower = upper }
            guard mayHold(lower, upper) else {
                read.blocksSkipped += 1
                continue
            }
            read.blocksRead += 1
            let entries = try blockEntries(try block(file, dataHandle, fileSize: size))
            if let last = entries.last?.key {
                read.separatorsExact = (read.separatorsExact ?? true) && last == separator
            }
            for (internalKey, value) in entries {
                guard internalKey.count >= 8 else { throw FormatError.corrupt("table key") }
                let userKey = internalKey[internalKey.startIndex..<(internalKey.endIndex - 8)]
                guard keep(userKey) else { continue }
                var trailer = ByteReader(Array(internalKey.suffix(8)))
                let tag = try trailer.fixed64()
                switch tag & 0xFF {
                case 1: read.entries.append(LevelDBEntry(sequence: tag >> 8, key: Array(userKey), value: Array(value)))
                case 0: read.entries.append(LevelDBEntry(sequence: tag >> 8, key: Array(userKey), value: nil))
                default: throw FormatError.corrupt("table key kind")
                }
            }
        }
        return read
    }

    struct Handle {
        var offset: Int
        var size: Int
    }

    static func handle(_ reader: inout ByteReader) throws -> Handle {
        let offset = try reader.varint()
        let size = try reader.varint()
        guard offset <= UInt64(Int.max / 2), size <= UInt64(Int.max / 2) else { throw FormatError.corrupt("block handle") }
        return Handle(offset: Int(offset), size: Int(size))
    }

    /// A block's contents, checked against its checksum and uncompressed.
    static func block(_ file: FileHandle, _ handle: Handle, fileSize: Int) throws -> [UInt8] {
        guard handle.offset + handle.size + blockTrailerSize <= fileSize - footerSize else {
            throw FormatError.corrupt("block handle")
        }
        let bytes = try readBytes(file, at: handle.offset, count: handle.size + blockTrailerSize)
        var trailer = ByteReader(bytes, from: handle.size)
        let compression = try trailer.byte()
        let checksum = try trailer.fixed32()
        let contents = bytes[0..<handle.size]
        guard CRC32C.unmask(checksum) == CRC32C.checksum(CollectionOfOne(compression), extending: CRC32C.checksum(contents)) else {
            throw FormatError.corrupt("block checksum")
        }
        switch compression {
        case 0: return Array(contents)
        case 1: return try Snappy.decompress(contents)
        default: throw FormatError.unsupported("block compression \(compression)")
        }
    }

    /// A block's keys and values. Keys share a prefix with the one before, except at the restart points listed at
    /// the end of the block.
    static func blockEntries(_ block: [UInt8]) throws -> [(key: [UInt8], value: ArraySlice<UInt8>)] {
        guard block.count >= 4 else { throw FormatError.corrupt("block") }
        var tail = ByteReader(block, from: block.count - 4)
        let restarts = Int(try tail.fixed32())
        guard restarts <= (block.count - 4) / 4 else { throw FormatError.corrupt("block restarts") }
        var reader = ByteReader(block, to: block.count - 4 - 4 * restarts)
        var entries: [(key: [UInt8], value: ArraySlice<UInt8>)] = []
        var key: [UInt8] = []
        while !reader.isAtEnd {
            let shared = Int(try reader.varint32())
            let unshared = Int(try reader.varint32())
            let valueLength = Int(try reader.varint32())
            guard shared <= key.count else { throw FormatError.corrupt("block key") }
            key.removeSubrange(shared...)
            key += try reader.bytes(unshared)
            entries.append((key, try reader.bytes(valueLength)))
        }
        return entries
    }

    static func readBytes(_ file: FileHandle, at offset: Int, count: Int) throws -> [UInt8] {
        try file.seek(toOffset: UInt64(offset))
        let data = try file.read(upToCount: count) ?? Data()
        guard data.count == count else { throw FormatError.truncated }
        return [UInt8](data)
    }
}
