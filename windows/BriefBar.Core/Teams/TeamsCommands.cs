namespace BriefBar.Core.Teams;

/// What the Teams sections' panels can ask them to do, by `PanelCommand.Key`.
public static class TeamsCommands
{
    /// A row: opens its chat in Teams, at its oldest unread message, and reads it in BriefBar.
    public const string Open = "open";

    /// A row: reads its chat in BriefBar, up to its newest message, until Teams' own marker gets there.
    public const string MarkRead = "markRead";

    /// The Unread group: reads every chat in it.
    public const string MarkAllRead = "markAllRead";

    /// The section: opens Teams.
    public const string OpenApp = "openApp";
}
