namespace BriefBar.Core.Copilot;

/// An entry from the app's own activity feed (`agent_idle`, `agent_asking`, `agent_error`…).
public sealed record ActivityPreview(string Kind, string Text, DateTimeOffset? At);
