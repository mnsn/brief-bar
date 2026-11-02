using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// A buffer as crypt32.dll takes and returns data: `DATA_BLOB`.
[StructLayout(LayoutKind.Sequential)]
internal struct DataBlob
{
    public uint Size;
    public nint Data;
}
