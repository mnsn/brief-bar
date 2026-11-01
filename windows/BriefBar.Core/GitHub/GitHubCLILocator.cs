namespace BriefBar.Core.GitHub;

/// Finds the GitHub CLI, `gh`: where `BRIEFBAR_GH` says, then in the `PATH`, then where its installer puts it, for 64-bit
/// and 32-bit Windows, and where WinGet links it (`ProgramLocator`). The Mac's `GitHubCLILocator`, which asks a login shell
/// instead.
public sealed class GitHubCLILocator
{
    /// Points BriefBar at another `gh`, for tests and debugging, as on the Mac.
    public const string OverrideVariable = "BRIEFBAR_GH";

    /// The names `gh` has on Windows, in the order Windows looks for programs (`PATHEXT`).
    static readonly string[] names = ["gh.exe", "gh.cmd", "gh.bat"];

    /// The variables that name the folders programs are installed in.
    static readonly string[] programFiles = ["ProgramFiles", "ProgramFiles(x86)"];

    readonly ProgramLocator programs;

    /// - `environment`: `BRIEFBAR_GH`, `PATH`, `ProgramFiles`, `ProgramFiles(x86)` and `LOCALAPPDATA`, as BriefBar's
    ///   environment has them.
    /// - `exists`: whether a file is there.
    public GitHubCLILocator(IReadOnlyDictionary<string, string?> environment, Func<string, bool>? exists = null)
    {
        programs = new ProgramLocator(environment: environment, exists: exists);
    }

    /// The variables the locator reads, as `environment` takes them.
    public static IReadOnlyList<string> Variables { get; } = [OverrideVariable, "PATH", "ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"];

    /// Where its installer puts `gh.exe`, for 64-bit Windows and for the 32-bit CLI, and where WinGet links it.
    public IReadOnlyList<string> UsualPlaces
    {
        get
        {
            var places = programFiles
                .Select(selector: variable => programs.Value(name: variable))
                .OfType<string>()
                .Select(selector: folder => Path.Combine(path1: folder, path2: "GitHub CLI", path3: "gh.exe"))
                .ToList();
            if (programs.Value(name: "LOCALAPPDATA") is { } local)
            {
                places.Add(item: Path.Combine(paths: new[] { local, "Microsoft", "WinGet", "Links", "gh.exe" }));
            }
            return places;
        }
    }

    /// The GitHub CLI's program, or null when it isn't anywhere BriefBar looks. A `BRIEFBAR_GH` that isn't there is passed
    /// over, as on the Mac.
    public string? Locate() => programs.Locate(overrideVariable: OverrideVariable, names: names, usualPlaces: UsualPlaces);
}
