namespace BriefBar.Core.ChromiumIndexedDB;

/// CRC-32C (Castagnoli), which LevelDB checksums its log records and table blocks with, masked. The Mac's `CRC32C`.
internal static class CRC32C
{
    const uint MaskDelta = 0xA282EAD8;

    static readonly uint[] table = MakeTable();

    /// The checksum of `bytes`, or of what `initial` is the checksum of followed by `bytes`.
    public static uint Checksum(ReadOnlySpan<byte> bytes, uint initial = 0)
    {
        var crc = ~initial;
        foreach (var next in bytes)
        {
            crc = table[(crc ^ next) & 0xFF] ^ (crc >> 8);
        }
        return ~crc;
    }

    /// LevelDB stores checksums masked, so that the checksum of data that holds checksums isn't thrown off.
    public static uint Mask(uint crc) => ((crc >> 15) | (crc << 17)) + MaskDelta;

    public static uint Unmask(uint masked)
    {
        var rotated = masked - MaskDelta;
        return (rotated >> 17) | (rotated << 15);
    }

    static uint[] MakeTable()
    {
        var made = new uint[256];
        for (uint index = 0; index < 256; index++)
        {
            var crc = index;
            for (var bit = 0; bit < 8; bit++)
            {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x82F63B78 : crc >> 1;
            }
            made[index] = crc;
        }
        return made;
    }
}
