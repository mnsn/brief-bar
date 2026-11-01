using System.Diagnostics;
using Microsoft.UI.Dispatching;

namespace BriefBar.Shell;

/// Keeps one BriefBar running per sign-in. A second start asks the first to show its Overview, then quits; and
/// windows/scripts/quit.ps1 asks it to quit, through a named event. The events are made as BriefBar claims its place,
/// before XAML starts, so a request made while it starts waits, signaled, until it listens.
internal sealed class SingleInstance : IDisposable
{
    const string MutexName = "BriefBar.Windows";
    const string QuitEventName = "BriefBar.Windows.Quit";
    const string ShowEventName = "BriefBar.Windows.Show";

    readonly Mutex mutex;
    readonly EventWaitHandle quitEvent;
    readonly EventWaitHandle showEvent;
    RegisteredWaitHandle? quitWait;
    RegisteredWaitHandle? showWait;

    SingleInstance(Mutex mutex)
    {
        this.mutex = mutex;
        quitEvent = new EventWaitHandle(initialState: false, mode: EventResetMode.AutoReset, name: QuitEventName);
        showEvent = new EventWaitHandle(initialState: false, mode: EventResetMode.AutoReset, name: ShowEventName);
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

    /// Asks the BriefBar that runs to show its Overview, trying for up to `patience`: one that has just claimed its
    /// place makes its events a moment later. False if it can't be reached, as while it quits.
    public static bool AskRunningToShow(TimeSpan patience)
    {
        var started = Stopwatch.GetTimestamp();
        while (true)
        {
            if (EventWaitHandle.TryOpenExisting(name: ShowEventName, result: out var showing))
            {
                using (showing)
                {
                    return showing.Set();
                }
            }
            if (Stopwatch.GetElapsedTime(startingTimestamp: started) >= patience)
            {
                return false;
            }
            Thread.Sleep(millisecondsTimeout: 50);
        }
    }

    /// Calls `quit` or `show`, on `queue`, when another program asks, or at once if it asked while BriefBar started.
    public void Listen(DispatcherQueue queue, Action quit, Action show)
    {
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
        quitEvent.Dispose();
        showEvent.Dispose();
        mutex.ReleaseMutex();
        mutex.Dispose();
    }
}
