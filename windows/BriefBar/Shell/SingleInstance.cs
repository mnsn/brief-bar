using Microsoft.UI.Dispatching;

namespace BriefBar.Shell;

/// Keeps one BriefBar running per sign-in. A second start asks the first to show its Overview, then quits; and
/// windows/scripts/quit.ps1 asks it to quit, through a named event.
internal sealed class SingleInstance : IDisposable
{
    const string MutexName = "BriefBar.Windows";
    const string QuitEventName = "BriefBar.Windows.Quit";
    const string ShowEventName = "BriefBar.Windows.Show";

    readonly Mutex mutex;
    EventWaitHandle? quitEvent;
    EventWaitHandle? showEvent;
    RegisteredWaitHandle? quitWait;
    RegisteredWaitHandle? showWait;

    SingleInstance(Mutex mutex)
    {
        this.mutex = mutex;
    }

    /// This BriefBar, if no other runs; null if one does.
    public static SingleInstance? TryClaim()
    {
        var mutex = new Mutex(initiallyOwned: true, name: MutexName, createdNew: out var isFirst);
        if (isFirst)
        {
            return new SingleInstance(mutex: mutex);
        }
        mutex.Dispose();
        return null;
    }

    /// Asks the BriefBar that runs to show its Overview. False if it can't be reached yet, as just after it starts.
    public static bool AskRunningToShow()
    {
        if (!EventWaitHandle.TryOpenExisting(name: ShowEventName, result: out var showing))
        {
            return false;
        }
        using (showing)
        {
            return showing.Set();
        }
    }

    /// Calls `quit` or `show`, on `queue`, when another program asks.
    public void Listen(DispatcherQueue queue, Action quit, Action show)
    {
        quitEvent = new EventWaitHandle(initialState: false, mode: EventResetMode.AutoReset, name: QuitEventName);
        showEvent = new EventWaitHandle(initialState: false, mode: EventResetMode.AutoReset, name: ShowEventName);
        quitWait = ThreadPool.RegisterWaitForSingleObject(
            waitObject: quitEvent,
            callBack: (_, _) => queue.TryEnqueue(callback: () => quit()),
            state: null,
            millisecondsTimeOutInterval: Timeout.Infinite,
            executeOnlyOnce: true);
        showWait = ThreadPool.RegisterWaitForSingleObject(
            waitObject: showEvent,
            callBack: (_, _) => queue.TryEnqueue(callback: () => show()),
            state: null,
            millisecondsTimeOutInterval: Timeout.Infinite,
            executeOnlyOnce: false);
    }

    /// Stops listening and lets another BriefBar start. Call it on the thread that started this one.
    public void Dispose()
    {
        quitWait?.Unregister(waitObject: null);
        showWait?.Unregister(waitObject: null);
        quitEvent?.Dispose();
        showEvent?.Dispose();
        mutex.ReleaseMutex();
        mutex.Dispose();
    }
}
