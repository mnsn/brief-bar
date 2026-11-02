using BriefBar.Core.ChromiumIndexedDB;
using BriefBar.Core.Teams;
using BriefBar.Core.Tests.ChromiumIndexedDB;

namespace BriefBar.Core.Tests.Teams;

/// Teams' own records, made up and read as Chromium wrote them: a conversation from `conversations`, and the messages of a
/// reply chain from `replychains-2`.
public sealed class TeamsRecordsTests
{
    [Fact]
    public void ReadsAOneOnOneChat()
    {
        var newest = new MadeUpMessage(Id: TeamsData.Id(seconds: 30), Sender: "Avery Quinn", Html: "<p>Are we still on for <b>3</b>?</p>");
        var record = new MadeUpChat(
            Id: Fixture.Avery, Type: "Chat", ReadUpTo: TeamsData.Id(seconds: 10), Newest: newest, Topic: "Not a 1:1 chat's name", ShortTitle: "Avery Quinn", LongTitle: "Avery Quinn");

        var chat = Chat(chat: record);

        Assert.Equal(
            expected: new TeamsChat(
                Id: Fixture.Avery,
                Kind: ConversationKind.OneOnOne,
                Title: "Avery Quinn",
                FullTitle: null,
                Marker: new ReadMarker(MessageId: TeamsData.Id(seconds: 10), ReadAt: DateTimeOffset.FromUnixTimeMilliseconds(milliseconds: TeamsData.Id(seconds: 10) + 900)),
                Newest: new TeamsMessage(
                    ConversationId: Fixture.Avery,
                    Id: TeamsData.Id(seconds: 30),
                    Sender: "Avery Quinn",
                    IsFromMe: false,
                    Type: "RichText/Html",
                    Text: "Are we still on for 3?",
                    ArrivedAt: TeamsData.At(seconds: 30)),
                IsMuted: false),
            actual: chat);
    }

    /// A group chat by its topic, else its members, with all their names when Teams has a longer list; a meeting's chat by
    /// its meeting; a 1:1 chat without a name by whoever wrote to you.
    [Fact]
    public void NamesEachChatAsTeamsDoes()
    {
        var jordan = new MadeUpMessage(Id: TeamsData.Id(seconds: 5), Sender: "Jordan Lee", Html: "Shipping at 5");
        var crew = Chat(chat: new MadeUpChat(
            Id: Fixture.Crew, Type: "Chat", ReadUpTo: 0, Newest: jordan, Topic: "Launch crew", ShortTitle: "Jordan, Maya, Sam", LongTitle: "Jordan Lee, Maya Chen, Sam Rivera"));
        Assert.Equal(expected: ConversationKind.Group, actual: crew?.Kind);
        Assert.Equal(expected: "Launch crew", actual: crew?.Title);
        Assert.Equal(expected: "Jordan Lee, Maya Chen, Sam Rivera", actual: crew?.FullTitle);
        Assert.Null(@object: crew?.Marker);

        var untitled = Chat(chat: new MadeUpChat(Id: Fixture.Crew, Type: "Chat", ReadUpTo: 0, Newest: null, ShortTitle: "Jordan, Maya, Sam", LongTitle: "Jordan, Maya, Sam"));
        Assert.Equal(expected: "Jordan, Maya, Sam", actual: untitled?.Title);
        Assert.Null(@object: untitled?.FullTitle);
        Assert.Null(@object: untitled?.Newest);
        Assert.Equal(expected: "Group chat", actual: Chat(chat: new MadeUpChat(Id: Fixture.Crew, Type: "Chat", ReadUpTo: 0, Newest: null))?.Title);

        var meeting = Chat(chat: new MadeUpChat(Id: Fixture.Sync, Type: "Meeting", ReadUpTo: 0, Newest: null, Topic: "Weekly sync"));
        Assert.Equal(expected: ConversationKind.Meeting, actual: meeting?.Kind);
        Assert.Equal(expected: "Weekly sync", actual: meeting?.Title);
        Assert.Equal(expected: "Meeting chat", actual: Chat(chat: new MadeUpChat(Id: Fixture.Sync, Type: "Meeting", ReadUpTo: 0, Newest: null))?.Title);

        var avery = new MadeUpMessage(Id: TeamsData.Id(seconds: 5), Sender: "Avery Quinn", Html: "Lunch?");
        Assert.Equal(expected: "Avery Quinn", actual: Chat(chat: new MadeUpChat(Id: Fixture.Avery, Type: "Chat", ReadUpTo: 0, Newest: avery))?.Title);
        var mine = avery with { Sender = "Made-up Me", FromMe = true };
        Assert.Equal(expected: "Chat", actual: Chat(chat: new MadeUpChat(Id: Fixture.Avery, Type: "Chat", ReadUpTo: 0, Newest: mine))?.Title);
    }

