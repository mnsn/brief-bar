namespace BriefBar.Core.AzureDevOps;

/// Someone sent you a link to a pull request in an app that posts notifications, such as Teams: only this is kept, never
/// the message. BriefBar for Windows doesn't read notifications for links yet, so it has none of these outside tests; the
/// classifier treats them as the Mac does. The Mac's `ChatLink`.
public sealed record ChatLink(PullRequestLink Link, string App, string? Sender, DateTimeOffset SentAt, string NotificationKey)
{
    /// The app, its notification, and the pull request: another app may use the same notification's identifier.
    public string Id => App + "|" + NotificationKey + "#" + Link.Key;

    public PRKey Key => Link.Key;

    /// Such as "Teams".
    public string AppName => ChatApps.Name(app: App);
}
