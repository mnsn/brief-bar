using BriefBar.Core.Presentation;
using BriefBar.Core.Settings;

namespace BriefBar.Core.Tests.Presentation;

public sealed class AppearanceSettingsTests
{
    [Fact]
    public void StartsAutomaticWithNoColorOfYourOwn()
    {
        var storage = new MemorySettings();
        var settings = new AppearanceSettings(settings: storage);
        Assert.Equal(expected: BarBackground.Automatic, actual: settings.BarBackground);
        Assert.Null(@object: settings.BarColor);
        Assert.Null(@object: storage.Read(key: AppearanceSettings.BarBackgroundKey));
    }

    [Fact]
    public void KeepsWhatYouChoseAndSaysSoOnce()
    {
        var storage = new MemorySettings();
        var settings = new AppearanceSettings(settings: storage);
        var changes = 0;
        settings.Changed += (_, _) => changes++;

        settings.BarBackground = BarBackground.CustomColor;
        settings.BarBackground = BarBackground.CustomColor;
        settings.BarColor = 0x80123456u;
        settings.BarColor = 0x80123456u;
        // Nothing that isn't a choice, and no color that isn't one.
        settings.BarBackground = (BarBackground)7;
        settings.BarColor = null;

        Assert.Equal(expected: 2, actual: changes);
        Assert.Equal(expected: "color", actual: storage.Text(key: AppearanceSettings.BarBackgroundKey));
        Assert.Equal(expected: "#80123456", actual: storage.Text(key: AppearanceSettings.BarColorKey));
        var again = new AppearanceSettings(settings: storage);
        Assert.Equal(expected: BarBackground.CustomColor, actual: again.BarBackground);
        Assert.Equal(expected: 0x80123456u, actual: again.BarColor);
        again.BarBackground = BarBackground.LikeTheTaskbar;
        Assert.Equal(expected: "taskbar", actual: storage.Text(key: AppearanceSettings.BarBackgroundKey));
    }

    [Theory]
    [InlineData("sideways", "#FF123456", BarBackground.Automatic, 0xFF123456u)]
    [InlineData("taskbar", "red", BarBackground.LikeTheTaskbar, null)]
    [InlineData("color", "#GG123456", BarBackground.CustomColor, null)]
    [InlineData("color", "#123456", BarBackground.CustomColor, null)]
    public void ReadsWhatItCanOfWhatWasSaved(string background, string color, BarBackground expectedBackground, uint? expectedColor)
    {
        var storage = new MemorySettings();
        storage.SetText(key: AppearanceSettings.BarBackgroundKey, value: background);
        storage.SetText(key: AppearanceSettings.BarColorKey, value: color);
        var settings = new AppearanceSettings(settings: storage);
        Assert.Equal(expected: expectedBackground, actual: settings.BarBackground);
        Assert.Equal(expected: expectedColor, actual: settings.BarColor);
    }
}
