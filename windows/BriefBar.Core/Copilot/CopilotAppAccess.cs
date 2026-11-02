namespace BriefBar.Core.Copilot;

/// What `CopilotSource` asks of Windows about the GitHub Copilot app, which BriefBar.Core can't do itself: open a
/// session's link, bring the app to the front, and whether it's installed, or in front.
public sealed record CopilotAppAccess(Action<string> OpenSession, Action Activate, Func<bool> IsInstalled, Func<bool> IsFrontmost);
