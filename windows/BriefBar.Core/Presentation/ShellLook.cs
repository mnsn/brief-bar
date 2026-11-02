namespace BriefBar.Core.Presentation;

/// How the bar and the panel look in Windows' colors: in Windows' mode, as the taskbar and its flyouts are, which can
/// differ from the apps' mode that Settings follows (Settings › Personalization › Colors › Custom); and tinted with the
/// accent color, as the taskbar is, when "Show accent color on Start and taskbar" is on, which Windows offers in dark
/// only.
public sealed record ShellLook(bool IsDark, bool UsesAccent)
{
    /// From Personalize's `SystemUsesLightTheme` and `ColorPrevalence` in the registry, each null when Windows doesn't
    /// say, and the apps' mode, which Windows' mode is when Windows doesn't say.
    public static ShellLook Of(int? systemUsesLightTheme, int? colorPrevalence, bool appsAreDark)
    {
        var isDark = systemUsesLightTheme is { } light ? light == 0 : appsAreDark;
        return new ShellLook(IsDark: isDark, UsesAccent: isDark && colorPrevalence == 1);
    }
}
