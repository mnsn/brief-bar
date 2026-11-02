using System.Text.RegularExpressions;

namespace BriefBar.Core.Tests;

/// WinUI calls a backdrop's `OnDefaultSystemBackdropConfigurationChanged` as Windows switches between light and dark.
/// Its base implementation throws for a backdrop that keeps its own configuration, as BriefBar's do, and that ended
/// BriefBar. No test here can host WinUI, so this checks the app's code: each of its backdrops overrides it.
public sealed partial class SystemBackdropTests
{
    [GeneratedRegex(pattern: @"\bclass\s+\w+(\s*\([^)]*\))?\s*:\s*SystemBackdrop\b")]
    private static partial Regex Backdrop();

    [GeneratedRegex(pattern: @"\boverride\s+void\s+OnDefaultSystemBackdropConfigurationChanged\b")]
    private static partial Regex ThemeChangeOverride();

    [Fact]
    public void EveryBackdropHandlesThemeChangesItself()
    {
        var backdrops = SourceTree.Files()
            .Where(predicate: file => file.StartsWith(value: "BriefBar/", comparisonType: StringComparison.Ordinal))
            .Select(selector: file => (File: file, Text: SourceTree.Read(file: file)))
            .Where(predicate: source => Backdrop().IsMatch(input: source.Text))
            .ToList();
        // Guards against passing because it found none.
        Assert.Contains(collection: backdrops, filter: source => source.File == "BriefBar/Shell/ActiveAcrylic.cs");
        var missing = backdrops
            .Where(predicate: source => !ThemeChangeOverride().IsMatch(input: source.Text))
            .Select(selector: source => source.File)
            .ToList();
        Assert.Empty(collection: missing);
    }
}
