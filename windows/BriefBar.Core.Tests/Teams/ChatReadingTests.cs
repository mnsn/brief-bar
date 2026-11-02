using BriefBar.Core.Teams;
using BriefBar.Core.Tests.ChromiumIndexedDB;

namespace BriefBar.Core.Tests.Teams;

/// Which of a chat's messages are unread, as Teams' own list decides: what others wrote after how far you read it in Teams,
/// after your own newest message, and after how far you marked it read in BriefBar, within Keep Unread For. The Mac's
/// `ReadMarkerRuleTests` and `UnreadTests`, where Windows decides the same.
public sealed class ChatReadingTests
{
    static readonly DateTimeOffset now = TeamsData.At(seconds: 1_000);

    [Fact]
    public void CountsWhatOthersWroteSinceYouReadTheChatInTeams()
    {
        TeamsMessage[] messages = [Message(seconds: 10, text: "Lunch?"), Message(seconds: 20, text: "Noon works"), Message(seconds: 30, text: "See you there")];

        Assert.Equal(expected: ["See you there"], actual: Texts(chat: Chat(newest: messages[^1], readUpTo: TeamsData.Id(seconds: 20)), messages: messages));
        Assert.Empty(collection: Texts(chat: Chat(newest: messages[^1], readUpTo: TeamsData.Id(seconds: 30)), messages: messages));
        Assert.Equal(expected: 3, actual: Texts(chat: Chat(newest: messages[^1], readUpTo: 0), messages: messages).Count);
        Assert.True(condition: ChatReading.MayBeUnread(chat: Chat(newest: messages[^1], readUpTo: TeamsData.Id(seconds: 20))));
        Assert.False(condition: ChatReading.MayBeUnread(chat: Chat(newest: messages[^1], readUpTo: TeamsData.Id(seconds: 30))));
        Assert.False(condition: ChatReading.MayBeUnread(chat: Chat(newest: null, readUpTo: 0)));
    }

    /// Writing in a chat reads it, as Teams moves its marker to what you sent: only what others wrote after that counts.
    [Fact]
    public void ReadsEverythingBeforeYourOwnMessage()
    {
        TeamsMessage[] answered = [Message(seconds: 10, text: "Lunch?"), Message(seconds: 20, text: "Sure", fromMe: true)];
        Assert.False(condition: ChatReading.MayBeUnread(chat: Chat(newest: answered[^1], readUpTo: 0)));
        Assert.Empty(collection: Texts(chat: Chat(newest: answered[^1], readUpTo: 0), messages: answered));

        TeamsMessage[] again = [.. answered, Message(seconds: 30, text: "Great, noon then")];
        Assert.Equal(expected: ["Great, noon then"], actual: Texts(chat: Chat(newest: again[^1], readUpTo: 0), messages: again));
    }

    /// A call, a meeting's recording or someone joining isn't something to read, though Teams lists it.
    [Fact]
    public void CountsOnlyWhatSomeoneWrote()
    {
        TeamsMessage[] messages =
        [
            Message(seconds: 10, text: string.Empty, type: "Event/Call"),
            Message(seconds: 20, text: "Notes are in the chat"),
            Message(seconds: 30, text: string.Empty, type: "RichText/Media_CallRecording"),
            Message(seconds: 40, text: string.Empty, type: "ThreadActivity/AddMember"),
        ];
        Assert.Equal(expected: ["Notes are in the chat"], actual: Texts(chat: Chat(newest: messages[^1], readUpTo: 0, kind: ConversationKind.Meeting), messages: messages));
        Assert.Empty(collection: Texts(chat: Chat(newest: messages[^1], readUpTo: TeamsData.Id(seconds: 20), kind: ConversationKind.Meeting), messages: messages));
    }

    /// Teams doesn't notify you of a muted chat, so it never needs you.
    [Fact]
    public void LeavesMutedChatsRead()
    {
        var newest = Message(seconds: 10, text: "Muted chatter");
        Assert.False(condition: ChatReading.MayBeUnread(chat: Chat(newest: newest, readUpTo: 0, muted: true)));
        Assert.Empty(collection: Texts(chat: Chat(newest: newest, readUpTo: 0, muted: true), messages: [newest]));
    }

    [Fact]
    public void ReadsAChatAsFarAsYouMarkedItReadInBriefBar()
    {
        TeamsMessage[] messages = [Message(seconds: 10, text: "Lunch?"), Message(seconds: 20, text: "Noon works"), Message(seconds: 30, text: "See you there")];
        var chat = Chat(newest: messages[^1], readUpTo: TeamsData.Id(seconds: 10));

        Assert.Equal(expected: ["See you there"], actual: Texts(chat: chat, messages: messages, markedUpTo: TeamsData.Id(seconds: 20)));
        Assert.Empty(collection: Texts(chat: chat, messages: messages, markedUpTo: TeamsData.Id(seconds: 30)));
        // A mark behind Teams' own marker changes nothing.
        Assert.Equal(expected: ["Noon works", "See you there"], actual: Texts(chat: chat, messages: messages, markedUpTo: TeamsData.Id(seconds: 5)));
    }

