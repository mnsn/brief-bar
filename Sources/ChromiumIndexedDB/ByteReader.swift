/// Why bytes couldn't be read as the format they should be in. Never holds any of the data.
public enum FormatError: Error, Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The data ends before what it says it holds.
    case truncated
    /// The data contradicts the format.
    case corrupt(String)
    /// A valid form that BriefBar doesn't read, such as a newer version.
    case unsupported(String)

    public var description: String {
        switch self {
        case .truncated: return "truncated"
        case .corrupt(let what): return "corrupt \(what)"
        case .unsupported(let what): return "unsupported \(what)"
        }
    }
}

/// Reads LevelDB's and Chromium's encodings from bytes, throwing rather than reading past the end.
struct ByteReader {
    let bytes: [UInt8]
    private(set) var offset: Int
    let end: Int

    init(_ bytes: [UInt8], from start: Int = 0, to end: Int? = nil) {
        self.bytes = bytes
        self.end = min(max(0, end ?? bytes.count), bytes.count)
        offset = min(max(0, start), self.end)
    }

    var isAtEnd: Bool { offset >= end }
    var remaining: Int { end - offset }

    mutating func byte() throws -> UInt8 {
        guard offset < end else { throw FormatError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    func peek() throws -> UInt8 {
        guard offset < end else { throw FormatError.truncated }
        return bytes[offset]
    }

    mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= remaining else { throw FormatError.truncated }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw FormatError.truncated }
        offset += count
    }

    /// A little-endian integer of `count` bytes, as LevelDB writes fixed-width ones.
    mutating func littleEndian(_ count: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for (shift, byte) in try bytes(count).enumerated() {
            value |= UInt64(byte) << (8 * UInt64(shift))
        }
        return value
    }

    /// A big-endian integer of `count` bytes.
    mutating func bigEndian(_ count: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for byte in try bytes(count) {
            value = value << 8 | UInt64(byte)
        }
        return value
    }

    mutating func fixed32() throws -> UInt32 { UInt32(try littleEndian(4)) }
    mutating func fixed64() throws -> UInt64 { try littleEndian(8) }
    mutating func double() throws -> Double { Double(bitPattern: try fixed64()) }

    /// A base-128 varint of up to 64 bits.
    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try self.byte()
            guard shift < 63 || byte <= 1 else { throw FormatError.corrupt("varint") }
            value |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return value }
            shift += 7
        }
    }

    mutating func varint32() throws -> UInt32 {
        let value = try varint()
        guard value <= UInt64(UInt32.max) else { throw FormatError.corrupt("varint") }
        return UInt32(value)
    }

    /// A varint that counts bytes or items: no more than what's left to read could hold.
    mutating func count() throws -> Int {
        let value = try varint()
        guard value <= UInt64(remaining) else { throw FormatError.truncated }
        return Int(value)
    }
}
