namespace BriefBar.Core.Copilot;

/// A tool call of the main agent that hasn't completed: a question it asks, a plan, or work.
public sealed record PendingTool
{
    public required string CallId { get; init; }

    public required string Name { get; init; }

    public DateTimeOffset? StartedAt { get; init; }

    public string? Question { get; init; }

    public ValueList<string> Choices { get; init; } = ValueList<string>.Empty;

    public string? PlanSummary { get; init; }

    /// The session whose question a coordinating session asks you (`relay_session_input`), by its session or workspace
    /// ID.
    public string? RelayedSession { get; init; }

    public string? RelayContext { get; init; }

    /// Asks you a question that a session it coordinates waits on.
    public bool RelaysQuestion => Name == "relay_session_input";
}
