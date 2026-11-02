using BriefBar.Core.Copilot;

namespace BriefBar.Core.Demo;

/// An engine that reads nothing: it hands over `CopilotDemoData`'s made-up sessions as it starts, and again when asked
/// to read again, so `CopilotSource` shows them as it would the Copilot app's.
public sealed class DemoSessionEngine(DateTimeOffset madeAt, Action<EngineSnapshot> onChange) : ISessionEngine
{
    readonly EngineSnapshot snapshot = CopilotDemoData.Snapshot(now: madeAt);

    public void Start() => onChange(obj: snapshot);

    public void Stop()
    {
    }

    public void Refresh() => onChange(obj: snapshot);
}
