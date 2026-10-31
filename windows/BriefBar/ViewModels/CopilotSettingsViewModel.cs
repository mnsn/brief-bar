using BriefBar.Core.Copilot;

namespace BriefBar.ViewModels;

/// Copilot's own settings, on its page in Settings, as the Mac's gear menu and Settings page offer them. Each change is
/// saved at once, and Copilot's list follows it.
public sealed class CopilotSettingsViewModel : Observable
{
    readonly CopilotSettings settings;

    public CopilotSettingsViewModel(CopilotSettings settings)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        this.settings = settings;
    }

    public IReadOnlyList<string> KeepEndedTitles { get; } = CopilotSettings.KeepEndedChoices.Select(selector: CopilotSettings.KeepEndedTitle).ToList();

    /// Which of `KeepEndedTitles` is chosen, or -1 for a time it doesn't offer.
    public int KeepEndedIndex
    {
        get => CopilotSettings.KeepEndedChoices.ToList().IndexOf(item: settings.KeepEndedMinutes);
        set
        {
            if (value >= 0 && value < CopilotSettings.KeepEndedChoices.Count)
            {
                settings.KeepEndedMinutes = CopilotSettings.KeepEndedChoices[value];
            }
        }
    }

    public bool MoveViewedToIdle
    {
        get => settings.MoveViewedToIdle;
        set => settings.MoveViewedToIdle = value;
    }

    public bool ShowRelayedQuestionsOnce
    {
        get => settings.ShowRelayedQuestionsOnce;
        set => settings.ShowRelayedQuestionsOnce = value;
    }

    public bool NestSessions
    {
        get => settings.NestSessions;
        set => settings.NestSessions = value;
    }

    public bool ShowContextUsage
    {
        get => settings.ShowContextUsage;
        set => settings.ShowContextUsage = value;
    }
}
