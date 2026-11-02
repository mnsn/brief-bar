using BriefBar.Core.Teams;

namespace BriefBar.Core.Tests.Teams;

/// An engine a test drives: it hands over what the test says, when it says. With `holdStart`, its start waits until the
/// test sets it, as a first read of Teams' data takes a while. It notes each start, stop and refresh, in order.
internal sealed class FakeTeamsEngine(Action<TeamsSnapshot> onChange, bool failsToStart = false, ManualResetEventSlim? holdStart = null) : ITeamsEngine
{
    static readonly TimeSpan longestHold = TimeSpan.FromSeconds(value: 10);

    readonly List<string> calls = [];
    volatile bool enteredStart;

    /// Whether its start has begun, though it may still be held.
    public bool EnteredStart => enteredStart;

    public int Starts => Count(call: "start");

    public int Stops => Count(call: "stop");

    public int Refreshes => Count(call: "refresh");

    /// "start", "stop" and "refresh", in the order they happened.
    public IReadOnlyList<string> Calls
    {
        get
        {
            lock (calls)
            {
                return [.. calls];
            }
        }
    }

    public void Start()
    {
        enteredStart = true;
        holdStart?.Wait(timeout: longestHold);
        Note(call: "start");
        if (failsToStart)
        {
            throw new InvalidOperationException(message: "Made-up failure.");
        }
    }

    public void Stop() => Note(call: "stop");

    public void Refresh() => Note(call: "refresh");

    public void Publish(TeamsSnapshot snapshot) => onChange(obj: snapshot);

    void Note(string call)
    {
        lock (calls)
        {
            calls.Add(item: call);
        }
    }

    int Count(string call)
    {
        lock (calls)
        {
            return calls.Count(predicate: noted => noted == call);
        }
    }
}
