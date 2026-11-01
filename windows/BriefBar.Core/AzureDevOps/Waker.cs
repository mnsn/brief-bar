namespace BriefBar.Core.AzureDevOps;

/// Lets the refresh loop wait for its next refresh, or until something asks for one sooner: a wake before the wait counts
/// too. The Mac's `Waker`.
internal sealed class Waker
{
    readonly Lock gate = new();
    bool pending;
    TaskCompletionSource? waiting;

    public void Wake()
    {
        TaskCompletionSource? woken;
        lock (gate)
        {
            if (waiting is null)
            {
                pending = true;
                return;
            }
            woken = waiting;
            waiting = null;
        }
        woken.TrySetResult();
    }

    /// Returns after `delay`, or as soon as `Wake` is called, including before this was.
    public async Task WaitAsync(TimeSpan delay, TimeProvider time, CancellationToken cancellationToken)
    {
        TaskCompletionSource woken;
        lock (gate)
        {
            if (pending)
            {
                pending = false;
                return;
            }
            woken = waiting = new TaskCompletionSource(creationOptions: TaskCreationOptions.RunContinuationsAsynchronously);
        }
        using var timer = CancellationTokenSource.CreateLinkedTokenSource(token: cancellationToken);
        try
        {
            var delayed = Task.Delay(delay: delay > TimeSpan.Zero ? delay : TimeSpan.Zero, timeProvider: time, cancellationToken: timer.Token);
            await Task.WhenAny(task1: woken.Task, task2: delayed).ConfigureAwait(continueOnCapturedContext: false);
            cancellationToken.ThrowIfCancellationRequested();
        }
        finally
        {
            await timer.CancelAsync().ConfigureAwait(continueOnCapturedContext: false);
            lock (gate)
            {
                if (waiting == woken)
                {
                    waiting = null;
                }
            }
        }
    }
}
