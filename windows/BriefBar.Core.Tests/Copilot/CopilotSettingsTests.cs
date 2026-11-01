using BriefBar.Core.Copilot;
using BriefBar.Core.Settings;
using static BriefBar.Core.Tests.TestTimes;

namespace BriefBar.Core.Tests.Copilot;

public sealed class CopilotSettingsTests
{
    [Fact]
    public void NamesEachChoiceOfHowLongToKeepFinishedSessions()
    {
        Assert.Equal(
            expected: ["15 minutes", "1 hour", "4 hours", "1 day"],
            actual: CopilotSettings.KeepEndedChoices.Select(selector: CopilotSettings.KeepEndedTitle));
        Assert.Equal(expected: ["1 minute", "90 minutes", "2 days"], actual: new List<int> { 1, 90, 2_880 }.Select(selector: CopilotSettings.KeepEndedTitle));
    }

    /// Under the Mac's keys, so the two apps' settings read alike.
    [Fact]
    public void KeepsItsSettingsAndStartsWithTheMacsDefaults()
    {
        var storage = new MemorySettings();
        var settings = new CopilotSettings(settings: storage, now: T(seconds: 0));
        Assert.Equal(expected: 60, actual: settings.KeepEndedMinutes);
        Assert.False(condition: settings.ShowContextUsage || settings.MoveViewedToIdle || settings.ShowRelayedQuestionsOnce || settings.NestSessions);
        var changes = 0;
        settings.Changed += (_, _) => changes++;

        settings.KeepEndedMinutes = 240;
        settings.ShowContextUsage = true;
        settings.ShowContextUsage = true;
        settings.NestSessions = true;

        Assert.Equal(expected: 3, actual: changes);
        var again = new CopilotSettings(settings: storage, now: T(seconds: 0));
        Assert.Equal(expected: 240, actual: again.KeepEndedMinutes);
        Assert.True(condition: again.ShowContextUsage && again.NestSessions);
        Assert.Equal(expected: 240, actual: storage.Read(key: CopilotSettings.KeepEndedMinutesKey)!.GetValue<int>());
    }

    /// Turning Copilot off forgets the sessions you cleared or viewed, and keeps how you set it up.
    [Fact]
    public void ForgetsWhatYouClearedOrViewedButNotItsSettings()
    {
        var storage = new MemorySettings();
        var settings = new CopilotSettings(settings: storage, now: T(seconds: 0));
        settings.ShowContextUsage = true;
        settings.Clear(ids: ["a"], date: T(seconds: 0));
        settings.MarkViewed(ids: ["b"], date: T(seconds: 0));

        settings.ForgetDismissed();

        Assert.Empty(collection: settings.Cleared);
        Assert.Empty(collection: settings.Viewed);
        Assert.Null(@object: storage.Read(key: CopilotSettings.ClearedKey));
        Assert.Null(@object: storage.Read(key: CopilotSettings.ViewedKey));
        Assert.True(condition: new CopilotSettings(settings: storage, now: T(seconds: 0)).ShowContextUsage);
    }

    /// A dismissal older than a week isn't kept in memory, but it's still saved until turning Copilot off deletes it.
    [Fact]
    public void ForgetsDismissalsTooOldToBeInMemory()
    {
        var storage = new MemorySettings();
        storage.SetDates(key: CopilotSettings.ClearedKey, dates: new Dictionary<string, DateTimeOffset> { ["made-up-session"] = T(seconds: -10 * 86_400) });
        storage.SetDates(key: CopilotSettings.ViewedKey, dates: new Dictionary<string, DateTimeOffset> { ["made-up-other"] = T(seconds: -9 * 86_400) });
        var settings = new CopilotSettings(settings: storage, now: T(seconds: 0));
        Assert.Empty(collection: settings.Cleared);
        var changes = 0;
        settings.Changed += (_, _) => changes++;

        settings.ForgetDismissed();

        Assert.Null(@object: storage.Read(key: CopilotSettings.ClearedKey));
        Assert.Null(@object: storage.Read(key: CopilotSettings.ViewedKey));
        // Nothing it showed changed.
        Assert.Equal(expected: 0, actual: changes);
    }
}
