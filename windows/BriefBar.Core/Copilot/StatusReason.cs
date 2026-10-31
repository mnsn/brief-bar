namespace BriefBar.Core.Copilot;

/// Why a session is in its group. Idle sessions keep the reason they ended with.
public enum StatusReason
{
    Question,
    PlanApproval,
    Permission,
    Working,
    Starting,

    /// Waits on a question or plan that the session coordinating it asks you for it (`RelayedQuestions`).
    Relayed,
    Finished,
    Interrupted,
    Failed,
    Unresponsive,
    Idle,
}
