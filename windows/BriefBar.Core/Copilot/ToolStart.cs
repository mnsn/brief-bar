namespace BriefBar.Core.Copilot;

/// A tool call the agent started, from `tool.execution_start`.
public sealed record ToolStart
{
    public required string CallId { get; init; }

    public required string Name { get; init; }

    public bool IsSubagent { get; init; }

    public string? Title { get; init; }

    /// Free-text description argument some tools take, such as `bash`'s.
    public string? Description { get; init; }

    /// `ask_user`'s question and choices.
    public string? Question { get; init; }

    public ValueList<string> Choices { get; init; } = ValueList<string>.Empty;

    /// `exit_plan_mode`'s summary.
    public string? PlanSummary { get; init; }

    /// `relay_session_input`: the session whose question it asks you, by its session or workspace ID.
    public string? RelayedSession { get; init; }

    /// `relay_session_input`: what it says before the question, which it doesn't repeat.
    public string? RelayContext { get; init; }
}
