namespace BriefBar.Core.Teams;

/// What `TeamsSource` asks of Windows about Teams, which BriefBar.Core can't do itself: open a chat's link in Teams, and
/// open Teams.
public sealed record TeamsAccess(Action<Uri> OpenLink, Action OpenApp);
