namespace BriefBar.Core.Tests;

/// Ported from `sectionsKnowTheirSource` in Tests/BriefBarCoreTests/SourceChoicesTests.swift, with the names the two
/// apps share.
public sealed class SectionIdTests
{
    [Fact]
    public void SectionsKnowTheirSource()
    {
        Assert.Equal(expected: SourceId.Teams, actual: SectionId.TeamsChats.Source);
        Assert.Equal(expected: SourceId.Teams, actual: SectionId.TeamsGroupChats.Source);
        Assert.Equal(expected: SourceId.AzureDevOps, actual: SectionId.AzureDevOpsPullRequests.Source);
        Assert.Equal(expected: SourceId.Copilot, actual: SectionId.CopilotSessions.Source);
        Assert.Equal(expected: SourceId.GitHub, actual: SectionId.GitHubPullRequests.Source);
        Assert.Null(@object: new SectionId(RawValue: "outlook.mail").Source);
        Assert.Null(@object: new SectionId(RawValue: string.Empty).Source);
        Assert.Null(@object: default(SectionId).Source);
    }

    [Fact]
    public void SourcesHaveTheMacsNames()
    {
        Assert.Equal(
            expected: ["teams", "azureDevOps", "copilot", "github"],
            actual: Enum.GetValues<SourceId>().Select(selector: source => SourceIds.RawValue(source: source)));
        foreach (var source in Enum.GetValues<SourceId>())
        {
            Assert.True(condition: SourceIds.TryParse(rawValue: SourceIds.RawValue(source: source), source: out var parsed));
            Assert.Equal(expected: source, actual: parsed);
        }
        Assert.False(condition: SourceIds.TryParse(rawValue: "Teams", source: out _));
        Assert.False(condition: SourceIds.TryParse(rawValue: "outlook", source: out _));
    }

    [Fact]
    public void EverySectionInTheBarHasStatesAndANameForEachPlace()
    {
        Assert.Equal(
            expected: ["teams.chats", "teams.groupChats", "azureDevOps.pullRequests", "copilot.sessions", "github.pullRequests"],
            actual: Sections.InBarOrder.Select(selector: section => section.Id.RawValue));
        foreach (var section in Sections.InBarOrder)
        {
            Assert.NotEmpty(collection: section.States);
            Assert.Equal(expected: section.States.Count, actual: section.States.Distinct().Count());
            Assert.False(condition: string.IsNullOrWhiteSpace(value: section.Title));
            Assert.False(condition: string.IsNullOrWhiteSpace(value: section.BarLabel));
            Assert.StartsWith(
                expectedStartString: section.SourceName.Replace(oldValue: "Microsoft ", newValue: string.Empty, comparisonType: StringComparison.Ordinal),
                actualString: section.FullName,
                comparisonType: StringComparison.Ordinal);
        }
    }

    [Fact]
    public void CountsInWords()
    {
        var noun = new CountNoun(One: "chat", Many: "chats");
        Assert.Equal(expected: "1 chat", actual: noun.Format(count: 1));
        Assert.Equal(expected: "3 chats", actual: noun.Format(count: 3));
        Assert.Equal(expected: "0 chats", actual: noun.Format(count: 0));
    }
}
