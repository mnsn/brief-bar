namespace BriefBar.Core.Copilot;

/// What the main agent of a session is doing, derived purely from its event log, with what goes with it: since when it
/// works or when it ended (`At`), its current step, summary or error (`Text`), and what it waits on. The Mac's
/// `LogActivity`, whose cases carry values, as one record that only its factories make.
public sealed record LogActivity
{
    LogActivity(LogActivityType type)
    {
        Type = type;
    }

    public LogActivityType Type { get; }

    public DateTimeOffset? At { get; private init; }

    public string? Text { get; private init; }

    public PendingPermission? Permission { get; private init; }

    public PendingTool? Tool { get; private init; }

    public static LogActivity Unknown { get; } = new(type: LogActivityType.Unknown);

    public static LogActivity Working(DateTimeOffset? since, string? detail) =>
        new(type: LogActivityType.Working) { At = since, Text = detail };

    public static LogActivity NeedsPermission(PendingPermission permission) =>
        new(type: LogActivityType.NeedsPermission) { Permission = permission };

    public static LogActivity NeedsAnswer(PendingTool tool) => new(type: LogActivityType.NeedsAnswer) { Tool = tool };

    public static LogActivity NeedsPlanApproval(PendingTool tool) => new(type: LogActivityType.NeedsPlanApproval) { Tool = tool };

    public static LogActivity Finished(DateTimeOffset? at, string? summary) =>
        new(type: LogActivityType.Finished) { At = at, Text = summary };

    public static LogActivity Interrupted(DateTimeOffset? at) => new(type: LogActivityType.Interrupted) { At = at };

    public static LogActivity Failed(DateTimeOffset? at, string? message) =>
        new(type: LogActivityType.Failed) { At = at, Text = message };
}
