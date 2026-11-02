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

    /// As the Mac's VoiceOver value: what it's about, then how full its context is, then the session that started it.
    [Fact]
    public void SaysHowFullItIsAndWhatItsTagNames()
    {
        var row = Snapshots.Row(id: "ask", section: SectionId.CopilotSessions, group: "running", state: ItemState.Running, minutesAgo: 2) with
        {
            Detail = "Made-up detail",
            Meter = new RowMeter(Fraction: 0.5, Text: "50%", IsHigh: false, Spoken: "Context: 50% full (100K of 200K tokens)"),
            Tag = new RowTag(Text: "↳ Made-up lead", ToolTip: "Started by “Made-up lead”", Spoken: "Started by “Made-up lead”", Command: null),
        };

        Assert.Equal(
            expected: "Made-up ask, Made-up status, Made-up detail, Context: 50% full (100K of 200K tokens), Started by “Made-up lead”, 2 minutes ago",
            actual: RowWords.SpokenName(row: row, sourceName: null, now: now));
    }

    /// As the Mac's VoiceOver value: what's left before it's done after what it's about; and, in a list sorted by when each
    /// was created, how long ago that was, rather than since its state.
    [Fact]
    public void SaysWhatsLeftAndWhenItWasCreated()
    {
        var row = Snapshots.Row(id: "pr", section: SectionId.AzureDevOpsPullRequests, group: "waiting", state: null, minutesAgo: 5) with
        {
            Detail = "Made-up detail",
            Checklist = new RowChecklist(
                Items: [new RowChecklistItem(Icon: IconKey.Clock, State: null, Label: "Made-up wait", IsDone: false)],
                Summary: ["Left to complete it: Made-up wait (Made-up reviewer)", "Done: Made-up build"]),
            Created = now.AddDays(days: -3),
        };

        Assert.Equal(
            expected: "Made-up pr, Made-up status, Made-up detail, Left to complete it: Made-up wait (Made-up reviewer), Done: Made-up build, 5 minutes ago",
            actual: RowWords.SpokenName(row: row, sourceName: null, now: now));
        Assert.EndsWith(
            expectedEndString: "Done: Made-up build, created 3 days ago",
            actualString: RowWords.SpokenName(row: row, sourceName: null, now: now, showsCreated: true),
            comparisonType: StringComparison.Ordinal);
        // Without when it was created, since its state.
        Assert.EndsWith(
            expectedEndString: ", 5 minutes ago",
            actualString: RowWords.SpokenName(row: row with { Created = null }, sourceName: null, now: now, showsCreated: true),
            comparisonType: StringComparison.Ordinal);
    }
}
