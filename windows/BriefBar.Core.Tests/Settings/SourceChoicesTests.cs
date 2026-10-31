using System.Text.Json.Nodes;
using BriefBar.Core.Settings;
using static BriefBar.Core.Tests.Copilot.TestTimes;

namespace BriefBar.Core.Tests.Settings;

public sealed class SourceChoicesTests
{
    [Fact]
    public void NothingIsOnAtFirst()
    {
        var choices = SourceChoices.Load(settings: new MemorySettings());
        Assert.All(collection: Enum.GetValues<SourceId>(), action: source => Assert.Equal(expected: SourceState.Off, actual: choices.State(source: source, version: 1)));
    }

    /// GitHub, like every source, stays off until you turn it on, whatever else is on.
    [Fact]
    public void GitHubIsOffUntilTurnedOn()
    {
        var choices = SourceChoices.Load(settings: new MemorySettings());
        foreach (var source in Enum.GetValues<SourceId>().Where(predicate: source => source != SourceId.GitHub))
        {
            choices.TurnOn(source: source, version: 1, date: T(seconds: 0));
        }
        Assert.Equal(expected: SourceState.Off, actual: choices.State(source: SourceId.GitHub, version: 1));
        choices.TurnOn(source: SourceId.GitHub, version: 1, date: T(seconds: 60));
        Assert.Equal(expected: SourceState.On, actual: choices.State(source: SourceId.GitHub, version: 1));
        choices.TurnOff(source: SourceId.GitHub);
        Assert.Equal(expected: SourceState.Off, actual: choices.State(source: SourceId.GitHub, version: 1));
        Assert.Equal(expected: SourceState.On, actual: choices.State(source: SourceId.Copilot, version: 1));
    }

    [Fact]
    public void ASourceIsOnOnlyAfterItsTurnedOn()
    {
        var choices = new SourceChoices();
        choices.TurnOn(source: SourceId.Copilot, version: 1, date: T(seconds: 0));
        Assert.Equal(expected: SourceState.On, actual: choices.State(source: SourceId.Copilot, version: 1));
        Assert.Equal(expected: SourceState.Off, actual: choices.State(source: SourceId.Teams, version: 1));
        Assert.Equal(expected: SourceState.Off, actual: choices.State(source: SourceId.AzureDevOps, version: 1));
        choices.TurnOff(source: SourceId.Copilot);
        Assert.Equal(expected: SourceState.Off, actual: choices.State(source: SourceId.Copilot, version: 1));
    }

    [Fact]
    public void ASourceThatReadsMoreWaitsUntilYouveSeenIt()
    {
        var choices = new SourceChoices();
        choices.TurnOn(source: SourceId.Teams, version: 1, date: T(seconds: 0));
        Assert.Equal(expected: SourceState.NeedsReview, actual: choices.State(source: SourceId.Teams, version: 2));
        choices.TurnOn(source: SourceId.Teams, version: 2, date: T(seconds: 60));
        Assert.Equal(expected: SourceState.On, actual: choices.State(source: SourceId.Teams, version: 2));
        // An older version of the description, after a downgrade, is covered by the newer consent.
        Assert.Equal(expected: SourceState.On, actual: choices.State(source: SourceId.Teams, version: 1));
    }

    [Fact]
    public void RoundTripsThroughTheSettings()
    {
        var settings = new MemorySettings();
        var choices = new SourceChoices();
        choices.TurnOn(source: SourceId.AzureDevOps, version: 3, date: T(seconds: 0.25));
        choices.Save(settings: settings);
        Assert.Equal(expected: choices.Consents, actual: SourceChoices.Load(settings: settings).Consents);
    }

    [Fact]
    public void SomethingUnreadableTurnsNothingOn()
    {
        var settings = new MemorySettings();
        foreach (var unreadable in new JsonNode?[]
        {
            JsonNode.Parse(json: "{\"consents\":{\"teams\":{\"version\":\"one\",\"date\":\"2026-10-18T10:00:00.000Z\"}}}"),
            JsonNode.Parse(json: "{\"consents\":{\"teams\":{\"version\":1,\"date\":\"yesterday\"}}}"),
            JsonNode.Parse(json: "{\"consents\":[\"teams\"]}"),
            JsonValue.Create(value: "teams"),
            JsonValue.Create(value: true),
        })
        {
            settings.Write(key: SourceChoices.SettingsKey, value: unreadable);
            Assert.Empty(collection: SourceChoices.Load(settings: settings).Consents);
        }
    }

    [Fact]
    public void KeepsButIgnoresSourcesThisVersionDoesntKnow()
    {
        var settings = new MemorySettings();
        var date = Iso(date: T(seconds: 0));
        settings.Write(
            key: SourceChoices.SettingsKey,
            value: JsonNode.Parse(json: "{\"consents\":{\"outlook\":{\"version\":1,\"date\":\"" + date + "\"},\"copilot\":{\"version\":1,\"date\":\"" + date + "\"}}}"));

        var choices = SourceChoices.Load(settings: settings);
        Assert.Equal(expected: [SourceId.Copilot], actual: Enum.GetValues<SourceId>().Where(predicate: source => choices.State(source: source, version: 1) == SourceState.On));
        choices.TurnOff(source: SourceId.Copilot);
        choices.Save(settings: settings);
        Assert.Equal(expected: ["outlook"], actual: SourceChoices.Load(settings: settings).Consents.Keys);
    }
}
