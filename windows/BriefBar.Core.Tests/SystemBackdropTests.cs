using System.Text.RegularExpressions;

namespace BriefBar.Core.Tests;

/// WinUI calls a backdrop's `OnDefaultSystemBackdropConfigurationChanged` as Windows switches between light and dark,
/// with a target or XamlRoot it holds only weakly, so either can be null, and the base implementation rejects a null one.
/// That ended BriefBar. No test here can host WinUI, so this checks the app's code: each of its backdrops overrides it,
/// and nothing calls the base.
public sealed partial class SystemBackdropTests
{
    [GeneratedRegex(pattern: @"\bclass\s+\w+(\s*\([^)]*\))?\s*:\s*SystemBackdrop\b")]
    private static partial Regex Backdrop();

    [GeneratedRegex(pattern: @"\boverride\s+void\s+OnDefaultSystemBackdropConfigurationChanged\b")]
    private static partial Regex ThemeChangeOverride();

    [GeneratedRegex(pattern: @"\bbase\s*\.\s*OnDefaultSystemBackdropConfigurationChanged\b")]
    private static partial Regex BaseThemeChange();

    [Fact]
    public void EveryBackdropHandlesThemeChangesItself()
    {
        var backdrops = AppSources()
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

    [Fact]
    public void NothingCallsTheBaseThemeChange()
    {
        var calling = AppSources()
            .Where(predicate: source => BaseThemeChange().IsMatch(input: source.Text))
            .Select(selector: source => source.File)
            .ToList();
        Assert.Empty(collection: calling);
    }

    /// The app's own C# files, with their text.
    static List<(string File, string Text)> AppSources() => SourceTree.Files()
        .Where(predicate: file => file.StartsWith(value: "BriefBar/", comparisonType: StringComparison.Ordinal))
        .Select(selector: file => (File: file, Text: SourceTree.Read(file: file)))
        .ToList();
}
