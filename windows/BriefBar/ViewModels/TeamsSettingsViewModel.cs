using BriefBar.Core.Teams;

namespace BriefBar.ViewModels;

/// Teams' own settings, on its page in Settings, as the Mac's gear menu and Settings page offer them: how long a message
/// stays unread, and whether rows show what messages say. Each change is saved at once, and Teams' lists follow it.
public sealed class TeamsSettingsViewModel : Observable
{
    readonly TeamsSettings settings;

    public TeamsSettingsViewModel(TeamsSettings settings)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        this.settings = settings;
    }

    public IReadOnlyList<string> KeepUnreadTitles { get; } = TeamsSettings.KeepUnreadChoices.Select(selector: TeamsSettings.KeepUnreadTitle).ToList();

    /// Which of `KeepUnreadTitles` is chosen.
    public int KeepUnreadIndex
    {
        get => TeamsSettings.KeepUnreadChoices.ToList().IndexOf(item: settings.KeepUnread);
        set
        {
            if (value >= 0 && value < TeamsSettings.KeepUnreadChoices.Count)
            {
                settings.KeepUnread = TeamsSettings.KeepUnreadChoices[value];
            }
        }
    }

    public bool ShowMessagePreviews
    {
        get => settings.ShowMessagePreviews;
        set => settings.ShowMessagePreviews = value;
    }
}
