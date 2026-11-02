using BriefBar.Core.Demo;
using BriefBar.Core.Presentation;
using BriefBar.Core.Settings;
using BriefBar.Core.Teams;
using BriefBar.Core.Tests.ChromiumIndexedDB;

namespace BriefBar.Core.Tests.Teams;

/// What the Teams sections show: the demo's made-up chats as the Mac's panel lists them, with or without previews; what
/// each says when nothing is unread, or when Teams' data can't be read; and their brief. The Mac's `TeamsSource`, its
/// rows' views and `SummaryPromptTests`' brief sentences.
public sealed class TeamsRowsTests
{
    static readonly DateTimeOffset now = Times.At(seconds: 0);

    [Fact]
    public void ListsTheUnreadChatsThenTheRecentOnes()
    {
        var chats = DemoData.TeamsChats(now: now);

        Assert.Equal(expected: SectionStatus.Live, actual: chats.Status);
        Assert.Equal(expected: [TeamsRows.UnreadGroup, TeamsRows.RecentGroup], actual: chats.Groups.Select(selector: group => group.Key));
        Assert.True(condition: chats.Groups[1].IsFolded);
        var markAll = Assert.Single(collection: chats.Groups[0].Commands);
        Assert.Equal(expected: (TeamsCommands.MarkAllRead, "Mark all read", "Mark every chat here as read"), actual: (markAll.Key, markAll.Title, markAll.Help));
        Assert.Equal(expected: [TeamsDemoData.Avery, TeamsDemoData.Sam, TeamsDemoData.Noah], actual: chats.Rows.Select(selector: row => row.Id));
        Assert.Equal(expected: new StateCounts(NeedsYou: 2), actual: chats.Counts);
        Assert.Null(@object: chats.Quiet);
        Assert.Equal(expected: TeamsCommands.OpenApp, actual: Assert.Single(collection: chats.Commands).Key);

        var avery = chats.Rows[0];
        Assert.Equal(expected: (TeamsRows.UnreadGroup, ItemState.NeedsYou, IconKey.Person, "AQ"), actual: (avery.Group, avery.State, avery.Icon, avery.Initials));
        Assert.Equal(expected: ("Avery Quinn", "I moved the deck to the shared folder.", StatusTone.Quote, 2), actual: (avery.Title, avery.Status, avery.StatusTone, avery.Unread));
        Assert.Equal(expected: now.AddMinutes(minutes: -12), actual: avery.Date);
        Assert.Equal(expected: [TeamsCommands.Open, TeamsCommands.MarkRead], actual: avery.Commands.Select(selector: command => command.Key));
        Assert.True(condition: avery.Commands[0].Opens);
        Assert.Equal(
            expected: "Avery Quinn\nAre we still on for the 3 pm review?\nI moved the deck to the shared folder.\nClick to open in Microsoft Teams",
            actual: avery.ToolTip);

        var noah = chats.Rows[2];
        Assert.Equal(expected: (TeamsRows.RecentGroup, (ItemState?)null, 0), actual: (noah.Group, noah.State, noah.Unread));
        Assert.Equal(expected: "Thanks, that worked!", actual: noah.Status);
        Assert.Equal(expected: now.AddMinutes(minutes: -300), actual: noah.Date);
        Assert.Equal(expected: [TeamsCommands.Open], actual: noah.Commands.Select(selector: command => command.Key));
    }

    /// In a group chat, each message says who wrote it; its row has no initials, as its picture is the group's.
    [Fact]
    public void SaysWhoWroteInAGroupChat()
    {
        var groups = DemoData.TeamsGroupChats(now: now);

        Assert.Equal(expected: [TeamsDemoData.LaunchCrew, TeamsDemoData.WeeklySync, TeamsDemoData.DesignReviews], actual: groups.Rows.Select(selector: row => row.Id));
        var crew = groups.Rows[0];
        Assert.Equal(expected: (IconKey.People, (string?)null, 3), actual: (crew.Icon, crew.Initials, crew.Unread));
        Assert.Equal(expected: "Jordan Lee: Shipping at 5 unless someone objects.", actual: crew.Status);
        Assert.Equal(expected: "Priya Patel: Notes and action items are in the chat.", actual: groups.Rows[1].Status);
        Assert.Equal(expected: "Maya Chen: New mocks are up for Thursday.", actual: groups.Rows[2].Status);
        Assert.Equal(expected: "Mark every group chat here as read", actual: groups.Groups[0].Commands[0].Help);
    }

