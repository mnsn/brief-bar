using BriefBar.Core.AzureDevOps;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Collects what a running `PulseEngine` hands over, on its own threads, to wait for in a test. As the Swift tests'
/// `SnapshotCollector`.
internal sealed class PulseCollector
{
    readonly Lock gate = new();
    readonly List<PulseSnapshot> snapshots = [];

    public int Count
    {
        get
        {
            lock (gate)
            {
                return snapshots.Count;
            }
        }
    }

    public PulseSnapshot? Last
    {
        get
        {
            lock (gate)
            {
                return snapshots.Count > 0 ? snapshots[^1] : null;
            }
        }
    }

    public void Add(PulseSnapshot snapshot)
    {
        lock (gate)
        {
            snapshots.Add(item: snapshot);
        }
    }

    /// Waits until the latest snapshot satisfies `predicate`, `seconds` at most.
    public async Task<PulseSnapshot> WaitAsync(string what, Func<PulseSnapshot, bool> predicate, int seconds = 10)
    {
        var deadline = DateTime.UtcNow.AddSeconds(value: seconds);
        while (DateTime.UtcNow < deadline)
        {
            if (Last is { } latest && predicate(arg: latest))
            {
                return latest;
            }
            await Task.Delay(millisecondsDelay: 20, cancellationToken: TestContext.Current.CancellationToken);
        }
        // On a busy machine a test can look again only after its deadline, though what it waits for came in time.
        if (Last is { } last && predicate(arg: last))
        {
            return last;
        }
        Assert.Fail(message: $"Timed out waiting for {what} after {Count} snapshot(s)");
        throw new InvalidOperationException();
    }
}
