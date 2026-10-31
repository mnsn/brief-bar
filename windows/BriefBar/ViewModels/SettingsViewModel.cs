using BriefBar.Core;
using BriefBar.Core.Copilot;

namespace BriefBar.ViewModels;

/// What Settings shows: every source you can turn on, whether it's on, and Copilot's own settings.
public sealed class SettingsViewModel
{
    readonly SourceSwitch sources;

    public SettingsViewModel(SourceSwitch sources, CopilotSettings copilot, ThemePalette palette)
    {
        ArgumentNullException.ThrowIfNull(argument: sources);
        this.sources = sources;
        Sources = sources.Entries.Select(selector: entry => new SourceSettingsViewModel(entry: entry, palette: palette)).ToList();
        Copilot = new CopilotSettingsViewModel(settings: copilot);
        Refresh();
    }

    public IReadOnlyList<SourceSettingsViewModel> Sources { get; }

    public CopilotSettingsViewModel Copilot { get; }

    public static string Intro =>
        "Every source is off until you turn it on. Each one first says what it reads, where it connects and what it needs, "
        + "and turning it on is your consent: BriefBar never turns a source on by itself.";

    public static string StillToCome => SourceCatalog.StillToCome + " come to BriefBar for Windows one at a time.";

    /// Whether each source is on, as it stands now.
    public void Refresh()
    {
        foreach (var source in Sources)
        {
            source.State = sources.State(entry: source.Entry);
        }
    }

    public void UsePalette(ThemePalette palette)
    {
        foreach (var source in Sources)
        {
            source.UsePalette(palette: palette);
        }
    }
}
