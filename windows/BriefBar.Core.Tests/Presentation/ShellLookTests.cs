using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

public sealed class ShellLookTests
{
    [Theory]
    // Windows' mode, whatever the apps' is: Settings › Personalization › Colors › Custom.
    [InlineData(0, false, true)]
    [InlineData(1, true, false)]
    [InlineData(1, false, false)]
    [InlineData(0, true, true)]
    // Windows doesn't say: the apps' mode.
    [InlineData(null, true, true)]
    [InlineData(null, false, false)]
    public void FollowsWindowsModeAsTheTaskbarDoes(int? systemUsesLightTheme, bool appsAreDark, bool isDark)
    {
        var look = ShellLook.Of(systemUsesLightTheme: systemUsesLightTheme, colorPrevalence: null, appsAreDark: appsAreDark);
        Assert.Equal(expected: isDark, actual: look.IsDark);
    }

    [Theory]
    [InlineData(0, 1, true)]
    [InlineData(0, 0, false)]
    [InlineData(0, null, false)]
    // In light, Windows doesn't show the accent on the taskbar, even if the setting says so.
    [InlineData(1, 1, false)]
    public void UsesTheAccentWhereTheTaskbarDoes(int? systemUsesLightTheme, int? colorPrevalence, bool usesAccent)
    {
        var look = ShellLook.Of(systemUsesLightTheme: systemUsesLightTheme, colorPrevalence: colorPrevalence, appsAreDark: false);
        Assert.Equal(expected: usesAccent, actual: look.UsesAccent);
    }
}
