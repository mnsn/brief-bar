using BriefBar.Core;
using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Copilot;
using BriefBar.Core.GitHub;

namespace BriefBar.ViewModels;

/// What Settings shows: every source you can turn on, whether it's on, and each source's own settings.
public sealed class SettingsViewModel
{
    readonly SourceSwitch sources;

    /// `findOrganizations` asks Azure DevOps to look for your organizations again.
    public SettingsViewModel(
        SourceSwitch sources, AzureDevOpsSettings azureDevOps, CopilotSettings copilot, GitHubSettings gitHub, ThemePalette palette, Action findOrganizations)
    {
        ArgumentNullException.ThrowIfNull(argument: sources);
        this.sources = sources;
        Sources = sources.Entries.Select(selector: entry => new SourceSettingsViewModel(entry: entry, palette: palette)).ToList();
        AzureDevOps = new AzureDevOpsSettingsViewModel(settings: azureDevOps, findOrganizations: findOrganizations);
        Copilot = new CopilotSettingsViewModel(settings: copilot);
        GitHub = new GitHubSettingsViewModel(settings: gitHub);
        Refresh();
    }

    public IReadOnlyList<SourceSettingsViewModel> Sources { get; }

    public AzureDevOpsSettingsViewModel AzureDevOps { get; }

    public CopilotSettingsViewModel Copilot { get; }

    public GitHubSettingsViewModel GitHub { get; }

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

    /// Stops following the sources' settings, as Settings closes.
    public void Detach() => AzureDevOps.Detach();
}
