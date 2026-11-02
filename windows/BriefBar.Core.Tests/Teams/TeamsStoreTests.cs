using BriefBar.Core.Settings;
using BriefBar.Core.Teams;
using BriefBar.Core.Tests.ChromiumIndexedDB;

namespace BriefBar.Core.Tests.Teams;

/// Teams' chats as the sections list them: unread ones, the newest first, linking to their oldest unread message; read ones
/// under Recent for a day; and the ones you mark read in BriefBar, until Teams' own marker gets there. The Mac's
/// `UnreadTests`, where Windows lists the same.
public sealed class TeamsStoreTests
{
    static readonly DateTimeOffset now = TeamsData.At(seconds: 1_000);

    [Fact]
    public void SortsNewestFirstAndLinksToTheOldestUnreadMessage()
    {
        var crew = Messages(chat: Fixture.Crew, (10, "First"), (30, "Second"));
        var sync = Messages(chat: Fixture.Sync, (20, "Notes"));
        var store = Store(
            (Chat(id: Fixture.Crew, kind: ConversationKind.Group, title: "Launch crew", newest: crew[^1]), crew),
            (Chat(id: Fixture.Sync, kind: ConversationKind.Meeting, title: "Weekly sync", newest: sync[^1]), sync));

        var groups = store.Unread(group: ChatGroup.Groups);

        Assert.Equal(expected: ["Launch crew", "Weekly sync"], actual: groups.Select(selector: chat => chat.Title));
        Assert.Equal(expected: 2, actual: groups[0].Unread.Count);
        Assert.Equal(expected: DeepLink.Message(conversationId: Fixture.Crew, messageId: TeamsData.Id(seconds: 10)), actual: groups[0].Link);
        Assert.Equal(expected: TeamsData.At(seconds: 30), actual: groups[0].Date);
        Assert.Equal(expected: ConversationKind.Meeting, actual: groups[1].Kind);
        Assert.Empty(collection: store.Unread(group: ChatGroup.Chats));
        Assert.Same(expected: groups[1], actual: store.Find(id: Fixture.Sync));
        Assert.Null(@object: store.Find(id: Fixture.Avery));
    }

    /// Read chats with something someone wrote in the last day, the newest first, ten at most.
    [Fact]
    public void KeepsRecentChatsWithinTheDayAndLimit()
    {
        var chats = Enumerable.Range(start: 0, count: 12)
            .Select(selector: index => ChatSince(seconds: 900 - (index * 10), id: "19:" + index.ToString(provider: System.Globalization.CultureInfo.InvariantCulture) + "aaaa@unq.gbl.spaces", title: "Person " + index.ToString(provider: System.Globalization.CultureInfo.InvariantCulture)))
            .Append(element: ChatSince(seconds: 1_000 - 90_000, id: Fixture.Sam, title: "Yesterday"))
            .Append(element: ChatSince(seconds: 950, id: Fixture.Avery, title: "A call", type: "Event/Call"))
            .ToArray();

        var recent = Store(chats: chats).Recent(group: ChatGroup.Chats);

        Assert.Equal(expected: TeamsStore.RecentLimit, actual: recent.Count);
        Assert.Equal(expected: "Person 0", actual: recent[0].Title);
        Assert.Equal(expected: "Person 9", actual: recent[^1].Title);
        Assert.DoesNotContain(collection: recent, filter: chat => chat.Title is "Yesterday" or "A call");
        Assert.All(collection: recent, action: chat => Assert.False(condition: chat.IsUnread));
    }

    [Fact]
    public void ReadsAChatWhenYouMarkItRead()
    {
        var avery = Messages(chat: Fixture.Avery, (10, "Lunch?"), (20, "Noon works"));
        var marks = TeamsReadMarks.InMemory();
        var store = Store(marks: marks, (Chat(id: Fixture.Avery, kind: ConversationKind.OneOnOne, title: "Avery Quinn", newest: avery[^1]), avery));

        store.MarkRead(conversation: store.Unread(group: ChatGroup.Chats).Single(), now: now);

        Assert.Empty(collection: store.Unread(group: ChatGroup.Chats));
        Assert.Equal(expected: ["Avery Quinn"], actual: store.Recent(group: ChatGroup.Chats).Select(selector: chat => chat.Title));
        Assert.Equal(expected: new Dictionary<string, long> { [Fixture.Avery] = TeamsData.Id(seconds: 20) }, actual: marks.Marks);

        // Avery writes again: only that is unread.
        var later = Messages(chat: Fixture.Avery, (10, "Lunch?"), (20, "Noon works"), (30, "See you there"));
        store.Receive(snapshot: Snapshot((Chat(id: Fixture.Avery, kind: ConversationKind.OneOnOne, title: "Avery Quinn", newest: later[^1]), later)), now: now);
        Assert.Equal(expected: ["See you there"], actual: store.Unread(group: ChatGroup.Chats).Single().Unread.Select(selector: message => message.Text));
    }

