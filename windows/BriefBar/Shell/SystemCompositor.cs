using System.Runtime.InteropServices;
using BriefBar.Interop;

namespace BriefBar.Shell;

/// Windows' own compositor, Windows.UI.Composition's, whose brushes a window's system backdrop takes; WinUI's is
/// another. It needs a Windows.System dispatcher queue on the UI thread, which WinUI doesn't start, so the first use
/// starts one, kept for as long as BriefBar runs. Use it on the UI thread only.
internal static class SystemCompositor
{
    static Windows.UI.Composition.Compositor? compositor;
    static nint queueController;

    public static Windows.UI.Composition.Compositor Get()
    {
        if (compositor is null)
        {
            if (Windows.System.DispatcherQueue.GetForCurrentThread() is null && queueController == 0)
            {
                var options = new DispatcherQueueOptions
                {
                    Size = Marshal.SizeOf<DispatcherQueueOptions>(),
                    ThreadType = DispatcherQueueOptions.DQTYPE_THREAD_CURRENT,
                    ApartmentType = DispatcherQueueOptions.DQTAT_COM_STA,
                };
                Marshal.ThrowExceptionForHR(errorCode: CoreMessaging.CreateDispatcherQueueController(options: options, dispatcherQueueController: out queueController));
            }
            compositor = new Windows.UI.Composition.Compositor();
        }
        return compositor;
    }
}
