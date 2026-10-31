namespace BriefBar.Core.Copilot;

/// Reducer over a session's events. Subagent events (`parentToolCallId`) never change the main agent's phase; they only
/// matter through the main agent's own tool calls. The Mac's `SessionLogState`, which is a value there: here,
/// `EventLogReader` replaces its state with a changed copy (`Clone`) rather than changing it, so that a state it gave out
/// stays as it was.
public sealed class SessionLogState : IEquatable<SessionLogState>
{
    static readonly HashSet<string> interactionTools = new(
        collection: ["ask_user", "exit_plan_mode", "report_intent", "task_complete"], comparer: StringComparer.Ordinal);

    readonly Dictionary<string, PendingTool> pendingTools = new(comparer: StringComparer.Ordinal);
    readonly Dictionary<string, PendingPermission> pendingPermissions = new(comparer: StringComparer.Ordinal);

    public LogPhase Phase { get; private set; }

    public DateTimeOffset? PhaseSince { get; private set; }

    public DateTimeOffset? LastEventAt { get; private set; }

    public string? ErrorMessage { get; private set; }

    public string? Summary { get; private set; }

    /// Short description of the latest main-agent tool call, such as a bash command's description.
    public string? CurrentStep { get; private set; }

    public IReadOnlyDictionary<string, PendingTool> PendingTools => pendingTools;

    public IReadOnlyDictionary<string, PendingPermission> PendingPermissions => pendingPermissions;

    public bool LastMainMessageHadTools { get; private set; }

    public LogActivity Activity
    {
        get
        {
            if (Phase is LogPhase.Running or LogPhase.Unknown)
            {
                var permission = pendingPermissions.Values
                    .OrderBy(keySelector: pending => pending.RequestedAt ?? DateTimeOffset.MinValue)
                    .ThenBy(keySelector: pending => pending.RequestId, comparer: StringComparer.Ordinal)
                    .FirstOrDefault();
                if (permission is not null)
                {
                    return LogActivity.NeedsPermission(permission: permission);
                }
                var tools = pendingTools.Values
                    .OrderBy(keySelector: pending => pending.StartedAt ?? DateTimeOffset.MinValue)
                    .ThenBy(keySelector: pending => pending.CallId, comparer: StringComparer.Ordinal)
                    .ToList();
                if (tools.Find(match: tool => tool.Name == "ask_user") is { } question)
                {
                    return LogActivity.NeedsAnswer(tool: question);
                }
                if (tools.Find(match: tool => tool.Name == "exit_plan_mode") is { } plan)
                {
                    return LogActivity.NeedsPlanApproval(tool: plan);
                }
                // Only then a question it relays for a session it coordinates, which may show as work instead.
                if (tools.Find(match: tool => tool.RelaysQuestion) is { } relay)
                {
                    return LogActivity.NeedsAnswer(tool: relay);
                }
            }
            return Phase switch
            {
                LogPhase.Unknown => LogActivity.Unknown,
                LogPhase.Running => LogActivity.Working(since: PhaseSince, detail: CurrentStep),
                LogPhase.Finished => LogActivity.Finished(at: PhaseSince, summary: Summary),
                LogPhase.Interrupted => LogActivity.Interrupted(at: PhaseSince),
                LogPhase.Failed => LogActivity.Failed(at: PhaseSince, message: ErrorMessage),
                _ => throw new InvalidOperationException(message: "Not a phase."),
            };
        }
    }

    /// A copy, to change without changing this one.
    public SessionLogState Clone()
    {
        var copy = new SessionLogState
        {
            Phase = Phase,
            PhaseSince = PhaseSince,
            LastEventAt = LastEventAt,
            ErrorMessage = ErrorMessage,
            Summary = Summary,
            CurrentStep = CurrentStep,
            LastMainMessageHadTools = LastMainMessageHadTools,
        };
        foreach (var (callId, tool) in pendingTools)
        {
            copy.pendingTools[callId] = tool;
        }
        foreach (var (requestId, permission) in pendingPermissions)
        {
            copy.pendingPermissions[requestId] = permission;
        }
        return copy;
    }

    public void Apply(IEnumerable<LogEvent> events)
    {
        ArgumentNullException.ThrowIfNull(argument: events);
        foreach (var logEvent in events)
        {
            Apply(logEvent: logEvent);
        }
    }

