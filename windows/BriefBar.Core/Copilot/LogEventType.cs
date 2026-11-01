namespace BriefBar.Core.Copilot;

/// What a line of a session's `events.jsonl` is, for status tracking.
public enum LogEventType
{
    UserMessage,
    TurnStart,
    TurnEnd,
    AssistantMessage,
    ToolStart,
    ToolComplete,
    PermissionRequested,
    PermissionCompleted,

    /// `hook.start` with `hookType == "agentStop"`: the agent finished its interaction.
    AgentStop,
    Abort,
    SessionError,
    SessionStart,

    /// A resume that abandoned what the previous CLI process left pending. A resume that keeps that work waiting, or
    /// joins a turn another client is running, is `Other`.
    SessionResume,
    SessionShutdown,
    TaskComplete,
    Other,
}
