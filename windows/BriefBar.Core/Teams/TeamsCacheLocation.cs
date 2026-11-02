using System.Text.RegularExpressions;

namespace BriefBar.Core.Teams;

/// Where the new Teams app keeps its web app's data: a folder per WebView2 profile (`WV2Profile_tfw` for work and school
/// accounts), each with Chromium's `IndexedDB` folder, where the Teams site's databases keep its chats and how far you've
/// read each. `IsTeamsOwn` says it's Teams' own, rather than made-up data that `BRIEFBAR_TEAMS_CACHE` names, laid out the
/// same way. The Mac's `TeamsCacheLocation`.
public sealed partial record TeamsCacheLocation(string Root, bool IsTeamsOwn)
{
    /// Points BriefBar at other data than Teams', laid out the same way, for tests and debugging.
    public const string Variable = "BRIEFBAR_TEAMS_CACHE";

    /// The new Teams app's package, as Windows names it.
    public const string PackageFamilyName = "MSTeams_8wekyb3d8bbwe";

    /// `%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView`, or the folder
    /// `BRIEFBAR_TEAMS_CACHE` names. Windows gives a program no permission that another program running as you lacks, so,
    /// unlike the Mac, it doesn't matter who started BriefBar.
    public static TeamsCacheLocation Default(IReadOnlyDictionary<string, string?> environment)
    {
        ArgumentNullException.ThrowIfNull(argument: environment);
        if (environment.TryGetValue(key: Variable, value: out var overridden) && !string.IsNullOrEmpty(value: overridden))
        {
            return new TeamsCacheLocation(Root: Environment.ExpandEnvironmentVariables(name: overridden), IsTeamsOwn: false);
        }
        var local = Environment.GetFolderPath(folder: Environment.SpecialFolder.LocalApplicationData);
        return new TeamsCacheLocation(
            Root: Path.Combine(paths: [local, "Packages", PackageFamilyName, "LocalCache", "Microsoft", "MSTeams", "EBWebView"]),
            IsTeamsOwn: true);
    }

    /// The Teams site's IndexedDB folders: `<profile>\IndexedDB\https_teams.<domain>_0.indexeddb.leveldb`, in order.
    public IReadOnlyList<string> Folders() => FindFolders().Folders;

    /// The Teams site's IndexedDB folders, in order, and how many folders couldn't be listed, which may hold more.
    public TeamsFolderList FindFolders()
    {
        var folders = new List<string>();
        var unlistable = 0;
        foreach (var profile in Subfolders(path: Root, unlistable: ref unlistable))
        {
            var indexedDB = Path.Combine(path1: profile, path2: "IndexedDB");
            folders.AddRange(collection: Subfolders(path: indexedDB, unlistable: ref unlistable)
                .Where(predicate: folder => IsTeamsFolder(name: Path.GetFileName(path: folder))));
        }
        return new TeamsFolderList(Folders: folders, Unlistable: unlistable);
    }

    public static bool IsTeamsFolder(string name) => TeamsFolder().IsMatch(input: name);

    /// The folders in `path`, in order: none when it isn't there, and none, counted in `unlistable`, when it can't be
    /// listed. Listing it is what tells: `Directory.Exists` says a folder isn't there when Windows can't say whether it is.
    static List<string> Subfolders(string path, ref int unlistable)
    {
        try
        {
            return Directory.EnumerateDirectories(path: path).Order(comparer: StringComparer.Ordinal).ToList();
        }
        catch (DirectoryNotFoundException)
        {
            // Not there, or gone since, as a profile Teams removes: it holds nothing.
            return [];
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            unlistable += 1;
            return [];
        }
    }

    [GeneratedRegex(pattern: @"^https?_teams\.[A-Za-z0-9.\-]+_[0-9]+\.indexeddb\.leveldb$", options: RegexOptions.CultureInvariant)]
    private static partial Regex TeamsFolder();
}
