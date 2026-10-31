using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

public sealed class RowWordsTests
{
    static readonly DateTimeOffset now = Times.At(seconds: 0);

    [Fact]
    public void SaysWhatTheRowShowsWithCommas()
    {
        var row = Snapshots.Row(id: "ask", section: SectionId.CopilotSessions, group: "needsYou", state: ItemState.NeedsYou, minutesAgo: 3) with
        {
            Title = "Made-up release",
            Status = "Needs permission · made-up-repo",
            Detail = "made-up command",
        };

        Assert.Equal(
            expected: "Made-up release, Needs permission, made-up-repo, made-up command, 3 minutes ago",
            actual: RowWords.SpokenName(row: row, sourceName: null, now: now));
    }

    [Fact]
    public void PutsTheSourceFirstWhenItHasOne()
    {
        var row = Snapshots.Row(id: "ask", section: SectionId.CopilotSessions, group: "needsYou", state: ItemState.NeedsYou, minutesAgo: 0);

        Assert.Equal(
            expected: "GitHub Copilot sessions: Made-up ask, Made-up status, just now",
            actual: RowWords.SpokenName(row: row, sourceName: "GitHub Copilot sessions", now: now));
    }

    [Fact]
    public void DoesNotDoubleASentencesEnd()
    {
        var row = Snapshots.Row(id: "done", section: SectionId.CopilotSessions, group: "done", state: ItemState.Done, minutesAgo: 9) with
        {
            Detail = "Its made-up checks pass.",
        };
        var question = row with { Detail = "Can it go ahead?", Date = null };

        Assert.Equal(
            expected: "Made-up done, Made-up status, Its made-up checks pass. 9 minutes ago",
            actual: RowWords.SpokenName(row: row, sourceName: null, now: now));
        Assert.Equal(
            expected: "Made-up done, Made-up status, Can it go ahead?",
            actual: RowWords.SpokenName(row: question, sourceName: null, now: now));
    }

    [Fact]
    public void LeavesOutEmptyPartsAndTrailingCommas()
    {
        var row = Snapshots.Row(id: "chat", section: SectionId.TeamsChats, group: "unread", state: ItemState.NeedsYou) with
        {
            Status = " · made-up-place",
            Detail = "Made-up preview,",
            Date = null,
        };

        Assert.Equal(
            expected: "Made-up chat, made-up-place, Made-up preview",
            actual: RowWords.SpokenName(row: row, sourceName: null, now: now));
    }

    [Fact]
    public void SaysLinksUnreadMessagesAndWhetherItsNew()
    {
        var row = Snapshots.Row(id: "pr", section: SectionId.AzureDevOpsPullRequests, group: "needsYou", state: ItemState.NeedsYou, minutesAgo: 60) with
        {
            Chips = [new RowChip(Kind: RowChipKind.WorkItem, Text: "#42"), new RowChip(Kind: RowChipKind.PullRequest, Text: "!7")],
            Unread = 2,
            IsNew = true,
        };
        var one = row with { Chips = [], Unread = 1, IsNew = false };

        Assert.Equal(
            expected: "Made-up pr, Made-up status, work item #42, pull request !7, 2 unread messages, new, 1 hour ago",
            actual: RowWords.SpokenName(row: row, sourceName: null, now: now));
        Assert.Equal(
            expected: "Made-up pr, Made-up status, 1 unread message, 1 hour ago",
            actual: RowWords.SpokenName(row: one, sourceName: null, now: now));
    }
}