    /// Teams' Mark as unread leaves the read marker alone and sets a bookmark, in the marker's form, to a message before
    /// the newest; opening the chat sets it back to 0.
    [Fact]
    public void ReadsWhetherAChatIsMarkedUnread()
    {
        var newest = new MadeUpMessage(Id: TeamsData.Id(seconds: 30), Sender: "Jordan Lee", Html: "Shipping at 5");
        MadeUpChat Crew(string? bookmark) => new(Id: Fixture.Crew, Type: "Chat", ReadUpTo: newest.Id, Newest: newest, Topic: "Launch crew", Bookmark: bookmark);

        var marked = Chat(chat: Crew(bookmark: TeamsData.Bookmark(after: newest.Id - 1, markedAtSeconds: 60)));
        Assert.Equal(expected: new ReadMarker(MessageId: newest.Id - 1, ReadAt: TeamsData.At(seconds: 60)), actual: marked?.MarkedUnread);
        Assert.Equal(expected: newest.Id, actual: marked?.Marker?.MessageId);

        Assert.Null(@object: Chat(chat: Crew(bookmark: "0;" + TeamsData.Digits(value: TeamsData.Id(seconds: 90)) + ";0"))?.MarkedUnread);
        Assert.Null(@object: Chat(chat: Crew(bookmark: string.Empty))?.MarkedUnread);
        Assert.Null(@object: Chat(chat: Crew(bookmark: null))?.MarkedUnread);
    }

    [Fact]
    public void ReadsWhetherAChatIsMuted()
    {
        MadeUpChat Crew(string? alerts) => new(Id: Fixture.Crew, Type: "Chat", ReadUpTo: 0, Newest: null, Alerts: alerts);
        Assert.True(condition: Chat(chat: Crew(alerts: "false"))?.IsMuted);
        Assert.False(condition: Chat(chat: Crew(alerts: "true"))?.IsMuted);
        Assert.False(condition: Chat(chat: Crew(alerts: null))?.IsMuted);

        Assert.False(condition: TeamsRecords.Flag(value: JSValue.FromBool(value: false)));
        Assert.True(condition: TeamsRecords.Flag(value: JSValue.FromString(text: "True")));
        Assert.False(condition: TeamsRecords.Flag(value: JSValue.FromString(text: "FALSE")));
        Assert.Null(@object: TeamsRecords.Flag(value: JSValue.FromString(text: "yes")));
        Assert.Null(@object: TeamsRecords.Flag(value: JSValue.FromNumber(value: 0)));
        Assert.Null(@object: TeamsRecords.Flag(value: null));
    }

    /// Teams says whether a chat's newest message is yours; without that, who sent it tells.
    [Fact]
    public void TellsYourMessagesApart()
    {
        var mine = new MadeUpMessage(Id: TeamsData.Id(seconds: 5), Sender: "Made-up Me", Html: "On it", FromMe: true);
        Assert.True(condition: Chat(chat: new MadeUpChat(Id: Fixture.Crew, Type: "Chat", ReadUpTo: 0, Newest: mine))?.Newest?.IsFromMe);

        var unsaid = Decoded(body: writer => writer.Members(properties:
        [
            ("id", value => value.Text(text: Fixture.Crew)),
            ("type", value => value.Text(text: "Chat")),
            ("lastMessage", mine.WriteAsLast),
        ]));
        Assert.True(condition: TeamsRecords.Chat(value: unsaid, recordKey: null, userId: Fixture.Me)?.Newest?.IsFromMe);
        Assert.False(condition: TeamsRecords.Chat(value: unsaid, recordKey: null, userId: "cccccccc-3333-4ccc-8ccc-cccccccccccc")?.Newest?.IsFromMe);
    }

