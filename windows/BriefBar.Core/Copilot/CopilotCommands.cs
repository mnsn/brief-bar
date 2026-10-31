namespace BriefBar.Core.Copilot;

/// What the Copilot section's panel can ask it to do, by `PanelCommand.Key`.
public static class CopilotCommands
{
    /// A row: opens its session in the Copilot app, or the session that asks you its question.
    public const string Open = "open";

    /// A row whose question another session asks you: opens the session itself.
    public const string OpenItself = "openItself";

    /// A row: opens the session that started it, which its ↳ tag names.
    public const string OpenParent = "openParent";

    /// The Done or Stopped group: moves its sessions to Idle.
    public const string Clear = "clear";

    /// The section: brings the Copilot app to the front.
    public const string OpenApp = "openApp";
}
