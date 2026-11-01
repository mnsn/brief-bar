namespace BriefBar.Core.Copilot;

/// Where the GitHub Copilot app keeps its local state, laid out on Windows as on the Mac. Everything here is read-only
/// for BriefBar. The Mac's `CopilotPaths`.
public sealed record CopilotPaths
{
    /// Points BriefBar at another Copilot data folder, for tests and debugging.
    public const string DirectoryVariable = "BRIEFBAR_COPILOT_DIR";

    public CopilotPaths(string root)
    {
        ArgumentException.ThrowIfNullOrEmpty(argument: root);
        Root = Path.TrimEndingDirectorySeparator(path: Path.GetFullPath(path: root));
    }

    public string Root { get; }

    /// The app's SQLite database.
    public string Database => Path.Combine(path1: Root, path2: "data.db");

    /// SQLite's write-ahead log, where the app's commits land until a checkpoint.
    public string DatabaseWal => Path.Combine(path1: Root, path2: "data.db-wal");

    public string SessionState => Path.Combine(path1: Root, path2: "session-state");

    /// `%USERPROFILE%\.copilot`, or the folder `BRIEFBAR_COPILOT_DIR` names. Windows gives a program no permission that
    /// another program running as you lacks, so, unlike the Mac, it doesn't matter who started BriefBar.
    public static CopilotPaths Default(IReadOnlyDictionary<string, string?> environment)
    {
        ArgumentNullException.ThrowIfNull(argument: environment);
        if (environment.TryGetValue(key: DirectoryVariable, value: out var overridden) && !string.IsNullOrEmpty(value: overridden))
        {
            return new CopilotPaths(root: Environment.ExpandEnvironmentVariables(name: overridden));
        }
        var home = Environment.GetFolderPath(folder: Environment.SpecialFolder.UserProfile);
        return new CopilotPaths(root: Path.Combine(path1: home, path2: ".copilot"));
    }

    public string SessionDirectory(string id) => Path.Combine(path1: SessionState, path2: id);

    public string EventsFile(string id) => Path.Combine(path1: SessionDirectory(id: id), path2: "events.jsonl");
}
