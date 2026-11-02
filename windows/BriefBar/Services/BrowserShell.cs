using System.Runtime.InteropServices;
using BriefBar.Core;
using BriefBar.Core.Logging;
using Windows.System;

namespace BriefBar.Services;

/// Opens web pages in your browser, for the sources that link to them: Azure DevOps' and GitHub's pull requests, and the
/// pages that say how to install their command-line tools. The Mac's `AzureDevOps.open` and `GitHub.open`.
internal static class BrowserShell
{
    /// Opens `link` for `source`; a page Windows can't open is logged, without the page.
    public static void Open(Uri link, SourceId source) => _ = OpenAsync(link: link, source: source);

    static async Task OpenAsync(Uri link, SourceId source)
    {
        try
        {
            if (!await Launcher.LaunchUriAsync(uri: link))
            {
                Log.Write(line: $"browser: Windows didn't open a page for {source}");
            }
        }
        catch (COMException error)
        {
            Log.Write(error: error, context: $"browser: Windows couldn't open a page for {source}");
        }
        catch (UnauthorizedAccessException error)
        {
            Log.Write(error: error, context: $"browser: Windows couldn't open a page for {source}");
        }
    }
}
