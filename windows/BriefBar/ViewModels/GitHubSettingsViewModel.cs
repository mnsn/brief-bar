using BriefBar.Core.GitHub;

namespace BriefBar.ViewModels;

/// GitHub's own settings, on its page in Settings, as the Mac's gear menu and Settings page offer them: how often it
/// reads. Each change is saved at once, and the next read follows it.
public sealed class GitHubSettingsViewModel : Observable
{
    readonly GitHubSettings settings;

    public GitHubSettingsViewModel(GitHubSettings settings)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        this.settings = settings;
    }

    public IReadOnlyList<string> RefreshTitles { get; } = GitHubSettings.RefreshChoices.Select(selector: GitHubSettings.RefreshTitle).ToList();

    /// Which of `RefreshTitles` is chosen.
    public int RefreshIndex
    {
        get => GitHubSettings.RefreshChoices.ToList().IndexOf(item: settings.RefreshMinutes);
        set
        {
            if (value >= 0 && value < GitHubSettings.RefreshChoices.Count)
            {
                settings.RefreshMinutes = GitHubSettings.RefreshChoices[value];
            }
        }
    }
}
