using System.Runtime.InteropServices;
using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Logging;
using Windows.System;

namespace BriefBar.Services;

/// What Windows does for `AzureDevOpsSource`: it opens Azure DevOps' pages, and the Azure CLI's, in your browser. The
/// Mac's `AzureDevOps.open`.
internal static class AzureDevOpsShell
{
    public static AzureDevOpsAccess Access { get; } = new(OpenLink: link => _ = OpenAsync(link: link));

    /// A page Windows can't open is logged, without the page.
    static async Task OpenAsync(Uri link)
    {
        try
        {
            if (!await Launcher.LaunchUriAsync(uri: link))
            {
                Log.Write(line: $"azureDevOps: Windows didn't open the page");
            }
        }
        catch (COMException error)
        {
            Log.Write(error: error, context: $"azureDevOps: Windows couldn't open the page");
        }
        catch (UnauthorizedAccessException error)
        {
            Log.Write(error: error, context: $"azureDevOps: Windows couldn't open the page");
        }
    }
}