    [Fact]
    public void LetsOldUnreadMessagesExpire()
    {
        TeamsMessage[] messages = [Message(seconds: 1_000 - 7_200, text: "Two hours ago"), Message(seconds: 1_000 - 1_800, text: "Half an hour ago")];
        var chat = Chat(newest: messages[^1], readUpTo: 0);

        Assert.Equal(expected: ["Half an hour ago"], actual: Texts(chat: chat, messages: messages, keepUnreadFor: TimeSpan.FromHours(value: 1)));
        Assert.Equal(expected: ["Two hours ago", "Half an hour ago"], actual: Texts(chat: chat, messages: messages, keepUnreadFor: null));
        Assert.Empty(collection: Texts(chat: chat, messages: messages, keepUnreadFor: TimeSpan.FromMinutes(value: 10)));
    }

    /// Teams' message cache may not have a chat's newest message yet: the chat's record names it, so it counts, once.
    [Fact]
    public void CountsTheNewestMessageTheCacheDoesntHaveYet()
    {
        var newest = Message(seconds: 30, text: "See you there");
        Assert.Equal(expected: ["See you there"], actual: Texts(chat: Chat(newest: newest, readUpTo: TeamsData.Id(seconds: 20)), messages: []));
        Assert.Equal(expected: ["See you there"], actual: Texts(chat: Chat(newest: newest, readUpTo: TeamsData.Id(seconds: 20)), messages: [newest, newest with { Text = "See you there (cached)" }]));
    }

    /// Marked unread in Teams, a chat is unread, read in Teams or not: what someone else wrote after where it was marked
    /// unread counts, and without any, as when your own reply is the newest, it's unread all the same.
    [Fact]
    public void CountsAChatMarkedUnreadInTeams()
    {
        TeamsMessage[] group = [Message(seconds: 10, text: "Staging is green"), Message(seconds: 20, text: "Shipping at 5")];
        var crew = Chat(newest: group[^1], readUpTo: TeamsData.Id(seconds: 20), kind: ConversationKind.Group) with
        {
            MarkedUnread = new ReadMarker(MessageId: TeamsData.Id(seconds: 20) - 1, ReadAt: TeamsData.At(seconds: 500)),
        };
        Assert.True(condition: ChatReading.MayBeUnread(chat: crew));
        var crewUnread = Read(chat: crew, messages: group, mark: null);
        Assert.True(condition: crewUnread.IsMarkedUnread);
        Assert.Equal(expected: ["Shipping at 5"], actual: crewUnread.Messages.Select(selector: message => message.Text));

        TeamsMessage[] answered = [Message(seconds: 10, text: "Lunch?"), Message(seconds: 20, text: "Sure", fromMe: true)];
        var avery = Chat(newest: answered[^1], readUpTo: TeamsData.Id(seconds: 20)) with
        {
            MarkedUnread = new ReadMarker(MessageId: TeamsData.Id(seconds: 20) - 1, ReadAt: TeamsData.At(seconds: 500)),
        };
        Assert.True(condition: ChatReading.MayBeUnread(chat: avery));
        var averyUnread = Read(chat: avery, messages: answered, mark: null);
        Assert.True(condition: averyUnread.IsMarkedUnread);
        Assert.True(condition: averyUnread.IsUnread);
        Assert.Empty(collection: averyUnread.Messages);
    }

    /// Teams keeps a chat marked unread until it's opened, so BriefBar does too, whatever Keep Unread For says.
    [Fact]
    public void KeepsAChatMarkedUnreadWhateverKeepUnreadForSays()
    {
        TeamsMessage[] old = [Message(seconds: 1_000 - (3 * 86_400), text: "Three days ago")];
        var chat = Chat(newest: old[^1], readUpTo: old[^1].Id) with { MarkedUnread = new ReadMarker(MessageId: old[^1].Id - 1, ReadAt: TeamsData.At(seconds: 1_000 - 86_400)) };

        var unread = ChatReading.Unread(chat: chat, messages: old, mark: null, keepUnreadFor: TimeSpan.FromHours(value: 4), now: now);

        Assert.True(condition: unread.IsMarkedUnread);
        Assert.Equal(expected: ["Three days ago"], actual: unread.Messages.Select(selector: message => message.Text));
    }

