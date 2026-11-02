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

    /// A change it can't save, here because a file is where its folder goes, says so and stays in memory, until a later
    /// write or a flush saves it, with everything else.
    [Fact]
    public void SaysWhenItCantSaveAndSavesLater()
    {
        using var folder = new TemporaryFolder();
        var blocker = folder.Combine("BriefBar");
        File.WriteAllText(path: blocker, contents: "Not a folder.");
        var path = Path.Combine(path1: blocker, path2: "Settings.json");
        var settings = new JsonFileSettings(path: path);

        Assert.False(condition: settings.Write(key: "sources", value: new JsonObject { ["off"] = true }));
        Assert.True(condition: settings.Read(key: "sources")!["off"]!.GetValue<bool>());
        Assert.False(condition: settings.Flush());
        // Removing a key that isn't there saves nothing, and what's unsaved still is.
        Assert.False(condition: settings.Write(key: "absent", value: null));

        File.Delete(path: blocker);
        Assert.True(condition: settings.Flush());
        Assert.True(condition: new JsonFileSettings(path: path).Read(key: "sources")!["off"]!.GetValue<bool>());
        Assert.True(condition: settings.Flush());
        Assert.True(condition: settings.Write(key: "absent", value: null));
    }

    /// A file that can't be read holds nothing: so every source is off. That includes a key it has twice, and a key .NET
    /// can't make a string of, as half of an emoji written as an escape, found as the file is loaded.
    [Fact]
    public void StartsEmptyFromAFileItCantRead()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("Settings.json");
        var consents = "\"sources\":{\"consents\":{\"copilot\":{\"version\":1,\"date\":\"2026-10-18T10:00:00.000Z\"}}}";
        foreach (var contents in new[]
        {
            "not json", "[1, 2]", "", "\"sources\"", "{\"\\ud83d\":1," + consents + "}", "{\"a\":1,\"a\":2," + consents + "}",
            "{\"sources\":{\"consents\":{\"copilot\":{\"version\":1,\"version\":2,\"date\":\"2026-10-18T10:00:00.000Z\"}}}}",
        })
        {
            File.WriteAllText(path: path, contents: contents);
            var settings = new JsonFileSettings(path: path);
            Assert.Null(@object: settings.Read(key: SourceChoices.SettingsKey));
            Assert.Empty(collection: SourceChoices.Load(settings: settings).Consents);
        }
    }

    /// A setting holding text .NET can't make a string of, as half of an emoji written as an escape, is left out as the
    /// file is loaded. The others are kept, and saving still works, which would otherwise fail on that text every time.
    [Fact]
    public void KeepsTheSettingsItCanRead()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("Settings.json");
        File.WriteAllText(
            path: path,
            contents: "{\"sources\":{\"consents\":{\"copilot\":{\"version\":1,\"date\":\"2026-10-18T10:00:00.000Z\"}}},"
                + "\"copilot.clearedSessions\":{\"\\ud83d\":1},\"copilot.viewedSessions\":{\"a\":\"\\ud83d\"},\"twice\":{\"a\":1,\"a\":2},"
                + "\"copilot.nestSessions\":true}");

        var settings = new JsonFileSettings(path: path);

        Assert.Null(@object: settings.Read(key: "copilot.clearedSessions"));
        Assert.Null(@object: settings.Read(key: "copilot.viewedSessions"));
        Assert.Null(@object: settings.Read(key: "twice"));
        Assert.True(condition: settings.Bool(key: "copilot.nestSessions"));
        Assert.Equal(expected: SourceState.On, actual: SourceChoices.Load(settings: settings).State(source: SourceId.Copilot, version: 1));
        Assert.True(condition: settings.SetBool(key: "copilot.showContextUsage", value: true));
        var reloaded = new JsonFileSettings(path: path);
        Assert.True(condition: reloaded.Bool(key: "copilot.showContextUsage") && reloaded.Bool(key: "copilot.nestSessions"));
        Assert.Null(@object: reloaded.Read(key: "copilot.clearedSessions"));
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
        Assert.Equal(expected: 1_792_317_600m, actual: settings.Read(key: "copilot.clearedSessions")!["a"]!.GetValue<decimal>());
        Assert.Equal(expected: dates, actual: settings.Dates(key: "copilot.clearedSessions"));
        settings.Write(key: "copilot.clearedSessions", value: JsonNode.Parse(json: "{\"a\":\"yesterday\",\"b\":1e300}"));
        Assert.Empty(collection: settings.Dates(key: "copilot.clearedSessions"));
        // A name it can't make a string of, as half of an emoji: what can't be read is forgotten, and nothing ends.
        settings.Write(key: "copilot.clearedSessions", value: JsonNode.Parse(json: "{\"\\ud83d\":1,\"a\":1}"));
        Assert.Empty(collection: settings.Dates(key: "copilot.clearedSessions"));
    }

    /// A time reads back to the tick, after a restart too: a seen time equal to a comment's must stay equal, or the comment
    /// would be new again. A double of seconds since 1970 can't hold every tick of today's dates.
    [Fact]
    public void KeepsEveryTickOfADate()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("Settings.json");
        var random = new Random(Seed: 2026);
        var dates = new Dictionary<string, DateTimeOffset>(comparer: StringComparer.Ordinal)
        {
            // Saved as a double, this one read back two ticks early.
            ["known"] = new DateTimeOffset(year: 2026, month: 7, day: 12, hour: 23, minute: 5, second: 20, offset: TimeSpan.Zero).AddTicks(ticks: 8_140_000),
        };
        for (var index = 0; index < 200; index++)
        {
            dates["random " + index.ToString(provider: System.Globalization.CultureInfo.InvariantCulture)] =
                TestTimes.T(seconds: 0).AddTicks(ticks: random.NextInt64(minValue: -TimeSpan.TicksPerDay * 365, maxValue: TimeSpan.TicksPerDay * 365));
        }
        new JsonFileSettings(path: path).SetDates(key: "copilot.clearedSessions", dates: dates);
        Assert.Equal(expected: dates, actual: new JsonFileSettings(path: path).Dates(key: "copilot.clearedSessions"));
        Assert.Equal(expected: dates["known"], actual: SettingsValues.DateFrom(node: SettingsValues.DateNode(date: dates["known"])));
    }
}
