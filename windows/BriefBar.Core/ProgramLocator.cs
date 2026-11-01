namespace BriefBar.Core;

/// Finds a command-line program as a terminal would: where an override variable says, when it's there; then in each
/// folder of the `PATH`, by each name the program has on Windows, in the order Windows tries them (`PATHEXT`'s: `.exe`,
/// then `.cmd` and `.bat`); then where its installer puts it, as BriefBar may have started before the `PATH` had it. For
/// the Azure CLI and the Copilot CLI.
public sealed class ProgramLocator
{
    readonly IReadOnlyDictionary<string, string?> environment;
    readonly Func<string, bool> exists;

    /// - `environment`: the variables BriefBar's environment has, of those the program's locator reads.
    /// - `exists`: whether a file is there.
    public ProgramLocator(IReadOnlyDictionary<string, string?> environment, Func<string, bool>? exists = null)
    {
        ArgumentNullException.ThrowIfNull(argument: environment);
        this.environment = environment;
        this.exists = exists ?? File.Exists;
    }

    /// The program: `overrideVariable`'s, unless that isn't there; else the first of `names` in a folder of the `PATH`; else
    /// the first of `usualPlaces` that's there; null when it's nowhere BriefBar looks.
    public string? Locate(string overrideVariable, IReadOnlyList<string> names, IReadOnlyList<string> usualPlaces)
    {
        ArgumentNullException.ThrowIfNull(argument: names);
        ArgumentNullException.ThrowIfNull(argument: usualPlaces);
        if (Value(name: overrideVariable) is { } overridden)
        {
            var expanded = Environment.ExpandEnvironmentVariables(name: overridden);
            if (exists(arg: expanded))
            {
                return expanded;
            }
        }
        foreach (var folder in (Value(name: "PATH") ?? string.Empty).Split(separator: ';', options: StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            foreach (var name in names)
            {
                var candidate = Path.Combine(path1: folder.Trim(trimChar: '"'), path2: name);
                if (Path.IsPathFullyQualified(path: candidate) && exists(arg: candidate))
                {
                    return candidate;
                }
            }
        }
        return usualPlaces.FirstOrDefault(predicate: exists);
    }

    /// The variable `name`, or null when it's unset or empty.
    public string? Value(string name) =>
        environment.TryGetValue(key: name, value: out var value) && !string.IsNullOrEmpty(value: value) ? value : null;
}
