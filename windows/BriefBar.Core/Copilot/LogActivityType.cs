namespace BriefBar.Core.Copilot;

/// What a session's main agent is doing, from its log: the cases of the Mac's `LogActivity`.
public enum LogActivityType
{
    Unknown,
    Working,
    NeedsPermission,
    NeedsAnswer,
    NeedsPlanApproval,
    Finished,
    Interrupted,
    Failed,
}
