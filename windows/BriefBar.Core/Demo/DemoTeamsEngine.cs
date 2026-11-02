using BriefBar.Core.Teams;

namespace BriefBar.Core.Demo;

/// An engine that reads nothing: it hands over `TeamsDemoData`'s made-up chats as it starts, and again when asked to read
/// again, so `TeamsSource` shows them as it would Teams' own.
public sealed class DemoTeamsEngine(DateTimeOffset madeAt, Action<TeamsSnapshot> onChange) : ITeamsEngine
{
    readonly TeamsSnapshot snapshot = TeamsDemoData.Snapshot(now: madeAt);

    public void Start() => onChange(obj: snapshot);

    public void Stop()
    {
    }

    public void Refresh() => onChange(obj: snapshot);
}
