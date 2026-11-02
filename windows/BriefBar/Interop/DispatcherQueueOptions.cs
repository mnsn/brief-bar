using System.Runtime.InteropServices;

namespace BriefBar.Interop;

/// `DispatcherQueueOptions`: what kind of Windows.System dispatcher queue to start (`CoreMessaging`).
[StructLayout(LayoutKind.Sequential)]
internal struct DispatcherQueueOptions
{
    /// `DQTYPE_THREAD_CURRENT`: on the thread that asks.
    public const int DQTYPE_THREAD_CURRENT = 2;

    /// `DQTAT_COM_STA`: a single-threaded apartment, as the UI thread's.
    public const int DQTAT_COM_STA = 2;

    public int Size;
    public int ThreadType;
    public int ApartmentType;
}
