using BriefBar.Core.Presentation;
using Microsoft.Win32;

namespace BriefBar.Shell;

/// Windows' colors for its own shell, the taskbar's, as Settings › Personalization › Colors keeps them: which apps can't
/// ask WinUI or `UISettings`, which say the apps' mode only.
internal static class ShellColors
{
    const string PersonalizeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    /// How the bar and the panel look now, with `appsAreDark` for when Windows doesn't say.
    public static ShellLook Read(bool appsAreDark)
    {
        using var key = Registry.CurrentUser.OpenSubKey(name: PersonalizeKey);
        return ShellLook.Of(
            systemUsesLightTheme: key?.GetValue(name: "SystemUsesLightTheme") as int?,
            colorPrevalence: key?.GetValue(name: "ColorPrevalence") as int?,
            appsAreDark: appsAreDark);
    }
}
