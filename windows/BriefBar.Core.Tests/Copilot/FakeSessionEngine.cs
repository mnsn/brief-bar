using BriefBar.Core.Copilot;

namespace BriefBar.Core.Tests.Copilot;

/// An engine a test drives: it hands over what the test says, when it says. With `holdStart`, its start waits until the
/// test sets it, as a first read of many sessions takes a while. It notes each start and stop, in order.
internal sealed class FakeSessionEngine(Action<EngineSnapshot> onChange, bool failsToStart = false, ManualResetEventSlim? holdStart = null) : ISessionEngine
{
    static readonly TimeSpan longestHold = TimeSpan.FromSeconds(value: 10);

    readonly List<string> calls = [];

    public int Starts => Count(call: "start");

    public int Stops => Count(call: "stop");

    /// "start" and "stop", in the order they happened.
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
        holdStart?.Wait(timeout: longestHold);
        Note(call: "start");
        if (failsToStart)
        {
            throw new InvalidOperationException(message: "Made-up failure.");
        }
    }

    public void Stop() => Note(call: "stop");

    public void Refresh()
    {
    }

    public void Publish(EngineSnapshot snapshot) => onChange(obj: snapshot);

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
