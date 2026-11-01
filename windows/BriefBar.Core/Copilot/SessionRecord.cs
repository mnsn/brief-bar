namespace BriefBar.Core.Copilot;

/// A session the app lists, with what its log says: null while it has no log.
public sealed record SessionRecord(SessionMeta Meta, SessionLogState? Log)
{
    public string Id => Meta.Id;
}
