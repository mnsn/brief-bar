using BriefBar.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace BriefBar;

/// Where BriefBar starts. Only one runs per sign-in: a second start asks the first to show its Overview, and quits,
/// before any of XAML starts.
public static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        var instance = SingleInstance.TryClaim();
        if (instance is null)
        {
            SingleInstance.AskRunningToShow();
            return 0;
        }
        try
        {
            WinRT.ComWrappersSupport.InitializeComWrappers();
            var options = LaunchOptions.Parse(arguments: args);
            Application.Start(callback: initialization =>
            {
                var context = new DispatcherQueueSynchronizationContext(dispatcherQueue: DispatcherQueue.GetForCurrentThread());
                SynchronizationContext.SetSynchronizationContext(syncContext: context);
                _ = new App(options: options, instance: instance);
            });
        }
        finally
        {
            instance.Dispose();
        }
        return 0;
    }
}