    [Fact]
    public void BriefsWhoWroteAndOnlyWithPreviewsWhat()
    {
        Assert.Equal(
            expected:
            [
                "Avery Quinn sent you 2 messages: “I moved the deck to the shared folder.”",
                "Sam Rivera sent you a message: “Can you look at my pull request when you get a chance?”",
            ],
            actual: DemoData.TeamsChats(now: now).BriefLines.Select(selector: line => line.Sentence));
        Assert.Equal(
            expected:
            [
                "Launch crew & Design: 3 new messages, the newest from Jordan Lee: “Shipping at 5 unless someone objects.”",
                "Weekly sync: a new message from Priya Patel: “Notes and action items are in the chat.”",
            ],
            actual: DemoData.TeamsGroupChats(now: now).BriefLines.Select(selector: line => line.Sentence));

        var (store, settings) = Demo();
        settings.ShowMessagePreviews = false;
        var chats = TeamsRows.Snapshot(store: store, settings: settings, group: ChatGroup.Chats);
        var groups = TeamsRows.Snapshot(store: store, settings: settings, group: ChatGroup.Groups);

        Assert.Equal(expected: ["Avery Quinn sent you 2 messages.", "Sam Rivera sent you a message."], actual: chats.BriefLines.Select(selector: line => line.Sentence));
        Assert.Equal(
            expected: ["Launch crew & Design: 3 new messages, the newest from Jordan Lee.", "Weekly sync: a new message from Priya Patel."],
            actual: groups.BriefLines.Select(selector: line => line.Sentence));
        Assert.Equal(expected: ["2 new messages", "1 new message", "No new messages"], actual: chats.Rows.Select(selector: row => row.Status));
        Assert.Equal(expected: "Avery Quinn\n2 new messages\nClick to open in Microsoft Teams", actual: chats.Rows[0].ToolTip);
        Assert.All(collection: chats.Rows.Concat(second: groups.Rows), action: row => Assert.DoesNotContain(expectedSubstring: "deck", actualString: row.ToolTip, comparisonType: StringComparison.Ordinal));
    }

    [Fact]
    public void ClipsLongMessagesInTheBrief()
    {
        var long_ = string.Concat(values: Enumerable.Repeat(element: "word ", count: 60)).Trim();
        var message = new TeamsMessage(ConversationId: Fixture.Crew, Id: 1, Sender: null, IsFromMe: false, Type: "Text", Text: long_, ArrivedAt: now);
        var conversation = new ConversationSummary(Id: Fixture.Crew, Kind: ConversationKind.Group, Title: "Launch crew", FullTitle: null, Unread: [message], Latest: message, LastActivity: now);

        var sentence = ChatBrief.Sentence(conversation: conversation, showsText: true);

        Assert.StartsWith(expectedStartString: "Launch crew: a new message: “word word", actualString: sentence, comparisonType: StringComparison.Ordinal);
        Assert.EndsWith(expectedEndString: "…”", actualString: sentence, comparisonType: StringComparison.Ordinal);
        Assert.True(condition: sentence.Length < 160);
        Assert.Equal(expected: "Launch crew: a new message.", actual: ChatBrief.Sentence(conversation: conversation, showsText: false));
    }

