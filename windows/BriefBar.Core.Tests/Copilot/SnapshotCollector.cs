using BriefBar.Core.Copilot;

namespace BriefBar.Core.Tests.Copilot;

/// Collects what an engine hands over, on its own threads, to wait for in a test.
internal sealed class SnapshotCollector
{
    readonly Lock gate = new();
    readonly List<EngineSnapshot> snapshots = [];

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

    public void Add(EngineSnapshot snapshot)
    {
        lock (gate)
        {
            snapshots.Add(item: snapshot);
        }
    }

    /// Waits until the latest snapshot satisfies `predicate`.
    public async Task<EngineSnapshot> WaitAsync(string what, Func<EngineSnapshot, bool> predicate, int seconds = 15)
    {
        var deadline = DateTime.UtcNow.AddSeconds(value: seconds);
        while (DateTime.UtcNow < deadline)
        {
            if (Latest() is { } latest && predicate(arg: latest))
            {
                return latest;
            }
            await Task.Delay(millisecondsDelay: 20, cancellationToken: TestContext.Current.CancellationToken);
        }
        // On a busy machine a test can look again only after its deadline, though what it waits for came in time.
        if (Latest() is { } last && predicate(arg: last))
        {
            return last;
        }
        Assert.Fail(message: $"Timed out waiting for {what} after {Count} snapshot(s)");
        throw new InvalidOperationException();
    }

    EngineSnapshot? Latest()
    {
        lock (gate)
        {
            return snapshots.Count > 0 ? snapshots[^1] : null;
        }
    }
}
