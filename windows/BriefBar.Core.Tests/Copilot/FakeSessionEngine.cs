using BriefBar.Core.Copilot;

namespace BriefBar.Core.Tests.Copilot;

/// An engine a test drives: it hands over what the test says, when it says.
internal sealed class FakeSessionEngine(Action<EngineSnapshot> onChange, bool failsToStart = false) : ISessionEngine
{
    public int Starts { get; private set; }

    public int Stops { get; private set; }

    public void Start()
    {
        Starts++;
        if (failsToStart)
        {
            throw new InvalidOperationException(message: "Made-up failure.");
        }
    }

    public void Stop() => Stops++;

    public void Refresh()
    {
    }

    public void Publish(EngineSnapshot snapshot) => onChange(obj: snapshot);
}
