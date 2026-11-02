using System.Text;
using System.Text.Json;
using BriefBar.Core.Teams;
using BriefBar.Core.Tests.ChromiumIndexedDB;
using BriefBar.Core.Tests.Copilot;

namespace BriefBar.Core.Tests.Teams;

/// The chats you mark read in BriefBar: kept by ID only, sealed for your Windows account, until Teams' own marker passes
/// them; deleted when you turn Teams off. The Mac's `UnreadTests` of its sealed file, where Windows keeps less.
public sealed class TeamsReadMarksTests
{
    [Fact]
    public void SealsWhatItSaves()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("Teams", "read");
        var marks = new TeamsReadMarks(path: path, protector: new FakeProtector());
        marks.Load();
        Assert.False(condition: File.Exists(path: path));

        marks.Mark(chat: Fixture.Avery, messageId: TeamsData.Id(seconds: 30));

        var saved = File.ReadAllBytes(path: path);
        Assert.True(condition: saved.AsSpan().StartsWith(value: FakeProtector.Header));
        Assert.DoesNotContain(expectedSubstring: "aaaa", actualString: Encoding.UTF8.GetString(bytes: saved), comparisonType: StringComparison.Ordinal);
        Assert.False(condition: File.Exists(path: path + ".tmp"));
        var reopened = new TeamsReadMarks(path: path, protector: new FakeProtector());
        reopened.Load();
        Assert.Equal(expected: new Dictionary<string, long> { [Fixture.Avery] = TeamsData.Id(seconds: 30) }, actual: reopened.Marks);
    }

    [Fact]
    public void KeepsTheFurthestMarkOfEachChat()
    {
        var marks = TeamsReadMarks.InMemory();
        marks.Mark(chat: Fixture.Avery, messageId: TeamsData.Id(seconds: 30));
        marks.Mark(chat: Fixture.Avery, messageId: TeamsData.Id(seconds: 20));
        marks.Mark(chat: Fixture.Sam, messageId: TeamsData.Id(seconds: 10));

        Assert.Equal(expected: new Dictionary<string, long> { [Fixture.Avery] = TeamsData.Id(seconds: 30), [Fixture.Sam] = TeamsData.Id(seconds: 10) }, actual: marks.Marks);
    }

    /// Teams' marker passing a mark, or its chat leaving Teams' data, ends it; with none left, the file and its folder go.
    [Fact]
    public void DeletesTheFileWhenNothingIsLeft()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("Teams", "read");
        var marks = new TeamsReadMarks(path: path, protector: new FakeProtector());
        marks.Mark(chat: Fixture.Avery, messageId: TeamsData.Id(seconds: 30));
        marks.Mark(chat: Fixture.Sam, messageId: TeamsData.Id(seconds: 10));

        marks.Prune(chats: [Chat(id: Fixture.Avery, readUpTo: TeamsData.Id(seconds: 20)), Chat(id: Fixture.Sam, readUpTo: TeamsData.Id(seconds: 10))], dropAbsent: true);
        Assert.Equal(expected: [Fixture.Avery], actual: marks.Marks.Keys);
        Assert.True(condition: File.Exists(path: path));

        marks.Prune(chats: [], dropAbsent: true);
        Assert.Empty(collection: marks.Marks);
        Assert.False(condition: File.Exists(path: path));
        Assert.False(condition: Directory.Exists(path: folder.Combine("Teams")));
    }

    /// A read that missed something may only have missed the chat: its mark stays, while Teams' marker ends the others'.
    [Fact]
    public void KeepsTheMarksOfChatsAReadMayHaveMissed()
    {
        var marks = TeamsReadMarks.InMemory();
        marks.Mark(chat: Fixture.Avery, messageId: TeamsData.Id(seconds: 30));
        marks.Mark(chat: Fixture.Sam, messageId: TeamsData.Id(seconds: 10));

        marks.Prune(chats: [Chat(id: Fixture.Sam, readUpTo: TeamsData.Id(seconds: 10))], dropAbsent: false);

        Assert.Equal(expected: [Fixture.Avery], actual: marks.Marks.Keys);
    }

    /// A file it can't open, sealed for someone else or damaged, is useless, so it goes.
    [Fact]
    public void DiscardsWhatItCannotOpen()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("Teams", "read");
        new TeamsReadMarks(path: path, protector: new FakeProtector()).Mark(chat: Fixture.Avery, messageId: TeamsData.Id(seconds: 30));

        var other = new TeamsReadMarks(path: path, protector: new FakeProtector(key: 0x33));
        other.Load();
        Assert.Empty(collection: other.Marks);
        Assert.False(condition: File.Exists(path: path));

        Directory.CreateDirectory(path: folder.Combine("Teams"));
        File.WriteAllBytes(path: path, bytes: new FakeProtector().Protect(data: "not JSON"u8.ToArray()));
        var damaged = new TeamsReadMarks(path: path, protector: new FakeProtector());
        damaged.Load();
        Assert.Empty(collection: damaged.Marks);
        Assert.False(condition: File.Exists(path: path));
    }

    [Fact]
    public void KeepsOnlyChatsMarks()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("read");
        var protector = new FakeProtector();
        var saved = new Dictionary<string, long> { ["not a chat"] = 5, [Fixture.Avery] = -1, [Fixture.Sam] = TeamsData.Id(seconds: 10) };
        File.WriteAllBytes(path: path, bytes: protector.Protect(data: JsonSerializer.SerializeToUtf8Bytes(value: saved)));

        var marks = new TeamsReadMarks(path: path, protector: protector);
        marks.Load();

        Assert.Equal(expected: new Dictionary<string, long> { [Fixture.Sam] = TeamsData.Id(seconds: 10) }, actual: marks.Marks);
    }

    /// Turning Teams off deletes the file, and its folder once it's empty; nothing is saved from then on.
    [Fact]
    public void DeletesEverythingWhenTurnedOff()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("Teams", "read");
        var marks = new TeamsReadMarks(path: path, protector: new FakeProtector());
        marks.Mark(chat: Fixture.Avery, messageId: TeamsData.Id(seconds: 30));

        marks.Delete();

        Assert.Empty(collection: marks.Marks);
        Assert.False(condition: Directory.Exists(path: folder.Combine("Teams")));
        marks.Mark(chat: Fixture.Sam, messageId: TeamsData.Id(seconds: 10));
        Assert.Empty(collection: marks.Marks);
        Assert.False(condition: File.Exists(path: path));

        // Nothing saved yet, in a folder that isn't there: nothing to delete.
        new TeamsReadMarks(path: folder.Combine("Elsewhere", "read"), protector: new FakeProtector()).Delete();
        Assert.False(condition: Directory.Exists(path: folder.Combine("Elsewhere")));
    }

    [Fact]
    public void KeepsTheDemosMarksInMemory()
    {
        var marks = TeamsReadMarks.InMemory();
        marks.Load();
        marks.Mark(chat: Fixture.Avery, messageId: TeamsData.Id(seconds: 30));
        Assert.Single(collection: marks.Marks);

        marks.Prune(chats: [Chat(id: Fixture.Avery, readUpTo: TeamsData.Id(seconds: 30))], dropAbsent: false);
        Assert.Empty(collection: marks.Marks);
    }

    static TeamsChat Chat(string id, long readUpTo) =>
        new(Id: id, Kind: ConversationKind.OneOnOne, Title: "Made-up", FullTitle: null, Marker: new ReadMarker(MessageId: readUpTo), Newest: null, IsMuted: false);
}
