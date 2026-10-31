namespace BriefBar.Core.Copilot;

/// How a session's reason is said.
public static class StatusReasons
{
    /// Where it stands, in a few words: "Waiting for your answer".
    public static string Headline(this StatusReason reason) => reason switch
    {
        StatusReason.Question => "Waiting for your answer",
        StatusReason.PlanApproval => "Plan ready for review",
        StatusReason.Permission => "Needs permission",
        StatusReason.Working => "Working",
        StatusReason.Starting => "Starting…",
        StatusReason.Relayed => "Answer in another session",
        StatusReason.Finished => "Finished",
        StatusReason.Interrupted => "Interrupted",
        StatusReason.Failed => "Error",
        StatusReason.Unresponsive => "Stopped responding",
        StatusReason.Idle => "Idle",
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(reason), actualValue: reason, message: "Not a reason."),
    };
}