    /// Marking it read in BriefBar reads a Mark as unread made before then; one made again since makes it unread again.
    [Fact]
    public void ReadsAMarkedChatWhenYouMarkItReadInBriefBar()
    {
        TeamsMessage[] messages = [Message(seconds: 10, text: "Lunch?"), Message(seconds: 20, text: "Noon works")];
        var chat = Chat(newest: messages[^1], readUpTo: messages[^1].Id) with { MarkedUnread = new ReadMarker(MessageId: messages[^1].Id - 1, ReadAt: TeamsData.At(seconds: 500)) };

        Assert.False(condition: Read(chat: chat, messages: messages, mark: new TeamsReadMark(UpTo: messages[^1].Id, At: TeamsData.At(seconds: 600))).IsUnread);
        Assert.False(condition: Read(chat: chat, messages: messages, mark: new TeamsReadMark(UpTo: messages[^1].Id, At: TeamsData.At(seconds: 500))).IsUnread);
        var markedAgain = Read(chat: chat, messages: messages, mark: new TeamsReadMark(UpTo: messages[^1].Id, At: TeamsData.At(seconds: 400)));
        Assert.True(condition: markedAgain.IsMarkedUnread);
        Assert.Equal(expected: ["Noon works"], actual: markedAgain.Messages.Select(selector: message => message.Text));
        // Without a time, Teams' Mark as unread counts as made before any mark.
        Assert.False(condition: Read(chat: chat with { MarkedUnread = new ReadMarker(MessageId: messages[^1].Id - 1) }, messages: messages, mark: new TeamsReadMark(UpTo: messages[^1].Id, At: TeamsData.At(seconds: 0))).IsUnread);
    }

    [Fact]
    public void LeavesAMutedChatReadThoughItsMarkedUnread()
    {
        var newest = Message(seconds: 10, text: "Muted chatter");
        var chat = Chat(newest: newest, readUpTo: newest.Id, muted: true) with { MarkedUnread = new ReadMarker(MessageId: newest.Id - 1, ReadAt: TeamsData.At(seconds: 500)) };

        Assert.False(condition: ChatReading.MayBeUnread(chat: chat));
        Assert.Equal(expected: ChatUnread.None, actual: Read(chat: chat, messages: [newest], mark: null));
    }

    static ChatUnread Read(TeamsChat chat, IReadOnlyList<TeamsMessage> messages, TeamsReadMark? mark) =>
        ChatReading.Unread(chat: chat, messages: messages, mark: mark, keepUnreadFor: null, now: now);

    /// A call you started, or another event of yours, doesn't read the chat as a message you write does: what others
    /// wrote before it still counts.
    [Fact]
    public void ReadsNothingForAnEventOfYours()
    {
        TeamsMessage[] messages = [Message(seconds: 20, text: "Can you call me?"), Message(seconds: 30, text: string.Empty, fromMe: true, type: "Event/Call")];
        var chat = Chat(newest: messages[^1], readUpTo: TeamsData.Id(seconds: 10));

        Assert.True(condition: ChatReading.MayBeUnread(chat: chat));
        Assert.Equal(expected: ["Can you call me?"], actual: Texts(chat: chat, messages: messages));
    }

    /// Only Teams' message cache says a message was deleted: the chat's newest message, as the chat's record names it,
    /// doesn't count once the cache has it deleted.
    [Fact]
    public void CountsNoDeletedMessage()
    {
        var newest = Message(seconds: 30, text: "Oops, wrong chat");
        var chat = Chat(newest: newest, readUpTo: TeamsData.Id(seconds: 10));

        Assert.Equal(expected: ["Oops, wrong chat"], actual: Texts(chat: chat, messages: []));
        Assert.Empty(collection: Texts(chat: chat, messages: [newest with { Text = string.Empty, IsDeleted = true }]));
    }

    static List<string> Texts(TeamsChat chat, IReadOnlyList<TeamsMessage> messages, long? markedUpTo = null, TimeSpan? keepUnreadFor = null) =>
        ChatReading.Unread(
                chat: chat,
                messages: messages,
                mark: markedUpTo is { } upTo ? new TeamsReadMark(UpTo: upTo, At: now) : null,
                keepUnreadFor: keepUnreadFor,
                now: now)
            .Messages.Select(selector: message => message.Text).ToList();

    static TeamsChat Chat(TeamsMessage? newest, long readUpTo, bool muted = false, ConversationKind kind = ConversationKind.OneOnOne) => new(
        Id: kind == ConversationKind.OneOnOne ? Fixture.Avery : Fixture.Sync,
        Kind: kind,
        Title: kind == ConversationKind.OneOnOne ? "Avery Quinn" : "Weekly sync",
        FullTitle: null,
        Marker: readUpTo > 0 ? new ReadMarker(MessageId: readUpTo) : null,
        Newest: newest,
        IsMuted: muted);

    static TeamsMessage Message(double seconds, string text, bool fromMe = false, string type = "RichText/Html") => new(
        ConversationId: Fixture.Avery,
        Id: TeamsData.Id(seconds: seconds),
        Sender: fromMe ? "Made-up Me" : "Avery Quinn",
        IsFromMe: fromMe,
        Type: type,
        Text: text,
        ArrivedAt: TeamsData.At(seconds: seconds));
}
