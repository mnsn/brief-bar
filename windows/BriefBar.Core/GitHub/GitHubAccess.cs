namespace BriefBar.Core.GitHub;

/// What `GitHubSource` asks of Windows, which BriefBar.Core can't do itself: open a page in your browser.
public sealed record GitHubAccess(Action<Uri> OpenLink);
