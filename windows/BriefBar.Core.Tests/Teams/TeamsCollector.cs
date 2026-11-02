using BriefBar.Core.Teams;

namespace BriefBar.Core.Tests.Teams;

/// Collects what `TeamsEngine` hands over, on its own threads, to wait for in a test.
internal sealed class TeamsCollector
{
    readonly Lock gate = new();
    readonly List<TeamsSnapshot> snapshots = [];

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

    public TeamsSnapshot? First
    {
        get
        {
            lock (gate)
            {
                return snapshots.Count > 0 ? snapshots[0] : null;
            }
        }
    }

    public TeamsSnapshot? Latest
    {
        get
        {
            lock (gate)
            {
                return snapshots.Count > 0 ? snapshots[^1] : null;
            }
        }
    }

    public void Add(TeamsSnapshot snapshot)
    {
        lock (gate)
        {
            snapshots.Add(item: snapshot);
        }
    }

    /// Waits until the latest snapshot satisfies `predicate`.
    public async Task<TeamsSnapshot> Until(string what, Func<TeamsSnapshot, bool> predicate, int seconds = 15)
    {
        var deadline = DateTime.UtcNow.AddSeconds(value: seconds);
        while (DateTime.UtcNow < deadline)
        {
            if (Latest is { } latest && predicate(arg: latest))
            {
                return latest;
            }
            await Task.Delay(millisecondsDelay: 20, cancellationToken: TestContext.Current.CancellationToken);
        }
        // On a busy machine a test can look again only after its deadline, though what it waits for came in time.
        if (Latest is { } last && predicate(arg: last))
        {
            return last;
        }
        Assert.Fail(message: $"Timed out waiting for {what} after {Count} snapshot(s)");
        throw new InvalidOperationException();
    }
}
