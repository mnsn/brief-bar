using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// crypt32.dll: Windows' data protection (DPAPI), which seals data for your Windows account.
internal static class Crypt32
{
    /// Never show a prompt: fail instead.
    public const uint CRYPTPROTECT_UI_FORBIDDEN = 0x1;

    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CryptProtectData(
        ref DataBlob dataIn, string? description, ref DataBlob optionalEntropy, nint reserved, nint promptStruct, uint flags, out DataBlob dataOut);

    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CryptUnprotectData(
        ref DataBlob dataIn, nint description, ref DataBlob optionalEntropy, nint reserved, nint promptStruct, uint flags, out DataBlob dataOut);
}
