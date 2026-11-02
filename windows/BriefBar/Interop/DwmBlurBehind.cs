using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// `DWM_BLURBEHIND`: whether, and where, the desktop shows through a window.
[StructLayout(LayoutKind.Sequential)]
internal struct DwmBlurBehind
{
    /// `DWM_BB_ENABLE`: `Enable` says something.
    public const uint DWM_BB_ENABLE = 0x1;

    /// `DWM_BB_BLURREGION`: `Region` says something.
    public const uint DWM_BB_BLURREGION = 0x2;

    public uint Flags;

    [MarshalAs(UnmanagedType.Bool)]
    public bool Enable;

    public nint Region;

    [MarshalAs(UnmanagedType.Bool)]
    public bool TransitionOnMaximized;
}
