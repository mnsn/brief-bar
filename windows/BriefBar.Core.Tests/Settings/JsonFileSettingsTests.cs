using System.Text.Json.Nodes;
using BriefBar.Core.Settings;
using BriefBar.Core.Tests.Copilot;

namespace BriefBar.Core.Tests.Settings;

public sealed class JsonFileSettingsTests
{
    [Fact]
    public void KeepsWhatsSavedAcrossLaunches()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("BriefBar", "Settings.json");
        var settings = new JsonFileSettings(path: path);
        Assert.Null(@object: settings.Read(key: "copilot.nestSessions"));
        Assert.False(condition: File.Exists(path: path));

        settings.SetBool(key: "copilot.nestSessions", value: true);
        settings.SetNumber(key: "copilot.keepEndedMinutes", value: 240);
        var reopened = new JsonFileSettings(path: path);
        Assert.True(condition: reopened.Bool(key: "copilot.nestSessions"));
        Assert.Equal(expected: 240, actual: reopened.Number(key: "copilot.keepEndedMinutes"));

        reopened.Write(key: "copilot.nestSessions", value: null);
        Assert.Null(@object: new JsonFileSettings(path: path).Read(key: "copilot.nestSessions"));
        // Written whole, with nothing left over from writing it.
        Assert.Equal(expected: ["Settings.json"], actual: Directory.GetFiles(path: folder.Combine("BriefBar")).Select(selector: Path.GetFileName));
    }

    /// A file that can't be read holds nothing: so every source is off.
    [Fact]
    public void StartsEmptyFromAFileItCantRead()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("Settings.json");
        foreach (var contents in new[] { "not json", "[1, 2]", "", "\"sources\"" })
        {
            File.WriteAllText(path: path, contents: contents);
            var settings = new JsonFileSettings(path: path);
            Assert.Null(@object: settings.Read(key: SourceChoices.SettingsKey));
            Assert.Empty(collection: SourceChoices.Load(settings: settings).Consents);
        }
    }

    /// What it hands out is a copy: changing it changes nothing saved.
    [Fact]
    public void HandsOutCopies()
    {
        using var folder = new TemporaryFolder();
        foreach (ISettingsStorage settings in new ISettingsStorage[] { new JsonFileSettings(path: folder.Combine("Settings.json")), new MemorySettings() })
        {
            settings.Write(key: "dates", value: new JsonObject { ["a"] = 1 });
            var copy = (JsonObject)settings.Read(key: "dates")!;
            copy["b"] = 2;
            Assert.Equal(expected: ["a"], actual: ((JsonObject)settings.Read(key: "dates")!).Select(selector: pair => pair.Key));
        }
    }

    [Fact]
    public void KeepsDatesAsTheMacDoes()
    {
        var settings = new MemorySettings();
        var dates = new Dictionary<string, DateTimeOffset> { ["b"] = TestTimes.T(seconds: 0.5), ["a"] = TestTimes.T(seconds: 0) };
        settings.SetDates(key: "copilot.clearedSessions", dates: dates);
        Assert.Equal(expected: 1_792_317_600.0, actual: settings.Read(key: "copilot.clearedSessions")!["a"]!.GetValue<double>());
        Assert.Equal(expected: dates, actual: settings.Dates(key: "copilot.clearedSessions"));
        settings.Write(key: "copilot.clearedSessions", value: JsonNode.Parse(json: "{\"a\":\"yesterday\",\"b\":1e300}"));
        Assert.Empty(collection: settings.Dates(key: "copilot.clearedSessions"));
    }
}
