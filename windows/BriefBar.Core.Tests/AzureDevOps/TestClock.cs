namespace BriefBar.Core.Tests.AzureDevOps;

/// A clock a test sets, as the Swift tests' `now` closures do: what time it is, while timers and delays run in real time.
internal sealed class TestClock(DateTimeOffset start) : TimeProvider
{
    readonly Lock gate = new();
    DateTimeOffset now = start;

    public void Set(DateTimeOffset time)
    {
        lock (gate)
        {
            now = time;
        }
    }

    public override DateTimeOffset GetUtcNow()
    {
        lock (gate)
        {
            return now;
        }
    }
}
