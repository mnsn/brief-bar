namespace BriefBar.Core.Copilot;

/// What one log line says, with what goes with its type: the Mac's `LogEvent.Kind`, whose cases carry values, as one
/// record that only its factories make.
public sealed record LogEventKind
{
    LogEventKind(LogEventType type)
    {
        Type = type;
    }

    public LogEventType Type { get; }

    /// A subagent's turn, reply or stop, which never changes the main agent's phase.
    public bool IsSubagent { get; private init; }

    /// An assistant message that asked for tools.
    public bool HasToolRequests { get; private init; }

    public ToolStart? Tool { get; private init; }

    public PermissionRequest? Permission { get; private init; }

    /// The tool call a completion ends, or the permission prompt a completion answers.
    public string? Id { get; private init; }

    /// Why a turn was aborted, such as `user_initiated` or `subagent_cancelled`.
    public string? Reason { get; private init; }

    public string? ErrorType { get; private init; }

    public string? Message { get; private init; }

    public string? Summary { get; private init; }

    public bool? Success { get; private init; }

    public static LogEventKind UserMessage { get; } = new(type: LogEventType.UserMessage);

    public static LogEventKind SessionStart { get; } = new(type: LogEventType.SessionStart);

    public static LogEventKind SessionResume { get; } = new(type: LogEventType.SessionResume);

    public static LogEventKind SessionShutdown { get; } = new(type: LogEventType.SessionShutdown);

    public static LogEventKind Other { get; } = new(type: LogEventType.Other);

    /// Events from which a session's state can be rebuilt without older history.
    public bool IsAnchor => Type is LogEventType.UserMessage or LogEventType.SessionStart;

    public static LogEventKind TurnStart(bool isSubagent) => new(type: LogEventType.TurnStart) { IsSubagent = isSubagent };

    public static LogEventKind TurnEnd(bool isSubagent) => new(type: LogEventType.TurnEnd) { IsSubagent = isSubagent };

    public static LogEventKind AssistantMessage(bool isSubagent, bool hasToolRequests) =>
        new(type: LogEventType.AssistantMessage) { IsSubagent = isSubagent, HasToolRequests = hasToolRequests };

    public static LogEventKind ToolStarted(ToolStart tool)
    {
        ArgumentNullException.ThrowIfNull(argument: tool);
        return new(type: LogEventType.ToolStart) { Tool = tool };
    }

    public static LogEventKind ToolComplete(string callId) => new(type: LogEventType.ToolComplete) { Id = callId };

    public static LogEventKind PermissionRequested(PermissionRequest request) =>
        new(type: LogEventType.PermissionRequested) { Permission = request };

    public static LogEventKind PermissionCompleted(string requestId) =>
        new(type: LogEventType.PermissionCompleted) { Id = requestId };

    public static LogEventKind AgentStop(bool isSubagent) => new(type: LogEventType.AgentStop) { IsSubagent = isSubagent };

    public static LogEventKind Abort(string? reason) => new(type: LogEventType.Abort) { Reason = reason };

    public static LogEventKind SessionError(string? errorType, string? message) =>
        new(type: LogEventType.SessionError) { ErrorType = errorType, Message = message };

    public static LogEventKind TaskComplete(string? summary, bool? success) =>
        new(type: LogEventType.TaskComplete) { Summary = summary, Success = success };
}
