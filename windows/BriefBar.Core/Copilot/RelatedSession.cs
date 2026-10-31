namespace BriefBar.Core.Copilot;

/// Another session that a session's row refers to, by its ID and the name the list shows it by.
public sealed record RelatedSession(string Id, string Name);
