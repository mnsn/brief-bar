using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using BriefBar.Core;
using BriefBar.Interop;

namespace BriefBar.Services;

/// Seals data with Windows' DPAPI for your Windows account, as the Mac keeps its key in your login keychain: only programs
/// running as you, on this PC, can open it. `purpose` keeps what one part of BriefBar seals from opening as another's.
internal sealed class WindowsDataProtector(string purpose) : ISecretProtector
{
    readonly byte[] entropy = Encoding.UTF8.GetBytes(s: purpose);

    public byte[] Protect(byte[] data) => Transform(input: data, protect: true);

    public byte[] Unprotect(byte[] sealedData) => Transform(input: sealedData, protect: false);

    /// Seals or opens `input`; throws `CryptographicException` with Windows' error when it can't, as for data sealed for
    /// someone else, or damaged.
    byte[] Transform(byte[] input, bool protect)
    {
        ArgumentNullException.ThrowIfNull(argument: input);
        var inputHandle = GCHandle.Alloc(value: input, type: GCHandleType.Pinned);
        var entropyHandle = GCHandle.Alloc(value: entropy, type: GCHandleType.Pinned);
        var output = default(DataBlob);
        try
        {
            var inputBlob = new DataBlob { Size = (uint)input.Length, Data = inputHandle.AddrOfPinnedObject() };
            var entropyBlob = new DataBlob { Size = (uint)entropy.Length, Data = entropyHandle.AddrOfPinnedObject() };
            var done = protect
                ? Crypt32.CryptProtectData(
                    dataIn: ref inputBlob,
                    description: "BriefBar",
                    optionalEntropy: ref entropyBlob,
                    reserved: 0,
                    promptStruct: 0,
                    flags: Crypt32.CRYPTPROTECT_UI_FORBIDDEN,
                    dataOut: out output)
                : Crypt32.CryptUnprotectData(
                    dataIn: ref inputBlob,
                    description: 0,
                    optionalEntropy: ref entropyBlob,
                    reserved: 0,
                    promptStruct: 0,
                    flags: Crypt32.CRYPTPROTECT_UI_FORBIDDEN,
                    dataOut: out output);
            if (!done)
            {
                throw new CryptographicException(hr: Marshal.GetLastPInvokeError());
            }
            var result = new byte[output.Size];
            Marshal.Copy(source: output.Data, destination: result, startIndex: 0, length: result.Length);
            return result;
        }
        finally
        {
            if (output.Data != 0)
            {
                // What it opened doesn't stay in memory Windows hands back to others.
                Marshal.Copy(source: new byte[output.Size], startIndex: 0, destination: output.Data, length: (int)output.Size);
                Kernel32.LocalFree(memory: output.Data);
            }
            inputHandle.Free();
            entropyHandle.Free();
        }
    }
}
