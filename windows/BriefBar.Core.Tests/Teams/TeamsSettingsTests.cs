using System.Text.Json.Nodes;
using BriefBar.Core.Settings;
using BriefBar.Core.Teams;

namespace BriefBar.Core.Tests.Teams;

/// Teams' settings, under the Mac's keys and with its values: Show Message Previews and Keep Unread For.
public sealed class TeamsSettingsTests
{
    [Fact]
    public void StartsAsTheMacDoes()
    {
        var settings = new TeamsSettings(settings: new MemorySettings());

        Assert.True(condition: settings.ShowMessagePreviews);
        Assert.Equal(expected: KeepUnread.OneDay, actual: settings.KeepUnread);
        Assert.Equal(expected: TimeSpan.FromDays(value: 1), actual: settings.KeepUnreadFor);
    }

    [Fact]
    public void SavesWhatYouChooseAsTheMacDoes()
    {
        var storage = new MemorySettings();
        var settings = new TeamsSettings(settings: storage);

        settings.ShowMessagePreviews = false;
        settings.KeepUnread = KeepUnread.ThreeDays;

        Assert.False(condition: storage.Read(key: "teams.showMessagePreviews")?.GetValue<bool>());
        Assert.Equal(expected: "threeDays", actual: storage.Read(key: "teams.keepUnread")?.GetValue<string>());
        var reopened = new TeamsSettings(settings: storage);
        Assert.False(condition: reopened.ShowMessagePreviews);
        Assert.Equal(expected: KeepUnread.ThreeDays, actual: reopened.KeepUnread);
    }

    [Fact]
    public void IgnoresWhatItDoesntKnow()
    {
        var storage = new MemorySettings();
        storage.Write(key: TeamsSettings.KeepUnreadKey, value: JsonValue.Create(value: "forever"));
        storage.Write(key: TeamsSettings.ShowPreviewsKey, value: JsonValue.Create(value: "no"));
        Assert.Equal(expected: KeepUnread.OneDay, actual: new TeamsSettings(settings: storage).KeepUnread);
        Assert.True(condition: new TeamsSettings(settings: storage).ShowMessagePreviews);

        storage.Write(key: TeamsSettings.KeepUnreadKey, value: JsonValue.Create(value: 4));
        Assert.Equal(expected: KeepUnread.OneDay, actual: new TeamsSettings(settings: storage).KeepUnread);
    }

    [Fact]
    public void SaysWhenASettingChanges()
    {
        var settings = new TeamsSettings(settings: new MemorySettings());
        var changes = 0;
        settings.Changed += (_, _) => changes++;

        settings.ShowMessagePreviews = true;
        settings.KeepUnread = KeepUnread.OneDay;
        Assert.Equal(expected: 0, actual: changes);

        settings.ShowMessagePreviews = false;
        settings.KeepUnread = KeepUnread.UntilRead;
        Assert.Equal(expected: 2, actual: changes);
        Assert.Null(@object: settings.KeepUnreadFor);
    }

    [Fact]
    public void NamesEachChoice()
    {
        Assert.Equal(
            expected: ["4 hours", "1 day", "3 days", "Until I read it"],
            actual: TeamsSettings.KeepUnreadChoices.Select(selector: TeamsSettings.KeepUnreadTitle));
        Assert.Equal(
            expected: ["fourHours", "oneDay", "threeDays", "untilRead"],
            actual: TeamsSettings.KeepUnreadChoices.Select(selector: TeamsSettings.RawValue));
        Assert.Equal(
            expected: [TimeSpan.FromHours(value: 4), TimeSpan.FromDays(value: 1), TimeSpan.FromDays(value: 3), null],
            actual: TeamsSettings.KeepUnreadChoices.Select(selector: TeamsSettings.Interval));
    }
}
