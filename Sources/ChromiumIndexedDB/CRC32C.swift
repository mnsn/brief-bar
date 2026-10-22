/// CRC-32C (Castagnoli), which LevelDB checksums its log records and table blocks with, masked.
enum CRC32C {
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 {
            crc = crc & 1 != 0 ? (crc >> 1) ^ 0x82F6_3B78 : crc >> 1
        }
        return crc
    }

    /// The checksum of `bytes`, or of what `initial` is the checksum of followed by `bytes`.
    static func checksum<Bytes: Collection<UInt8>>(_ bytes: Bytes, extending initial: UInt32 = 0) -> UInt32 {
        var crc = ~initial
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return ~crc
    }

    private static let maskDelta: UInt32 = 0xA282_EAD8

    /// LevelDB stores checksums masked, so that the checksum of data that holds checksums isn't thrown off.
    static func mask(_ crc: UInt32) -> UInt32 {
        ((crc >> 15) | (crc << 17)) &+ maskDelta
    }

    static func unmask(_ masked: UInt32) -> UInt32 {
        let rotated = masked &- maskDelta
        return (rotated >> 17) | (rotated << 15)
    }
}