    [Fact]
    public void SaysWhenNothingIsUnread()
    {
        var (store, settings) = Demo();
        store.MarkAllRead(group: ChatGroup.Chats, now: now);
        store.MarkAllRead(group: ChatGroup.Groups, now: now);

        var chats = TeamsRows.Snapshot(store: store, settings: settings, group: ChatGroup.Chats);

        Assert.Equal(expected: new QuietNote(Title: "No unread chats", Detail: "3 recent chats"), actual: chats.Quiet);
        Assert.Empty(collection: chats.BriefLines);
        Assert.Equal(expected: new StateCounts(), actual: chats.Counts);
        Assert.All(collection: chats.Rows, action: row => Assert.Equal(expected: TeamsRows.RecentGroup, actual: row.Group));

        var empty = new TeamsStore(settings: settings, marks: TeamsReadMarks.InMemory());
        empty.Receive(snapshot: new TeamsSnapshot { Found = true, Report = new TeamsDataReport { Folders = 1, Stores = 1 } }, now: now);
        Assert.Equal(expected: new QuietNote(Title: "No unread group chats", Detail: "Nothing new in the last day"), actual: TeamsRows.Snapshot(store: empty, settings: settings, group: ChatGroup.Groups).Quiet);
    }

    /// What keeps BriefBar from reading Teams: the section says so, rather than that nothing is unread; while chats it
    /// read before are still there, they're shown as they were.
    [Fact]
    public void ExplainsWhatKeepsItFromReadingTeams()
    {
        var settings = new TeamsSettings(settings: new MemorySettings());
        var store = new TeamsStore(settings: settings, marks: TeamsReadMarks.InMemory());
        Assert.Equal(expected: SectionCondition.Starting, actual: TeamsRows.Snapshot(store: store, settings: settings, group: ChatGroup.Chats).Status.Condition);

        store.Receive(snapshot: new TeamsSnapshot(), now: now);
        var missing = TeamsRows.Snapshot(store: store, settings: settings, group: ChatGroup.Chats);
        Assert.Equal(expected: (SectionCondition.Problem, "No Teams"), actual: (missing.Status.Condition, missing.Status.ShortProblem));
        Assert.Null(@object: missing.Quiet);

        store.Receive(snapshot: new TeamsSnapshot { Found = true, Report = new TeamsDataReport { Folders = 1 } }, now: now);
        var changed = TeamsRows.Snapshot(store: store, settings: settings, group: ChatGroup.Groups);
        Assert.Equal(expected: (SectionCondition.Problem, "Can't read"), actual: (changed.Status.Condition, changed.Status.ShortProblem));
        Assert.Contains(expectedSubstring: "update to Teams", actualString: changed.Status.Problem, comparisonType: StringComparison.Ordinal);

        var demo = TeamsDemoData.Snapshot(now: now);
        store.Receive(snapshot: demo with { Failed = true }, now: now);
        var failed = TeamsRows.Snapshot(store: store, settings: settings, group: ChatGroup.Chats);
        Assert.Equal(expected: SectionCondition.Stale, actual: failed.Status.Condition);
        Assert.NotEmpty(collection: failed.Rows);

        store.Receive(snapshot: demo with { Report = demo.Report with { UnreadableFiles = 1 } }, now: now);
        var partly = TeamsRows.Snapshot(store: store, settings: settings, group: ChatGroup.Chats);
        Assert.Equal(expected: SectionStatus.Live, actual: partly.Status);
        Assert.Contains(expectedSubstring: "some chats may be missing", actualString: Assert.Single(collection: partly.Notices).Message, comparisonType: StringComparison.Ordinal);
    }

    [Fact]
    public void NamesPeopleByTheirInitials()
    {
        Assert.Equal(expected: "AQ", actual: TeamsRows.Initials(name: "Avery Quinn"));
        Assert.Equal(expected: "RS", actual: TeamsRows.Initials(name: "Rivera, Sam"));
        Assert.Equal(expected: "PS", actual: TeamsRows.Initials(name: "Priya (Contractor) Shah"));
        Assert.Equal(expected: "N", actual: TeamsRows.Initials(name: "noah"));
        Assert.Equal(expected: "?", actual: TeamsRows.Initials(name: "  1234 "));
    }

    /// The demo's made-up chats in a store of their own, with Teams' settings as they start.
    static (TeamsStore Store, TeamsSettings Settings) Demo()
    {
        var settings = new TeamsSettings(settings: new MemorySettings());
        var store = new TeamsStore(settings: settings, marks: TeamsReadMarks.InMemory());
        store.Receive(snapshot: TeamsDemoData.Snapshot(now: now), now: now);
        return (store, settings);
    }
}
