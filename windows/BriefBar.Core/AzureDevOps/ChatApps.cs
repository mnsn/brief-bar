namespace BriefBar.Core.AzureDevOps;

/// Names for the apps people send links in, by their identifiers. The Mac's `ChatApps`.
public static class ChatApps
{
    static readonly Dictionary<string, string> names = new(comparer: StringComparer.Ordinal)
    {
        ["com.microsoft.teams2"] = "Teams",
        ["com.microsoft.teams"] = "Teams",
        ["com.tinyspeck.slackmacgap"] = "Slack",
        ["com.microsoft.Outlook"] = "Outlook",
        ["com.apple.mail"] = "Mail",
        ["com.apple.MobileSMS"] = "Messages",
        ["net.whatsapp.WhatsApp"] = "WhatsApp",
        ["desktop.WhatsApp"] = "WhatsApp",
        ["ru.keepcoder.Telegram"] = "Telegram",
        ["com.hnc.Discord"] = "Discord",
        ["us.zoom.xos"] = "Zoom",
    };

    /// "Teams", or the last part of an app's identifier, capitalized.
    public static string Name(string app)
    {
        ArgumentNullException.ThrowIfNull(argument: app);
        if (names.TryGetValue(key: app, value: out var name))
        {
            return name;
        }
        var last = app.Split(separator: '.', options: StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? app;
        return last.Length == 0 ? last : char.ToUpperInvariant(c: last[0]) + last[1..];
    }
}
