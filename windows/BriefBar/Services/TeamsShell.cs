using System.Runtime.InteropServices;
using BriefBar.Core.Logging;
using BriefBar.Core.Teams;
using Windows.System;

namespace BriefBar.Services;

/// The new Teams app, as Windows knows it, for `TeamsSource`: a chat's `msteams:` link opens it there, as on the Mac, and
/// only in the new Teams app's package, never in another program that claims the scheme, such as classic Teams. The
/// Mac's `TeamsApp`.
internal static class TeamsShell
{
    /// What opens Teams itself, at whatever it shows.
    static readonly Uri app = new(uriString: "msteams:");

    public static TeamsAccess Access { get; } = new(OpenLink: Launch, OpenApp: () => Launch(link: app));

    /// Opens `link` in Teams. A link Windows can't open is logged, without the link.
    static void Launch(Uri link) => _ = LaunchAsync(link: link);

    static async Task LaunchAsync(Uri link)
    {
        try
        {
            var options = new LauncherOptions { TargetApplicationPackageFamilyName = TeamsCacheLocation.PackageFamilyName };
            if (!await Launcher.LaunchUriAsync(uri: link, options: options))
            {
                Log.Write(line: $"teams: Windows didn't open Teams' link");
            }
        }
        catch (COMException error)
        {
            Log.Write(error: error, context: $"teams: Windows couldn't open Teams' link");
        }
        catch (UnauthorizedAccessException error)
        {
            Log.Write(error: error, context: $"teams: Windows couldn't open Teams' link");
        }
    }
}
