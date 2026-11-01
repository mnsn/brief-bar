using System.Globalization;
using BriefBar.Core.Settings;

namespace BriefBar.Core.GitHub;

/// GitHub's settings, in BriefBar's, with the Mac's key: how often it reads your pull requests. Safe to use from any
/// thread. The Mac's `AppSettings`, in GitHubUI.
public sealed class GitHubSettings
{
    public const string RefreshMinutesKey = "github.refreshMinutes";

    /// Read every 2 minutes, unless you choose otherwise.
    public const int DefaultRefreshMinutes = 2;

    readonly Lock gate = new();
    readonly ISettingsStorage settings;
    int refreshMinutes;

    public GitHubSettings(ISettingsStorage settings)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        this.settings = settings;
        var saved = settings.Number(key: RefreshMinutesKey);
        refreshMinutes = RefreshChoices.Contains(value: saved) ? saved : DefaultRefreshMinutes;
    }

    /// Refresh's choices, in minutes: each at least a minute.
    public static IReadOnlyList<int> RefreshChoices { get; } = [1, 2, 5, 15];

    /// How often BriefBar reads GitHub, in minutes: one request each time. A choice it doesn't offer changes nothing.
    public int RefreshMinutes
    {
        get
        {
            lock (gate)
            {
                return refreshMinutes;
            }
        }
        set
        {
            lock (gate)
            {
                if (!RefreshChoices.Contains(value: value) || value == refreshMinutes)
                {
                    return;
                }
                refreshMinutes = value;
                settings.SetNumber(key: RefreshMinutesKey, value: value);
            }
        }
    }

    public TimeSpan RefreshInterval => TimeSpan.FromMinutes(value: RefreshMinutes);

    /// "Every minute", "Every 2 minutes".
    public static string RefreshTitle(int minutes) => minutes == 1
        ? "Every minute"
        : "Every " + minutes.ToString(provider: CultureInfo.InvariantCulture) + " minutes";
}