    public void Apply(LogEvent logEvent)
    {
        ArgumentNullException.ThrowIfNull(argument: logEvent);
        var previousEventAt = LastEventAt;
        if (logEvent.Timestamp is { } timestamp && timestamp > (LastEventAt ?? DateTimeOffset.MinValue))
        {
            LastEventAt = timestamp;
        }
        var at = logEvent.Timestamp ?? LastEventAt;
        var kind = logEvent.Kind;

        switch (kind.Type)
        {
            case LogEventType.UserMessage:
                // Anything still pending from a previous, already-ended interaction is stale.
                if (Phase != LogPhase.Running)
                {
                    ClearPending();
                    LastMainMessageHadTools = false;
                    CurrentStep = null;
                }
                ErrorMessage = null;
                Summary = null;
                Enter(phase: LogPhase.Running, at: at);
                break;

            case LogEventType.TurnStart when !kind.IsSubagent:
                Enter(phase: LogPhase.Running, at: at);
                break;

            case LogEventType.AssistantMessage when !kind.IsSubagent:
                LastMainMessageHadTools = kind.HasToolRequests;
                EnterRunningIfUnknown(at: at);
                break;

            case LogEventType.ToolStart when kind.Tool is { IsSubagent: false } tool:
                pendingTools[tool.CallId] = new PendingTool
                {
                    CallId = tool.CallId,
                    Name = tool.Name,
                    StartedAt = at,
                    Question = tool.Question,
                    Choices = tool.Choices,
                    PlanSummary = tool.PlanSummary,
                    RelayedSession = tool.RelayedSession,
                    RelayContext = tool.RelayContext,
                };
                if (!interactionTools.Contains(item: tool.Name))
                {
                    CurrentStep = tool.Description ?? tool.Title;
                }
                EnterRunningIfUnknown(at: at);
                break;

            case LogEventType.ToolComplete when kind.Id is { } callId:
                pendingTools.Remove(key: callId);
                break;

            case LogEventType.PermissionRequested when kind.Permission is { } request:
                pendingPermissions[request.RequestId] = new PendingPermission
                {
                    RequestId = request.RequestId,
                    Kind = request.Kind,
                    Detail = request.Detail,
                    RequestedAt = at,
                };
                EnterRunningIfUnknown(at: at);
                break;

            case LogEventType.PermissionCompleted when kind.Id is { } requestId:
                pendingPermissions.Remove(key: requestId);
                break;

            case LogEventType.TurnEnd when !kind.IsSubagent:
                // turn_end also separates model turns mid-run (immediately followed by turn_start), so it only means
                // "done" when the last reply asked for no tools and nothing is pending.
                if (Phase == LogPhase.Running && !LastMainMessageHadTools && pendingTools.Count == 0 && pendingPermissions.Count == 0)
                {
                    Finish(at: at);
                }
                break;

            case LogEventType.AgentStop when !kind.IsSubagent:
                if (Phase is LogPhase.Running or LogPhase.Unknown)
                {
                    Finish(at: at);
                }
                break;

            case LogEventType.Abort when kind.Reason != "subagent_cancelled":
                ClearPending();
                CurrentStep = null;
                Enter(phase: LogPhase.Interrupted, at: at);
                break;

            case LogEventType.SessionError:
                ClearPending();
                CurrentStep = null;
                ErrorMessage = kind.Message;
                Enter(phase: LogPhase.Failed, at: at);
                break;

            case LogEventType.SessionShutdown:
                ClearPending();
                if (Phase == LogPhase.Running)
                {
                    CurrentStep = null;
                    Enter(phase: LogPhase.Interrupted, at: at);
                }
                break;

            case LogEventType.TaskComplete:
                Summary = kind.Summary;
                if (Phase is LogPhase.Running or LogPhase.Unknown)
                {
                    Finish(at: at);
                }
                break;

            case LogEventType.SessionResume:
                // A new CLI process dropped what the previous one left pending. Without a shutdown event, that process
                // stopped mid-turn, the last time it wrote something.
                ClearPending();
                LastMainMessageHadTools = false;
                CurrentStep = null;
                if (Phase == LogPhase.Running)
                {
                    Enter(phase: LogPhase.Interrupted, at: previousEventAt ?? at);
                }
                break;

            default:
                // A subagent's turn, reply, tool or stop; a cancelled subagent; the session's start; anything else.
                break;
        }
    }

    public bool Equals(SessionLogState? other) =>
        other is not null
        && (ReferenceEquals(objA: this, objB: other)
            || (Phase == other.Phase
                && PhaseSince == other.PhaseSince
                && LastEventAt == other.LastEventAt
                && ErrorMessage == other.ErrorMessage
                && Summary == other.Summary
                && CurrentStep == other.CurrentStep
                && LastMainMessageHadTools == other.LastMainMessageHadTools
                && SameEntries(left: pendingTools, right: other.pendingTools)
                && SameEntries(left: pendingPermissions, right: other.pendingPermissions)));

    public override bool Equals(object? obj) => Equals(other: obj as SessionLogState);

    public override int GetHashCode() =>
        HashCode.Combine(value1: Phase, value2: PhaseSince, value3: LastEventAt, value4: CurrentStep, value5: pendingTools.Count, value6: pendingPermissions.Count);

    static bool SameEntries<T>(Dictionary<string, T> left, Dictionary<string, T> right) =>
        left.Count == right.Count
        && left.All(predicate: entry => right.TryGetValue(key: entry.Key, value: out var value) && EqualityComparer<T>.Default.Equals(x: entry.Value, y: value));

    void EnterRunningIfUnknown(DateTimeOffset? at)
    {
        if (Phase == LogPhase.Unknown)
        {
            Enter(phase: LogPhase.Running, at: at);
        }
    }

    void Enter(LogPhase phase, DateTimeOffset? at)
    {
        if (Phase != phase)
        {
            Phase = phase;
            PhaseSince = at;
        }
        else if (PhaseSince is null)
        {
            PhaseSince = at;
        }
    }

    void Finish(DateTimeOffset? at)
    {
        ClearPending();
        CurrentStep = null;
        Enter(phase: LogPhase.Finished, at: at);
    }

    void ClearPending()
    {
        pendingTools.Clear();
        pendingPermissions.Clear();
    }
}
