namespace BriefBar.Core.Presentation;

/// What a panel can ask of BriefBar itself rather than of a source, by `PanelCommand.Key`.
public static class AppCommands
{
    /// Opens Settings at the page of the source whose section asks, as a paused source's Review does.
    public const string ReviewSource = "briefbar.reviewSource";
}
