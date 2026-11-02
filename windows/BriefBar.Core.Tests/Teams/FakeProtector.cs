using System.Security.Cryptography;

namespace BriefBar.Core.Tests.Teams;

/// Seals data as a test's stand-in for Windows' DPAPI: a header, the key, and the data mixed with it. Opening what was
/// sealed with another key, or isn't sealed at all, fails as DPAPI does.
internal sealed class FakeProtector(byte key = 0x5A) : ISecretProtector
{
    public static byte[] Header { get; } = "SEAL"u8.ToArray();

    public byte[] Protect(byte[] data)
    {
        ArgumentNullException.ThrowIfNull(argument: data);
        return [.. Header, key, .. data.Select(selector: value => (byte)(value ^ key))];
    }

    public byte[] Unprotect(byte[] sealedData)
    {
        ArgumentNullException.ThrowIfNull(argument: sealedData);
        if (sealedData.Length <= Header.Length || !sealedData.AsSpan(start: 0, length: Header.Length).SequenceEqual(other: Header) || sealedData[Header.Length] != key)
        {
            throw new CryptographicException(message: "Not sealed with this key.");
        }
        return [.. sealedData.Skip(count: Header.Length + 1).Select(selector: value => (byte)(value ^ key))];
    }
}
