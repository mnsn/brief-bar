namespace BriefBar.Core.Copilot;

/// What one read of the app's database found: its sessions, and what its window shows.
public sealed record DatabaseSnapshot(ValueList<SessionMeta> Sessions, AppViewState View);
