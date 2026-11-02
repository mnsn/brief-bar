namespace BriefBar.Core.Copilot;

/// A session as the Copilot app lists it, in its own `data.db`. The Mac's `SessionMeta`.
public sealed record SessionMeta
{
    public required string Id { get; init; }

    public required string Name { get; init; }

    /// `project`, `workspace`, `general_chat`…, as the app stores it.
    public string SessionType { get; init; } = "project";

    public string? Mode { get; init; }

    /// The app's own "a turn is in progress" flag, also on while it waits on `ask_user`. Null when unknown: the fallback
    /// query and the folder scan can't read it.
    public bool? IsRunning { get; init; } = false;

    public bool WasInterrupted { get; init; }

    public string? InterruptionReason { get; init; }

    public DateTimeOffset? CreatedAt { get; init; }

    public DateTimeOffset? UpdatedAt { get; init; }

    public string? ProjectName { get; init; }

    public string? Branch { get; init; }

    public string? CreatorSessionId { get; init; }

    /// The session that coordinates this one: the app tells it when this one waits for you, and it can ask you for it.
    public string? CoordinatorSessionId { get; init; }

    /// The session the app's sidebar nests this one under, which started it (`AppDatabase.ReadParents`).
    public string? ParentSessionId { get; init; }

    /// The app's workspace for a project session, which its unread markers are keyed by.
    public string? WorkspaceId { get; init; }

    /// The latest entry in the app's activity feed for this session.
    public ActivityPreview? LastActivity { get; init; }

    /// How full the session's context window was when the app last measured it.
    public ContextUsage? ContextUsage { get; init; }

    public bool IsChat => SessionType == "general_chat";
}
