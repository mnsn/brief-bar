namespace BriefBar.Core.Copilot;

/// What the Copilot app itself shows: which workspaces carry an unread dot, and which session is on screen.
public sealed record AppViewState
{
    /// Workspace IDs with an unread marker; null when the app's format couldn't be read.
    public IReadOnlySet<string>? UnreadWorkspaceIds { get; init; }

    public DateTimeOffset? UnreadUpdatedAt { get; init; }

    /// The session the app's window shows, if it could be told.
    public string? ViewedSessionId { get; init; }

    public bool Equals(AppViewState? other) =>
        other is not null
        && UnreadUpdatedAt == other.UnreadUpdatedAt
        && ViewedSessionId == other.ViewedSessionId
        && (UnreadWorkspaceIds is null
            ? other.UnreadWorkspaceIds is null
            : other.UnreadWorkspaceIds is not null && UnreadWorkspaceIds.SetEquals(other: other.UnreadWorkspaceIds));

    public override int GetHashCode() =>
        HashCode.Combine(value1: UnreadUpdatedAt, value2: ViewedSessionId, value3: UnreadWorkspaceIds?.Count);
}
