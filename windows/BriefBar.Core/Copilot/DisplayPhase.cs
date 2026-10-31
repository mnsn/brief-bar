namespace BriefBar.Core.Copilot;

/// The groups a session list shows, in their order: what needs you first, idle last.
public enum DisplayPhase
{
    NeedsYou,
    Running,
    Done,
    Stopped,
    Idle,
}
