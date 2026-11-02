namespace BriefBar.Core.AzureDevOps;

/// Finds the Azure CLI on Windows, where `az` is a batch file, `az.cmd`: where `BRIEFBAR_AZ` says, then in the `PATH`, then
/// where its installer puts it (`ProgramLocator`). The Mac's `AzureCLILocator`, which asks a login shell instead.
public sealed class AzureCLILocator
{
    /// Points BriefBar at another `az`, for tests and debugging.
    public const string OverrideVariable = "BRIEFBAR_AZ";

    /// The names `az` has on Windows, in the order Windows looks for programs (`PATHEXT`).
    static readonly string[] names = ["az.exe", "az.cmd", "az.bat"];

    /// The variables that name the folders programs are installed in.
    static readonly string[] programFiles = ["ProgramFiles", "ProgramFiles(x86)"];

    readonly ProgramLocator programs;

    /// - `environment`: `BRIEFBAR_AZ`, `PATH`, `ProgramFiles` and `ProgramFiles(x86)`, as BriefBar's environment has them.
    /// - `exists`: whether a file is there.
    public AzureCLILocator(IReadOnlyDictionary<string, string?> environment, Func<string, bool>? exists = null)
    {
        programs = new ProgramLocator(environment: environment, exists: exists);
    }

    /// The variables the locator reads, as `environment` takes them.
    public static IReadOnlyList<string> Variables { get; } = [OverrideVariable, "PATH", "ProgramFiles", "ProgramFiles(x86)"];

    /// Where its installer puts `az.cmd`, for 64-bit Windows and for the 32-bit CLI.
    public IReadOnlyList<string> UsualPlaces => programFiles
        .Select(selector: variable => programs.Value(name: variable))
        .OfType<string>()
        .Select(selector: folder => Path.Combine(paths: new[] { folder, "Microsoft SDKs", "Azure", "CLI2", "wbin", "az.cmd" }))
        .ToList();

    /// The Azure CLI's program, or null when it isn't anywhere BriefBar looks. A `BRIEFBAR_AZ` that isn't there is passed
    /// over, as on the Mac.
    public string? Locate() => programs.Locate(overrideVariable: OverrideVariable, names: names, usualPlaces: UsualPlaces);
}
