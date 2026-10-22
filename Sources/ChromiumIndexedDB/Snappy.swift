/// Snappy's raw format, without framing: LevelDB compresses table blocks with it, and Chromium large IndexedDB values.
enum Snappy {
    /// No value BriefBar reads comes near this; a length beyond it is corrupt.
    static let limit = 64 << 20

    static func decompress<Bytes: Collection<UInt8>>(_ compressed: Bytes, limit: Int = Snappy.limit) throws -> [UInt8] {
        let input = Array(compressed)
        var position = 0
        var length = 0
        var shift = 0
        while true {
            guard position < input.count else { throw FormatError.truncated }
            guard shift <= 28 else { throw FormatError.corrupt("Snappy length") }
            let byte = input[position]
            position += 1
            length |= Int(byte & 0x7F) << shift
            if byte < 0x80 { break }
            shift += 7
        }
        guard length <= limit else { throw FormatError.unsupported("Snappy length") }

        var output = [UInt8](repeating: 0, count: length)
        var written = 0
        try output.withUnsafeMutableBufferPointer { destination in
            try input.withUnsafeBufferPointer { source in
                func copy(offset: Int, count: Int) throws {
                    guard offset > 0, offset <= written, count <= length - written else {
                        throw FormatError.corrupt("Snappy copy")
                    }
                    // Byte by byte: a copy may overlap what it writes, repeating a run.
                    for index in 0..<count {
                        destination[written + index] = destination[written - offset + index]
                    }
                    written += count
                }
                func little(_ count: Int) throws -> Int {
                    guard count <= source.count - position else { throw FormatError.truncated }
                    var value = 0
                    for index in 0..<count {
                        value |= Int(source[position + index]) << (8 * index)
                    }
                    position += count
                    return value
                }

                while position < source.count {
                    let tag = source[position]
                    position += 1
                    switch tag & 3 {
                    case 0:
                        var count = Int(tag >> 2)
                        if count >= 60 {
                            count = try little(count - 59)
                        }
                        count += 1
                        guard count <= source.count - position, count <= length - written else {
                            throw FormatError.corrupt("Snappy literal")
                        }
                        for index in 0..<count {
                            destination[written + index] = source[position + index]
                        }
                        position += count
                        written += count
                    case 1:
                        let count = 4 + Int((tag >> 2) & 7)
                        let offset = Int(tag >> 5) << 8 | (try little(1))
                        try copy(offset: offset, count: count)
                    case 2:
                        try copy(offset: try little(2), count: 1 + Int(tag >> 2))
                    default:
                        try copy(offset: try little(4), count: 1 + Int(tag >> 2))
                    }
                }
            }
        }
        guard written == length else { throw FormatError.corrupt("Snappy length") }
        return output
    }
}
