namespace BriefBar.Core.Copilot;

/// Where a session's main agent is, from its log alone.
public enum LogPhase
{
    Unknown,
    Running,
    Finished,
    Interrupted,
    Failed,
}
