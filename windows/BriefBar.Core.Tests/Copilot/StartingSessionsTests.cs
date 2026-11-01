using BriefBar.Core.Copilot;

namespace BriefBar.Core.Tests.Copilot;

/// The sessions being opened in a terminal: once at a time, for a while, until it's open or couldn't be, and none once
/// opening stops.
public sealed class StartingSessionsTests
{
    static readonly DateTimeOffset now = TestTimes.T(seconds: 0);

    [Fact]
    public void OpensEachSessionOnceAtATime()
    {
        var starting = new StartingSessions();
        Assert.True(condition: starting.Begin(id: "a", now: now));
        Assert.False(condition: starting.Begin(id: "a", now: now.AddSeconds(seconds: 29)));
        Assert.True(condition: starting.Begin(id: "b", now: now));
        // A terminal that never started the CLI doesn't hold it back for good.
        Assert.True(condition: starting.Begin(id: "a", now: now + StartingSessions.Window));

        starting.End(id: "b");
        Assert.True(condition: starting.Begin(id: "b", now: now.AddSeconds(seconds: 1)));
    }

    [Fact]
    public void ForgetsEverySessionOnceStopped()
    {
        var starting = new StartingSessions();
        Assert.True(condition: starting.Begin(id: "a", now: now));
        var round = starting.Round;
        starting.StopAll();
        Assert.Equal(expected: round + 1, actual: starting.Round);
        Assert.True(condition: starting.Begin(id: "a", now: now.AddSeconds(seconds: 1)));
    }
}
