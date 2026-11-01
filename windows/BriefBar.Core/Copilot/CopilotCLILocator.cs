namespace BriefBar.Core.Copilot;

/// Finds the Copilot CLI, `copilot`: where `BRIEFBAR_COPILOT_CLI` says, then in the `PATH`, then where WinGet links it and
/// npm installs it (`ProgramLocator`). Installed with npm, it's a batch file, `copilot.cmd`. The Mac's `CopilotCLI.locate`,
/// which asks a login shell instead.
public sealed class CopilotCLILocator
{
    /// Points BriefBar at another `copilot`, for tests and debugging, as on the Mac.
    public const string OverrideVariable = "BRIEFBAR_COPILOT_CLI";

    /// Where the CLI keeps its settings and sessions, when it's not the usual folder.
    public const string HomeVariable = "COPILOT_HOME";

    /// The names `copilot` has on Windows, in the order Windows looks for programs (`PATHEXT`).
    static readonly string[] names = ["copilot.exe", "copilot.cmd", "copilot.bat"];

    readonly ProgramLocator programs;

    /// - `environment`: `BRIEFBAR_COPILOT_CLI`, `PATH`, `LOCALAPPDATA` and `APPDATA`, as BriefBar's environment has them.
    /// - `exists`: whether a file is there.
    public CopilotCLILocator(IReadOnlyDictionary<string, string?> environment, Func<string, bool>? exists = null)
    {
        programs = new ProgramLocator(environment: environment, exists: exists);
    }

    /// The variables the locator reads, as `environment` takes them.
    public static IReadOnlyList<string> Variables { get; } = [OverrideVariable, "PATH", "LOCALAPPDATA", "APPDATA", HomeVariable, "USERPROFILE"];

    /// Where the CLI keeps its settings and sessions, as it decides by itself: `COPILOT_HOME`, or `.copilot` in your user
    /// folder; null when neither is known. The Mac's `CopilotCLI.home`.
    public string? Home => programs.Value(name: HomeVariable) is { } home
        ? Environment.ExpandEnvironmentVariables(name: home)
        : programs.Value(name: "USERPROFILE") is { } profile ? Path.Combine(path1: profile, path2: ".copilot") : null;

    /// Where WinGet links `copilot.exe`, and where npm installs `copilot.cmd`.
    public IReadOnlyList<string> UsualPlaces
    {
        get
        {
            var places = new List<string>();
            if (programs.Value(name: "LOCALAPPDATA") is { } local)
            {
                places.Add(item: Path.Combine(paths: new[] { local, "Microsoft", "WinGet", "Links", "copilot.exe" }));
            }
            if (programs.Value(name: "APPDATA") is { } roaming)
            {
                places.Add(item: Path.Combine(path1: roaming, path2: "npm", path3: "copilot.cmd"));
            }
            return places;
        }
    }

    /// The Copilot CLI's program, or null when it isn't anywhere BriefBar looks.
    public string? Locate() => programs.Locate(overrideVariable: OverrideVariable, names: names, usualPlaces: UsualPlaces);
}
