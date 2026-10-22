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
/// from where the last complete batch ended.
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
    /// batch that isn't all there yet. Only writes to keys that `keep` accepts are kept.
    public static func parse(
        _ bytes: [UInt8], fileOffset: Int = 0, keep: (ArraySlice<UInt8>) -> Bool = { _ in true }
    ) -> Parsed {
        var parsed = Parsed(entries: [], end: fileOffset, corrupt: 0)
        var position = 0
        var pending: [UInt8]?

        func batch<Bytes: Collection<UInt8>>(_ data: Bytes) {
            do {
                parsed.entries += try writes(in: Array(data), keep: keep)
            } catch {
                parsed.corrupt += 1
            }
        }
        // Drops the rest of a block, as LevelDB does with a record it can't trust.
        func skipBlock(left: Int) {
            parsed.corrupt += 1
            pending = nil
            position += left
            if position <= bytes.count {
                parsed.end = fileOffset + position
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
            // Space LevelDB hasn't written yet reads as zeros.
            if checksum == 0, size == 0, type == 0 { break }
            guard headerSize + size <= left else {
                skipBlock(left: left)
                continue
            }
            guard bytes.count - position - headerSize >= size else { break }
            let data = bytes[(position + headerSize)..<(position + headerSize + size)]
            guard CRC32C.unmask(checksum) == CRC32C.checksum(data, extending: CRC32C.checksum(CollectionOfOne(type))) else {
                // At the end of the file, it may still be being written: try again later.
                if position + headerSize + size >= bytes.count { break }
                skipBlock(left: left)
                continue
            }
            position += headerSize + size
            switch RecordType(rawValue: type) {
            case .full:
                if pending != nil { parsed.corrupt += 1 }
                pending = nil
                batch(data)
                parsed.end = fileOffset + position
            case .first:
                if pending != nil { parsed.corrupt += 1 }
                pending = Array(data)
            case .middle:
                if pending == nil { parsed.corrupt += 1 } else { pending! += data }
            case .last:
                if var whole = pending {
                    whole += data
                    batch(whole)
                    parsed.end = fileOffset + position
                } else {
                    parsed.corrupt += 1
                }
                pending = nil
            case nil:
                parsed.corrupt += 1
            }
        }
        return parsed
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