    [Fact]
    public void MarksEveryChatOfASectionRead()
    {
        var avery = Messages(chat: Fixture.Avery, (10, "Lunch?"));
        var crew = Messages(chat: Fixture.Crew, (20, "Shipping at 5"));
        var sync = Messages(chat: Fixture.Sync, (30, "Notes"));
        var store = Store(
            (Chat(id: Fixture.Avery, kind: ConversationKind.OneOnOne, title: "Avery Quinn", newest: avery[^1]), avery),
            (Chat(id: Fixture.Crew, kind: ConversationKind.Group, title: "Launch crew", newest: crew[^1]), crew),
            (Chat(id: Fixture.Sync, kind: ConversationKind.Meeting, title: "Weekly sync", newest: sync[^1]), sync));

        store.MarkAllRead(group: ChatGroup.Groups, now: now);

        Assert.Empty(collection: store.Unread(group: ChatGroup.Groups));
        Assert.Equal(expected: ["Avery Quinn"], actual: store.Unread(group: ChatGroup.Chats).Select(selector: chat => chat.Title));
        Assert.Equal(expected: ["Weekly sync", "Launch crew"], actual: store.Recent(group: ChatGroup.Groups).Select(selector: chat => chat.Title));
    }

    /// A mark is kept only until Teams' own marker gets there, or the chat is gone from Teams' data: and only once Teams'
    /// data was read in full, which alone says which chats are gone.
    [Fact]
    public void ForgetsAMarkOnceTeamsReadsThatFar()
    {
        var avery = Messages(chat: Fixture.Avery, (10, "Lunch?"), (20, "Noon works"));
        var sam = Messages(chat: Fixture.Sam, (15, "Can you look?"));
        var marks = TeamsReadMarks.InMemory();
        var chats = new[]
        {
            (Chat(id: Fixture.Avery, kind: ConversationKind.OneOnOne, title: "Avery Quinn", newest: avery[^1]), avery),
            (Chat(id: Fixture.Sam, kind: ConversationKind.OneOnOne, title: "Sam Rivera", newest: sam[^1]), sam),
        };
        var store = Store(marks: marks, chats: chats);
        store.MarkAllRead(group: ChatGroup.Chats, now: now);
        Assert.Equal(expected: 2, actual: marks.Marks.Count);

        // Part of Teams' data couldn't be read: a chat that's missing may only be unreadable.
        var partly = Snapshot(chats[0] with { Item1 = chats[0].Item1 with { Marker = new ReadMarker(MessageId: TeamsData.Id(seconds: 20)) } }) with
        {
            Report = new TeamsDataReport { Folders = 1, Stores = 1, Conversations = 2, Chats = 1, WithMarker = 1, UnreadableFiles = 1 },
        };
        store.Receive(snapshot: partly, now: now);
        Assert.Equal(expected: 2, actual: marks.Marks.Count);

        // Avery's chat read in Teams, and Sam's gone.
        store.Receive(snapshot: Snapshot(chats[0] with { Item1 = chats[0].Item1 with { Marker = new ReadMarker(MessageId: TeamsData.Id(seconds: 20)) } }), now: now);
        Assert.Empty(collection: marks.Marks);
        Assert.Empty(collection: store.Unread(group: ChatGroup.Chats));
    }

    /// Teams doesn't notify you of a muted chat: it's neither unread nor recent.
    [Fact]
    public void ListsNoMutedChat()
    {
        var crew = Messages(chat: Fixture.Crew, (10, "Muted chatter"));
        var store = Store((Chat(id: Fixture.Crew, kind: ConversationKind.Group, title: "Launch crew", newest: crew[^1]) with { IsMuted = true }, crew));

        Assert.Empty(collection: store.Unread(group: ChatGroup.Groups));
        Assert.Empty(collection: store.Recent(group: ChatGroup.Groups));
    }

