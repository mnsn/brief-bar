using BriefBar.Core.Copilot;

namespace BriefBar.Core.Tests.Copilot;

/// Where the Copilot CLI is: where `BRIEFBAR_COPILOT_CLI` says, then in the `PATH` in Windows' order, then where WinGet
/// links it and npm installs it; and where it keeps its sessions by itself.
public sealed class CopilotCLILocatorTests
{
    static readonly Dictionary<string, string?> environment = new(comparer: StringComparer.OrdinalIgnoreCase)
    {
        ["PATH"] = @"C:\Tools;""C:\Quoted Tools"";relative\bin;",
        ["LOCALAPPDATA"] = @"C:\Users\robin\AppData\Local",
        ["APPDATA"] = @"C:\Users\robin\AppData\Roaming",
        ["USERPROFILE"] = @"C:\Users\robin",
    };

    [Fact]
    public void LooksInThePathInWindowsOrder()
    {
        Assert.Equal(expected: @"C:\Tools\copilot.cmd", actual: Locator(present: [@"C:\Tools\copilot.cmd", @"C:\Quoted Tools\copilot.exe"]).Locate());
        Assert.Equal(expected: @"C:\Tools\copilot.exe", actual: Locator(present: [@"C:\Tools\copilot.cmd", @"C:\Tools\copilot.exe"]).Locate());
        Assert.Equal(expected: @"C:\Quoted Tools\copilot.exe", actual: Locator(present: [@"C:\Quoted Tools\copilot.exe"]).Locate());
        // A folder that isn't a whole path is passed over.
        Assert.Null(@object: Locator(present: [@"relative\bin\copilot.exe"]).Locate());
    }

    [Fact]
    public void LooksWhereWinGetAndNpmPutIt()
    {
        var winGet = @"C:\Users\robin\AppData\Local\Microsoft\WinGet\Links\copilot.exe";
        var npm = @"C:\Users\robin\AppData\Roaming\npm\copilot.cmd";
        Assert.Equal(expected: [winGet, npm], actual: Locator(present: []).UsualPlaces);
        Assert.Equal(expected: winGet, actual: Locator(present: [npm, winGet]).Locate());
        Assert.Equal(expected: npm, actual: Locator(present: [npm]).Locate());
        Assert.Equal(expected: @"C:\Tools\copilot.exe", actual: Locator(present: [npm, @"C:\Tools\copilot.exe"]).Locate());
    }

    /// `BRIEFBAR_COPILOT_CLI` comes first, unless it isn't there, as on the Mac.
    [Fact]
    public void TakesTheOverrideWhenItsThere()
    {
        var overridden = new Dictionary<string, string?>(dictionary: environment, comparer: StringComparer.OrdinalIgnoreCase)
        {
            [CopilotCLILocator.OverrideVariable] = @"D:\Custom\copilot.exe",
        };
        Assert.Equal(expected: @"D:\Custom\copilot.exe", actual: new CopilotCLILocator(environment: overridden, exists: _ => true).Locate());
        Assert.Equal(
            expected: @"C:\Tools\copilot.exe",
            actual: new CopilotCLILocator(environment: overridden, exists: path => path == @"C:\Tools\copilot.exe").Locate());
    }

    [Fact]
    public void KnowsWhereTheCliKeepsItsSessionsByItself()
    {
        Assert.Equal(expected: @"C:\Users\robin\.copilot", actual: Locator(present: []).Home);
        var elsewhere = new Dictionary<string, string?>(dictionary: environment, comparer: StringComparer.OrdinalIgnoreCase)
        {
            [CopilotCLILocator.HomeVariable] = @"D:\Copilot",
        };
        Assert.Equal(expected: @"D:\Copilot", actual: new CopilotCLILocator(environment: elsewhere).Home);
        Assert.Null(@object: new CopilotCLILocator(environment: new Dictionary<string, string?>()).Home);
    }

    static CopilotCLILocator Locator(IReadOnlyList<string> present) => new(environment: environment, exists: present.Contains);
}
