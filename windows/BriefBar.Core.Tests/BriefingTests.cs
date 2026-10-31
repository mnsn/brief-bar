namespace BriefBar.Core.Tests;

/// Ported from `Briefing.pick`'s tests in Tests/BriefBarUITests/BriefTests.swift.
public sealed class BriefingTests
{
    static BriefLine Line(SourceId source, string id, ItemState state, double? minutesAgo) => new(
        Id: id,
        Section: SectionOf(source: source),
        State: state,
        Date: minutesAgo is { } minutes ? Times.At(seconds: 100_000 - (minutes * 60)) : null,
        Sentence: id + ".");

    static SectionId SectionOf(SourceId source) => source switch
    {
        SourceId.Teams => SectionId.TeamsGroupChats,
        SourceId.AzureDevOps => SectionId.AzureDevOpsPullRequests,
        SourceId.Copilot => SectionId.CopilotSessions,
        _ => SectionId.GitHubPullRequests,
    };

    static IEnumerable<string> Ids(IReadOnlyList<BriefLine> lines) => lines.Select(selector: line => line.Id);

    [Fact]
    public void CoversEverySourceWithSomethingToSayThenWhatsMostPressing()
    {
        // Copilot has the newest of everything, but each source gets its most pressing line first.
        var picked = Briefing.Pick(lines:
        [
            Line(source: SourceId.Copilot, id: "release", state: ItemState.NeedsYou, minutesAgo: 1),
            Line(source: SourceId.Copilot, id: "plan", state: ItemState.NeedsYou, minutesAgo: 2),
            Line(source: SourceId.Copilot, id: "question", state: ItemState.NeedsYou, minutesAgo: 4),
            Line(source: SourceId.Teams, id: "launch-crew", state: ItemState.NeedsYou, minutesAgo: 5),
            Line(source: SourceId.AzureDevOps, id: "checkout", state: ItemState.NeedsYou, minutesAgo: 8),
            Line(source: SourceId.Copilot, id: "node", state: ItemState.Failing, minutesAgo: 10),
            Line(source: SourceId.AzureDevOps, id: "coupon", state: ItemState.Done, minutesAgo: 30),
            Line(source: SourceId.Copilot, id: "readme", state: ItemState.Done, minutesAgo: 20),
            Line(source: SourceId.Copilot, id: "tests", state: ItemState.Running, minutesAgo: 0),
        ]);
        // One of each source, then the newest wrong and done, in the order they show: by state, the newest first.
        Assert.Equal(expected: ["release", "launch-crew", "checkout", "node", "readme"], actual: Ids(lines: picked));
    }

    [Fact]
    public void FillsWithWhatsMostPressingAndLeavesOutWhatsRunning()
    {
        var picked = Briefing.Pick(
            lines:
            [
                Line(source: SourceId.AzureDevOps, id: "a", state: ItemState.NeedsYou, minutesAgo: 3),
                Line(source: SourceId.AzureDevOps, id: "b", state: ItemState.NeedsYou, minutesAgo: 1),
                Line(source: SourceId.AzureDevOps, id: "c", state: ItemState.NeedsYou, minutesAgo: null),
                Line(source: SourceId.AzureDevOps, id: "d", state: ItemState.NeedsYou, minutesAgo: 2),
                Line(source: SourceId.AzureDevOps, id: "ready", state: ItemState.Done, minutesAgo: 0),
                Line(source: SourceId.Copilot, id: "running", state: ItemState.Running, minutesAgo: 0),
            ],
            limit: 4);
        Assert.Equal(expected: ["b", "d", "a", "ready"], actual: Ids(lines: picked));
        Assert.Empty(collection: Briefing.Pick(lines: [Line(source: SourceId.Copilot, id: "running", state: ItemState.Running, minutesAgo: 0)]));
        Assert.Empty(collection: Briefing.Pick(lines: []));
    }

    [Fact]
    public void PutsDatedLinesBeforeUndatedOnesAndKeepsTheOrderGivenOtherwise()
    {
        var picked = Briefing.Pick(lines:
        [
            Line(source: SourceId.Copilot, id: "first", state: ItemState.NeedsYou, minutesAgo: null),
            Line(source: SourceId.Copilot, id: "second", state: ItemState.NeedsYou, minutesAgo: null),
            Line(source: SourceId.Copilot, id: "dated", state: ItemState.NeedsYou, minutesAgo: 90),
        ]);
        Assert.Equal(expected: ["dated", "first", "second"], actual: Ids(lines: picked));
    }
}
