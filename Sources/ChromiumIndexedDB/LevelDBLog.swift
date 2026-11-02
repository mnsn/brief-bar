/// One write to a LevelDB database: a key's new value, or its deletion.
public struct LevelDBEntry: Sendable, Equatable {
    /// LevelDB numbers every write; of two writes to a key, the higher number is the newer.
    public var sequence: UInt64
    public var key: [UInt8]
    /// Nil when the key was deleted.
    public var value: [UInt8]?

    public init(sequence: UInt64, key: [UInt8], value: [UInt8]?) {
        self.sequence = sequence
        self.key = key
        self.value = value
    }
}

/// LevelDB's write-ahead log: every write goes there first, in 32 KiB blocks of checksummed records, each a write
/// batch or a fragment of one. LevelDB only ever appends to it, so it can be read while it's written, and read on
/// from where the last complete batch ended. Its MANIFEST is in the same format (`LevelDBManifest`).
public enum LevelDBLog {
    static let blockSize = 32_768
    static let headerSize = 7

    enum RecordType: UInt8 {
        case full = 1, first, middle, last
    }

    public struct Parsed: Sendable {
        /// The writes of every complete batch, in order.
        public var entries: [LevelDBEntry]
        /// The file offset after the last complete batch: where to go on reading once more is written.
        public var end: Int
        /// Records or batches skipped because they broke the format or their checksum didn't match.
        public var corrupt: Int
    }

    /// Parses `bytes`, which start at `fileOffset` in the log: 0, or a previous `end`. Stops before a record or a
    /// batch that isn't all there yet, before zeros that run to the end, and before a record at the end whose checksum
    /// doesn't match: LevelDB may still be writing any of them, and reading on from `end` tries them again. Only writes
    /// to keys that `keep` accepts are kept.
    public static func parse(
        _ bytes: [UInt8], fileOffset: Int = 0, keep: (ArraySlice<UInt8>) -> Bool = { _ in true }
    ) -> Parsed {
        var entries: [LevelDBEntry] = []
        var corruptBatches = 0
        let (end, corrupt) = records(bytes, fileOffset: fileOffset, damagedEndIsCorrupt: false) { batch in
            do {
                entries += try writes(in: Array(batch), keep: keep)
            } catch {
                corruptBatches += 1
            }
        }
        return Parsed(entries: entries, end: end, corrupt: corrupt + corruptBatches)
    }

    /// Hands each record of `bytes`, which start at `fileOffset` in a file in the log's format, to `record`, in order:
    /// whole, where it was split across blocks. A log's records are write batches, and a MANIFEST's version edits.
    /// Stops before a record that isn't all there yet, before zeros that run to the end, which LevelDB may not have
    /// written yet, and before a record at the end whose checksum doesn't match. With `damagedEndIsCorrupt`, as LevelDB
    /// has it for a MANIFEST, that record counts as damaged, and so does one those zeros break off. Returns the file
    /// offset after the last whole record, and how many records or blocks were skipped because they broke the format or
    /// their checksum didn't match.
    static func records(
        _ bytes: [UInt8], fileOffset: Int = 0, damagedEndIsCorrupt: Bool, _ record: (ArraySlice<UInt8>) throws -> Void
    ) rethrows -> (end: Int, corrupt: Int) {
        var end = fileOffset
        var corrupt = 0
        var position = 0
        var pending: [UInt8]?

        // Drops the rest of a block, as LevelDB does with a record it can't trust, or one it never wrote, when that's
        // only damaged if it broke off a record.
        func skipBlock(left: Int, damaged: Bool = true) {
            if damaged { corrupt += 1 }
            pending = nil
            position += left
            if position <= bytes.count {
                end = fileOffset + position
            }
        }

        while position < bytes.count {
            let left = blockSize - (fileOffset + position) % blockSize
            if left < headerSize {
                // A block's last few bytes are zeros when no header fits.
                position += left
                continue
            }
            guard bytes.count - position >= headerSize else { break }
            var header = ByteReader(bytes, from: position, to: position + headerSize)
            guard let checksum = try? header.fixed32(), let length = try? header.littleEndian(2),
                  let type = try? header.byte()
            else { break }
            let size = Int(length)
            if type == 0, size == 0 {
                // Zeros that run to the end may be space LevelDB hasn't written yet: reading on from `end` reads what
                // it writes there. LevelDB never leaves a record broken off there as it writes, since a record's first
                // fragment fills its block: as it opens the database, it counts one as damaged.
                if bytes[position...].allSatisfy({ $0 == 0 }) {
                    if damagedEndIsCorrupt, pending != nil { corrupt += 1 }
                    break
                }
                // With more after them, the rest of the block was never written: LevelDB skips it, and counts a record
                // it breaks off as damaged.
                skipBlock(left: left, damaged: pending != nil)
                continue
            }
            guard headerSize + size <= left else {
                skipBlock(left: left)
                continue
            }
            guard bytes.count - position - headerSize >= size else { break }
            let data = bytes[(position + headerSize)..<(position + headerSize + size)]
            guard CRC32C.unmask(checksum) == CRC32C.checksum(data, extending: CRC32C.checksum(CollectionOfOne(type))) else {
                // At the end of a log, it may still be being written: try again later.
                if !damagedEndIsCorrupt, position + headerSize + size >= bytes.count { break }
                skipBlock(left: left)
                continue
            }
            position += headerSize + size
            switch RecordType(rawValue: type) {
            case .full:
                if pending != nil { corrupt += 1 }
                pending = nil
                try record(data)
                end = fileOffset + position
            case .first:
                if pending != nil { corrupt += 1 }
                pending = Array(data)
            case .middle:
                if pending == nil { corrupt += 1 } else { pending! += data }
            case .last:
                if var whole = pending {
                    whole += data
                    try record(whole[...])
                    end = fileOffset + position
                } else {
                    corrupt += 1
                }
                pending = nil
            case nil:
                corrupt += 1
            }
        }
        return (end, corrupt)
    }

    /// A write batch: its first sequence number, how many writes it holds, then each write.
    static func writes(in batch: [UInt8], keep: (ArraySlice<UInt8>) -> Bool) throws -> [LevelDBEntry] {
        var reader = ByteReader(batch)
        let sequence = try reader.fixed64()
        let count = try reader.fixed32()
        var entries: [LevelDBEntry] = []
        for index in 0..<UInt64(count) {
            let kind = try reader.byte()
            let key = try reader.bytes(reader.count())
            switch kind {
            case 1:
                let value = try reader.bytes(reader.count())
                if keep(key) {
                    entries.append(LevelDBEntry(sequence: sequence &+ index, key: Array(key), value: Array(value)))
                }
            case 0:
                if keep(key) {
                    entries.append(LevelDBEntry(sequence: sequence &+ index, key: Array(key), value: nil))
                }
            default:
                throw FormatError.corrupt("write kind")
            }
        }
        guard reader.isAtEnd else { throw FormatError.corrupt("write batch") }
        return entries
    }
}