    [Fact]
    public void DecidesAgainAsKeepUnreadForChanges()
    {
        var avery = Messages(chat: Fixture.Avery, (1_000 - (5 * 3_600), "Five hours ago"));
        var settings = new TeamsSettings(settings: new MemorySettings());
        var store = new TeamsStore(settings: settings, marks: TeamsReadMarks.InMemory());
        store.Receive(snapshot: Snapshot((Chat(id: Fixture.Avery, kind: ConversationKind.OneOnOne, title: "Avery Quinn", newest: avery[^1]), avery)), now: now);
        Assert.Single(collection: store.Unread(group: ChatGroup.Chats));

        settings.KeepUnread = KeepUnread.FourHours;
        store.Recompute(now: now);
        Assert.Empty(collection: store.Unread(group: ChatGroup.Chats));
        Assert.Single(collection: store.Recent(group: ChatGroup.Chats));

        settings.KeepUnread = KeepUnread.UntilRead;
        store.Recompute(now: now.AddDays(days: 30));
        Assert.Single(collection: store.Unread(group: ChatGroup.Chats));
    }

    [Fact]
    public void HasNothingToListBeforeItsFirstRead()
    {
        var store = new TeamsStore(settings: new TeamsSettings(settings: new MemorySettings()), marks: TeamsReadMarks.InMemory());

        Assert.False(condition: store.HasLoaded);
        Assert.Null(@object: store.Problem);
        Assert.Empty(collection: store.Unread(group: ChatGroup.Chats));
        Assert.Empty(collection: store.Recent(group: ChatGroup.Groups));
    }

    static TeamsStore Store(params (TeamsChat Chat, TeamsMessage[] Messages)[] chats) => Store(marks: TeamsReadMarks.InMemory(), chats: chats);

    static TeamsStore Store(TeamsReadMarks marks, params (TeamsChat Chat, TeamsMessage[] Messages)[] chats)
    {
        var store = new TeamsStore(settings: new TeamsSettings(settings: new MemorySettings()), marks: marks);
        store.Receive(snapshot: Snapshot(chats: chats), now: now);
        return store;
    }

    /// Teams' data, read in full, with `chats` and their messages.
    static TeamsSnapshot Snapshot(params (TeamsChat Chat, TeamsMessage[] Messages)[] chats) => new()
    {
        Found = true,
        Chats = [.. chats.Select(selector: chat => chat.Chat)],
        Messages = chats.ToDictionary(keySelector: chat => chat.Chat.Id, elementSelector: chat => (IReadOnlyList<TeamsMessage>)chat.Messages, comparer: StringComparer.Ordinal),
        Report = new TeamsDataReport { Folders = 1, Stores = 1, Conversations = chats.Length, Chats = chats.Length, WithMarker = chats.Length },
    };

    /// A chat whose newest message arrived `seconds` after the tests' base time, read in Teams.
    static (TeamsChat Chat, TeamsMessage[] Messages) ChatSince(double seconds, string id, string title, string type = "RichText/Html")
    {
        var newest = new TeamsMessage(ConversationId: id, Id: TeamsData.Id(seconds: seconds), Sender: title, IsFromMe: false, Type: type, Text: "Made-up", ArrivedAt: TeamsData.At(seconds: seconds));
        return (new TeamsChat(Id: id, Kind: ConversationKind.OneOnOne, Title: title, FullTitle: null, Marker: new ReadMarker(MessageId: newest.Id), Newest: newest, IsMuted: false), [newest]);
    }

    /// A chat never read in Teams.
    static TeamsChat Chat(string id, ConversationKind kind, string title, TeamsMessage newest) =>
        new(Id: id, Kind: kind, Title: title, FullTitle: null, Marker: null, Newest: newest, IsMuted: false);

    static TeamsMessage[] Messages(string chat, params (double Seconds, string Text)[] messages) =>
    [
        .. messages.Select(selector: message => new TeamsMessage(
            ConversationId: chat,
            Id: TeamsData.Id(seconds: message.Seconds),
            Sender: "Made-up Sender",
            IsFromMe: false,
            Type: "RichText/Html",
            Text: message.Text,
            ArrivedAt: TeamsData.At(seconds: message.Seconds))),
    ];
}