    [Fact]
    public void SkipsWhatIsntAChat()
    {
        Assert.Null(@object: Chat(chat: new MadeUpChat(Id: Fixture.Channel, Type: "Topic", ReadUpTo: 0, Newest: null)));
        var notes = Decoded(body: writer => writer.Members(properties: [("id", value => value.Text(text: "48:notes")), ("type", value => value.Text(text: "StreamOfNotes"))]));
        Assert.Null(@object: TeamsRecords.Chat(value: notes, recordKey: "48:notes", userId: Fixture.Me));

        // A record without its ID takes its key's.
        var unnamed = Decoded(body: writer => writer.Members(properties: [("type", value => value.Text(text: "Chat"))]));
        Assert.Equal(expected: Fixture.Avery, actual: TeamsRecords.Chat(value: unnamed, recordKey: Fixture.Avery, userId: Fixture.Me)?.Id);
        Assert.Null(@object: TeamsRecords.Chat(value: unnamed, recordKey: null, userId: Fixture.Me));
        // A newest message without an ID that's a time isn't one.
        var undated = Decoded(body: writer => writer.Members(properties:
        [
            ("id", value => value.Text(text: Fixture.Crew)),
            ("type", value => value.Text(text: "Chat")),
            ("lastMessage", value => value.Members(properties: [("id", id => id.Text(text: "draft")), ("content", content => content.Text(text: "Made-up"))])),
        ]));
        Assert.Null(@object: TeamsRecords.Chat(value: undated, recordKey: null, userId: Fixture.Me)?.Newest);
    }

    /// A reply chain's messages, except those deleted: who sent each and whether it was you, its type and text, and when
    /// it arrived.
    [Fact]
    public void ReadsAReplyChainsMessages()
    {
        var chain = new MadeUpReplyChain(ConversationId: Fixture.Crew, Messages:
        [
            new MadeUpMessage(Id: TeamsData.Id(seconds: 10), Sender: "Jordan Lee", Html: "<p>Staging is green</p>"),
            new MadeUpMessage(Id: TeamsData.Id(seconds: 20), Sender: "Made-up Me", Html: "<p>Great</p>", FromMe: true),
            new MadeUpMessage(Id: TeamsData.Id(seconds: 30), Sender: "Jordan Lee", Html: "<p>Oops</p>", Deleted: true),
            new MadeUpMessage(Id: TeamsData.Id(seconds: 40), Sender: "Jordan Lee", Html: string.Empty, Type: "Event/Call"),
        ]);

        var messages = TeamsRecords.Messages(value: Decoded(body: chain.Write), userId: Fixture.Me).OrderBy(keySelector: message => message.Id).ToList();

        Assert.Equal(expected: [TeamsData.Id(seconds: 10), TeamsData.Id(seconds: 20), TeamsData.Id(seconds: 40)], actual: messages.Select(selector: message => message.Id));
        Assert.Equal(
            expected: new TeamsMessage(
                ConversationId: Fixture.Crew,
                Id: TeamsData.Id(seconds: 10),
                Sender: "Jordan Lee",
                IsFromMe: false,
                Type: "RichText/Html",
                Text: "Staging is green",
                ArrivedAt: TeamsData.At(seconds: 10)),
            actual: messages[0]);
        Assert.True(condition: messages[1].IsFromMe);
        Assert.False(condition: messages[2].IsContent);
        Assert.Empty(collection: TeamsRecords.Messages(value: Decoded(body: writer => writer.Members(properties: [("conversationId", value => value.Text(text: Fixture.Crew))])), userId: Fixture.Me));
    }

    static TeamsChat? Chat(MadeUpChat chat) => TeamsRecords.Chat(value: Decoded(body: chat.Write), recordKey: chat.Id, userId: Fixture.Me);

    static JSValue Decoded(Action<V8Writer> body) => SerializedValue.Decode(bytes: V8Writer.Serialized(body: body)).Value!;
}
