using System.Security.Cryptography;
using BriefBar.Core.Teams;
using BriefBar.Core.Tests.ChromiumIndexedDB;
using BriefBar.Core.Tests.Copilot;

namespace BriefBar.Core.Tests.Teams;

/// Reading Teams' own data: each chat from Teams' conversations, as Teams writes them, and the messages of those that may be
/// unread from its message cache. The Mac's `ReadMarkerTests`, on the same fixture, with the message cache made up.
public sealed class TeamsEngineTests
{
    static readonly TimeSpan quickly = TimeSpan.FromMilliseconds(value: 50);

    [Fact]
    public void ReadsEachChatFromTeamsData()
    {
        using var folder = new TemporaryFolder();
        var (location, _) = TeamsData.Copy(folder: folder.Path);

        var snapshot = TeamsEngine.LoadOnce(location: location);

        Assert.True(condition: snapshot.Found);
        Assert.Null(@object: snapshot.Problem);
        Assert.True(condition: snapshot.IsComplete);
        var chats = snapshot.Chats.ToDictionary(keySelector: chat => chat.Id);
        // The channel was deleted, and Teams' own notes aren't a chat.
        Assert.Equal(
            expected: new HashSet<string> { Fixture.Avery, Fixture.Sam, Fixture.Crew, Fixture.Sync, Fixture.Big, Fixture.Wrapped },
            actual: chats.Keys.ToHashSet());
        Assert.Equal(expected: Marker(read: 5000), actual: chats[Fixture.Avery].Marker);
        Assert.Equal(expected: Marker(read: 7000), actual: chats[Fixture.Sam].Marker);
        Assert.Equal(expected: Marker(read: 2000), actual: chats[Fixture.Crew].Marker);
        Assert.Equal(expected: Marker(read: 100), actual: chats[Fixture.Big].Marker);
        Assert.Equal(expected: Marker(read: 300), actual: chats[Fixture.Wrapped].Marker);
        // The meeting's chat was never opened.
        Assert.Null(@object: chats[Fixture.Sync].Marker);
        Assert.Equal(expected: ConversationKind.OneOnOne, actual: chats[Fixture.Avery].Kind);
        Assert.Equal(expected: ConversationKind.Group, actual: chats[Fixture.Crew].Kind);
        Assert.Equal(expected: "Made-up chat", actual: chats[Fixture.Avery].Title);
        Assert.Equal(expected: "Made-up topic", actual: chats[Fixture.Crew].Title);
        Assert.Equal(
            expected: new TeamsMessage(
                ConversationId: Fixture.Sam,
                Id: Fixture.Base + 8000,
                Sender: null,
                IsFromMe: true,
                Type: "RichText/Html",
                Text: "Made-up text",
                ArrivedAt: DateTimeOffset.FromUnixTimeMilliseconds(milliseconds: Fixture.Base + 8000)),
            actual: chats[Fixture.Sam].Newest);
        // Every chat's newest message is yours, so none may be unread, and its messages aren't read.
        Assert.Empty(collection: snapshot.Messages);
        var report = snapshot.Report;
        Assert.Equal(expected: (1, 1, 7, 6, 5), actual: (report.Folders, report.Stores, report.Conversations, report.Chats, report.WithMarker));
        Assert.Equal(
            expected: new Dictionary<string, int>
            {
                ["Blink 21, V8 16"] = 5,
                ["Blink 21, V8 16, compressed"] = 1,
                ["Blink 21, V8 16, from a blob file"] = 1,
            },
            actual: report.Formats);
        Assert.Empty(collection: report.Unreadable);
        Assert.Equal(expected: 0, actual: report.UnreadableFiles);
    }

    [Fact]
    public void HasNothingToSayWithoutTeamsData()
    {
        using var folder = new TemporaryFolder();

        var snapshot = TeamsEngine.LoadOnce(location: new TeamsCacheLocation(Root: folder.Combine("EBWebView"), IsTeamsOwn: false));

        Assert.False(condition: snapshot.Found);
        Assert.False(condition: snapshot.IsComplete);
        Assert.Empty(collection: snapshot.Chats);
        Assert.Equal(expected: TeamsProblem.NotFound, actual: snapshot.Problem);
    }

    [Fact]
    public void SaysWhenTeamsDataCantBeUnderstood()
    {
        var report = new TeamsDataReport();
        Assert.Null(@object: report.Problem);
        report = report with { Folders = 1 };
        Assert.Equal(expected: TeamsProblem.DataChanged, actual: report.Problem);
        report = report with { Stores = 1, Conversations = 10 };
        Assert.Equal(expected: TeamsProblem.DataChanged, actual: report.Problem);
        report = report with { WithMarker = 8 };
        Assert.Null(@object: report.Problem);
        report = report with { Unreadable = new Dictionary<string, int> { ["corrupt property count"] = 1 } };
        Assert.Null(@object: report.Problem);
        report = report with { Unreadable = new Dictionary<string, int> { ["unsupported V8 tag 92"] = 4 } };
        Assert.Equal(expected: TeamsProblem.PartlyUnreadable, actual: report.Problem);
        report = report with { Unreadable = new Dictionary<string, int>(), UnreadableFiles = 1 };
        Assert.Equal(expected: TeamsProblem.PartlyUnreadable, actual: report.Problem);

        var both = report.Adding(other: report with { Unreadable = new Dictionary<string, int> { ["truncated"] = 2 } });
        Assert.Equal(expected: (2, 2, 20, 16, 2), actual: (both.Folders, both.Stores, both.Conversations, both.WithMarker, both.UnreadableFiles));
        Assert.Equal(expected: new Dictionary<string, int> { ["truncated"] = 2 }, actual: both.Unreadable);

        Assert.Equal(expected: TeamsProblem.NotFound, actual: new TeamsSnapshot().Problem);
        Assert.Equal(expected: TeamsProblem.ReadFailed, actual: new TeamsSnapshot { Found = true, Failed = true }.Problem);
    }

    /// Teams' data found but not understood, as after an update that renames its stores, says nothing of which chats are
    /// gone.
    [Fact]
    public void IsntCompleteWhenTeamsDataIsntUnderstood()
    {
        using var folder = new TemporaryFolder();
        var leveldb = Path.Combine(paths: [folder.Path, "EBWebView", "WV2Profile_tfw", "IndexedDB", TeamsData.FolderName]);
        Directory.CreateDirectory(path: leveldb);
        var log = new LogWriter();
        log.Add(batch: LogWriter.Batch(
            sequence: 1,
            (IndexedDBKeys.DatabaseName(name: Fixture.ConversationsDatabase), IndexedDBKeys.DatabaseId(id: TeamsData.ConversationsDatabase)),
            (IndexedDBKeys.ObjectStoreName(database: TeamsData.ConversationsDatabase, objectStore: TeamsData.Store), IndexedDBKeys.Name(name: "conversations-v2"))));
        File.WriteAllBytes(path: Path.Combine(path1: leveldb, path2: TeamsData.LogName), bytes: log.Bytes);

        var snapshot = TeamsEngine.LoadOnce(location: new TeamsCacheLocation(Root: folder.Combine("EBWebView"), IsTeamsOwn: false));

        Assert.True(condition: snapshot.Found);
        Assert.Empty(collection: snapshot.Chats);
        Assert.Equal(expected: TeamsProblem.DataChanged, actual: snapshot.Problem);
        Assert.False(condition: snapshot.IsComplete);
    }

    /// Of Teams' message cache, only the chats that may be unread are read: those whose newest message isn't yours, past
    /// how far you've read them, and aren't muted.
    [Fact]
    public void ReadsTheMessagesOfChatsThatMayBeUnreadOnly()
    {
        using var folder = new TemporaryFolder();
        var (location, _) = MadeUp(folder: folder);

        var snapshot = TeamsEngine.LoadOnce(location: location);

        Assert.Null(@object: snapshot.Problem);
        Assert.Equal(expected: new HashSet<string> { Fixture.Avery, Fixture.Sync }, actual: snapshot.Messages.Keys.ToHashSet());
        Assert.Equal(expected: [TeamsData.Id(seconds: 10), TeamsData.Id(seconds: 20), TeamsData.Id(seconds: 30)], actual: snapshot.Messages[Fixture.Avery].Select(selector: message => message.Id));
        Assert.Equal(expected: [TeamsData.Id(seconds: 45), TeamsData.Id(seconds: 50)], actual: snapshot.Messages[Fixture.Sync].Select(selector: message => message.Id));
        var report = snapshot.Report;
        Assert.Equal(expected: (1, 1, 5, 5, 3), actual: (report.Folders, report.Stores, report.Conversations, report.Chats, report.WithMarker));

        // Avery's two since you read it in Teams, and the meeting's message, without its call.
        var chats = snapshot.Chats.ToDictionary(keySelector: chat => chat.Id);
        var now = TeamsData.At(seconds: 100);
        Assert.Equal(
            expected: ["Noon works", "See you there"],
            actual: ChatReading.Unread(chat: chats[Fixture.Avery], messages: snapshot.Messages[Fixture.Avery], mark: null, keepUnreadFor: null, now: now).Messages.Select(selector: message => message.Text));
        Assert.Equal(
            expected: ["Notes are in the chat"],
            actual: ChatReading.Unread(chat: chats[Fixture.Sync], messages: snapshot.Messages[Fixture.Sync], mark: null, keepUnreadFor: null, now: now).Messages.Select(selector: message => message.Text));
        Assert.True(condition: chats[Fixture.Big].IsMuted);
    }

    /// Marked unread in Teams, a chat may be unread though your reply is its newest message: its messages are read, and
    /// what Mark as unread left in it with them.
    [Fact]
    public void ReadsTheMessagesOfAChatMarkedUnread()
    {
        using var folder = new TemporaryFolder();
        var lunch = Avery(seconds: 10, text: "Lunch?");
        var reply = new MadeUpMessage(Id: TeamsData.Id(seconds: 20), Sender: "Made-up Me", Html: "Sure", FromMe: true);
        var (location, _) = TeamsData.Write(
            folder: folder.Path,
            chats:
            [
                new MadeUpChat(
                    Id: Fixture.Avery, Type: "Chat", ReadUpTo: reply.Id, Newest: reply, ShortTitle: "Avery Quinn", Bookmark: TeamsData.Bookmark(after: reply.Id - 1, markedAtSeconds: 60)),
            ],
            replyChains: [Chain(chat: Fixture.Avery, lunch), Chain(chat: Fixture.Avery, reply)]);

        var snapshot = TeamsEngine.LoadOnce(location: location);

        var chat = Assert.Single(collection: snapshot.Chats);
        Assert.Equal(expected: new ReadMarker(MessageId: reply.Id - 1, ReadAt: TeamsData.At(seconds: 60)), actual: chat.MarkedUnread);
        Assert.Equal(expected: 2, actual: snapshot.Messages[Fixture.Avery].Count);
        var unread = ChatReading.Unread(chat: chat, messages: snapshot.Messages[Fixture.Avery], mark: null, keepUnreadFor: null, now: TeamsData.At(seconds: 100));
        Assert.True(condition: unread.IsMarkedUnread);
        Assert.Empty(collection: unread.Messages);
    }

    [Fact]
    public async Task ReadsMessagesAsTheyArrive()
    {
        using var folder = new TemporaryFolder();
        var (location, log) = MadeUp(folder: folder);
        var collector = new TeamsCollector();
        using var engine = new TeamsEngine(location: location, onChange: collector.Add, reloadDelay: quickly);
        engine.Start();
        await collector.Until(what: "the first read", predicate: snapshot => Messages(snapshot: snapshot, chat: Fixture.Avery) == 3);

        // Another message in a chat that may be unread, before Teams names it the chat's newest.
        TeamsData.Append(path: log, TeamsData.Batch(sequence: 100, replyChain: Chain(chat: Fixture.Avery, new MadeUpMessage(Id: TeamsData.Id(seconds: 31), Sender: "Avery Quinn", Html: "One more thing"))));
        await collector.Until(what: "Avery's new message", predicate: snapshot => Messages(snapshot: snapshot, chat: Fixture.Avery) == 4);

        // A message in a chat that was read.
        var sam = new MadeUpMessage(Id: TeamsData.Id(seconds: 70), Sender: "Sam Rivera", Html: "Can you look at my pull request?");
        TeamsData.Append(
            path: log,
            TeamsData.Batch(sequence: 101, chat: new MadeUpChat(Id: Fixture.Sam, Type: "Chat", ReadUpTo: TeamsData.Id(seconds: 20), Newest: sam, ShortTitle: "Sam Rivera")),
            TeamsData.Batch(sequence: 102, replyChain: Chain(chat: Fixture.Sam, sam)));
        var arrived = await collector.Until(what: "Sam's message", predicate: snapshot => Messages(snapshot: snapshot, chat: Fixture.Sam) == 2);
        Assert.Equal(expected: [TeamsData.Id(seconds: 20), TeamsData.Id(seconds: 70)], actual: arrived.Messages[Fixture.Sam].Select(selector: message => message.Id));

        // Avery's chat, read in Teams: its messages are let go.
        TeamsData.Append(
            path: log,
            TeamsData.Batch(sequence: 103, chat: new MadeUpChat(Id: Fixture.Avery, Type: "Chat", ReadUpTo: TeamsData.Id(seconds: 30), Newest: Avery(seconds: 30, text: "See you there"), ShortTitle: "Avery Quinn")));
        var read = await collector.Until(what: "Avery's chat read in Teams", predicate: snapshot => !snapshot.Messages.ContainsKey(key: Fixture.Avery));
        Assert.Equal(expected: TeamsData.Id(seconds: 30), actual: read.Chats.Single(predicate: chat => chat.Id == Fixture.Avery).Marker?.MessageId);
    }

    [Fact]
    public async Task FollowsTheLogAsTeamsWritesIt()
    {
        using var folder = new TemporaryFolder();
        var (location, log) = TeamsData.Copy(folder: folder.Path, logLength: Fixture.FirstRunLength);
        var collector = new TeamsCollector();
        using var engine = new TeamsEngine(location: location, onChange: collector.Add, reloadDelay: quickly);
        engine.Start();
        await collector.Until(what: "the first read", predicate: snapshot => MarkerOf(snapshot: snapshot, chat: Fixture.Avery) == Fixture.Base + 1000);

        // Half a record: LevelDB is still writing it.
        var second = TeamsData.SecondRun();
        TeamsData.AppendBytes(path: log, bytes: second[..100]);
        await Task.Delay(millisecondsDelay: 400, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: Fixture.Base + 1000, actual: MarkerOf(snapshot: collector.Latest!, chat: Fixture.Avery));

        TeamsData.AppendBytes(path: log, bytes: second[100..]);
        var read = await collector.Until(what: "Avery's chat read in Teams", predicate: snapshot => MarkerOf(snapshot: snapshot, chat: Fixture.Avery) == Fixture.Base + 5000);
        Assert.Equal(expected: Fixture.Base + 8000, actual: read.Chats.Single(predicate: chat => chat.Id == Fixture.Sam).Newest?.Id);
        Assert.Equal(expected: 7, actual: read.Report.Conversations);
    }

    [Fact]
    public async Task FollowsANewLog()
    {
        using var folder = new TemporaryFolder();
        var (location, log) = TeamsData.Copy(folder: folder.Path);
        var collector = new TeamsCollector();
        using var engine = new TeamsEngine(location: location, onChange: collector.Add, reloadDelay: quickly);
        engine.Start();
        await collector.Until(what: "the first read", predicate: snapshot => MarkerOf(snapshot: snapshot, chat: Fixture.Avery) == Fixture.Base + 5000);

        // LevelDB starts a new log, and drops the old one: here, one with only the first run's writes.
        var newLog = Path.Combine(path1: Path.GetDirectoryName(path: log)!, path2: "000009.log");
        var firstRun = File.ReadAllBytes(path: log)[..Fixture.FirstRunLength];
        File.Delete(path: log);
        File.WriteAllBytes(path: newLog, bytes: firstRun);
        await collector.Until(what: "the new log", predicate: snapshot => MarkerOf(snapshot: snapshot, chat: Fixture.Avery) == Fixture.Base + 1000);

        TeamsData.AppendBytes(path: newLog, bytes: TeamsData.SecondRun());
        await collector.Until(what: "more written to it", predicate: snapshot => MarkerOf(snapshot: snapshot, chat: Fixture.Avery) == Fixture.Base + 5000);
    }

    [Fact]
    public async Task ReadsAChatInABlobFileOnceItsBlobEntryArrives()
    {
        using var folder = new TemporaryFolder();
        var (location, log) = TeamsData.Copy(folder: folder.Path, logLength: TeamsData.WrappedRecord);
        var bytes = File.ReadAllBytes(path: Fixture.Log);
        var collector = new TeamsCollector();
        using var engine = new TeamsEngine(location: location, onChange: collector.Add, reloadDelay: quickly);
        engine.Start();
        await collector.Until(what: "the first read", predicate: snapshot => snapshot.Chats.Any(predicate: chat => chat.Id == Fixture.Big));

        // Chromium writes the record first, and which blob file it's in only when the transaction commits.
        TeamsData.AppendBytes(path: log, bytes: bytes[TeamsData.WrappedRecord..TeamsData.WrappedBlobEntry]);
        var record = await collector.Until(what: "the record", predicate: snapshot => snapshot.Report.Unreadable.GetValueOrDefault(key: "corrupt blob reference") == 1);
        Assert.DoesNotContain(collection: record.Chats, filter: chat => chat.Id == Fixture.Wrapped);
        // Too few to say some of Teams' data couldn't be read, but its chat may be the one missing.
        Assert.Null(@object: record.Problem);
        Assert.False(condition: record.IsComplete);
        TeamsData.AppendBytes(path: log, bytes: bytes[TeamsData.WrappedBlobEntry..Fixture.FirstRunLength]);
        var read = await collector.Until(what: "its blob entry", predicate: snapshot => snapshot.Chats.Any(predicate: chat => chat.Id == Fixture.Wrapped));
        Assert.Equal(expected: Fixture.Base + 300, actual: MarkerOf(snapshot: read, chat: Fixture.Wrapped));
        Assert.Empty(collection: read.Report.Unreadable);
        Assert.True(condition: read.IsComplete);
    }

    [Fact]
    public async Task CountsATableAsUnreadableOnlyWhenItStaysSo()
    {
        using var folder = new TemporaryFolder();
        var (location, log) = TeamsData.Copy(folder: folder.Path);
        // As LevelDB writes a table: where it'll stay, footer last.
        File.WriteAllBytes(path: Path.Combine(path1: Path.GetDirectoryName(path: log)!, path2: "000010.ldb"), bytes: Enumerable.Repeat(element: (byte)7, count: 100).ToArray());
        var collector = new TeamsCollector();
        using var engine = new TeamsEngine(location: location, onChange: collector.Add, reloadDelay: quickly, confirmationDelay: TimeSpan.FromMilliseconds(value: 300));
        engine.Start();
        await collector.Until(what: "the first read", predicate: snapshot => snapshot.Chats.Count > 0);
        var first = collector.First!;
        Assert.Equal(expected: 0, actual: first.Report.UnreadableFiles);
        Assert.Null(@object: first.Problem);
        // The table may only be being written, but what it holds is missing meanwhile.
        Assert.False(condition: first.IsComplete);

        var later = await collector.Until(what: "a second look", predicate: snapshot => snapshot.Report.UnreadableFiles == 1);
        Assert.Equal(expected: TeamsProblem.PartlyUnreadable, actual: later.Problem);
        Assert.Equal(expected: first.Chats, actual: later.Chats);
    }

    [Fact]
    public async Task ClearsTheWarningWhenATableIsRemoved()
    {
        using var folder = new TemporaryFolder();
        var (location, log) = TeamsData.Copy(folder: folder.Path);
        var table = Path.Combine(path1: Path.GetDirectoryName(path: log)!, path2: "000010.ldb");
        File.WriteAllBytes(path: table, bytes: Enumerable.Repeat(element: (byte)7, count: 100).ToArray());
        var collector = new TeamsCollector();
        using var engine = new TeamsEngine(location: location, onChange: collector.Add, reloadDelay: quickly, confirmationDelay: TimeSpan.FromMilliseconds(value: 500));
        engine.Start();
        var unreadable = await collector.Until(what: "the confirmed warning", predicate: snapshot => snapshot.Report.UnreadableFiles == 1);

        File.Delete(path: table);

        var readable = await collector.Until(what: "the removed table", predicate: snapshot => snapshot.Report.UnreadableFiles == 0);
        Assert.Null(@object: readable.Problem);
        Assert.True(condition: readable.IsComplete);
        Assert.Equal(expected: unreadable.Chats, actual: readable.Chats);
    }

    /// Asked to read, as a panel opens, it reads what Teams wrote since, without waiting for its watcher.
    [Fact]
    public async Task ReadsWhatTeamsWroteWhenAsked()
    {
        using var folder = new TemporaryFolder();
        var (location, log) = TeamsData.Copy(folder: folder.Path, logLength: Fixture.FirstRunLength);
        var collector = new TeamsCollector();
        using var engine = new TeamsEngine(location: location, onChange: collector.Add, reloadDelay: TimeSpan.FromMinutes(value: 5));
        engine.Start();
        await collector.Until(what: "the first read", predicate: snapshot => MarkerOf(snapshot: snapshot, chat: Fixture.Avery) == Fixture.Base + 1000);

        TeamsData.AppendBytes(path: log, bytes: TeamsData.SecondRun());
        engine.Refresh();

        Assert.Equal(expected: Fixture.Base + 5000, actual: MarkerOf(snapshot: collector.Latest!, chat: Fixture.Avery));
    }

    /// Teams' data that wasn't there as it started, as before you sign in to Teams, is found when it's asked to read.
    [Fact]
    public async Task FindsTeamsDataOnceItsThere()
    {
        using var folder = new TemporaryFolder();
        var collector = new TeamsCollector();
        using var engine = new TeamsEngine(location: new TeamsCacheLocation(Root: folder.Combine("EBWebView"), IsTeamsOwn: false), onChange: collector.Add);
        engine.Start();
        await collector.Until(what: "the first read", predicate: snapshot => snapshot.Problem == TeamsProblem.NotFound);

        TeamsData.Copy(folder: folder.Path);
        engine.Refresh();

        Assert.True(condition: collector.Latest!.Found);
        Assert.Equal(expected: Fixture.Base + 5000, actual: MarkerOf(snapshot: collector.Latest, chat: Fixture.Avery));
    }

    /// Stopped, it hands over nothing more, whatever Teams writes.
    [Fact]
    public async Task ReadsNothingOnceStopped()
    {
        using var folder = new TemporaryFolder();
        var (location, log) = TeamsData.Copy(folder: folder.Path, logLength: Fixture.FirstRunLength);
        var collector = new TeamsCollector();
        var engine = new TeamsEngine(location: location, onChange: collector.Add, reloadDelay: quickly);
        engine.Start();
        await collector.Until(what: "the first read", predicate: snapshot => snapshot.Chats.Count > 0);
        engine.Stop();
        var count = collector.Count;

        TeamsData.AppendBytes(path: log, bytes: TeamsData.SecondRun());
        engine.Refresh();
        await Task.Delay(millisecondsDelay: 400, cancellationToken: TestContext.Current.CancellationToken);

        Assert.Equal(expected: count, actual: collector.Count);
    }

    /// BriefBar only reads Teams' data: every file stays as it was, and none is added, not even a lock.
    [Fact]
    public void LeavesTeamsDataAsItWas()
    {
        using var folder = new TemporaryFolder();
        var (location, _) = MadeUp(folder: folder);
        TeamsData.Copy(folder: folder.Combine("Profile2"));
        var before = Files(root: folder.Path);

        TeamsEngine.LoadOnce(location: location);
        TeamsEngine.LoadOnce(location: new TeamsCacheLocation(Root: folder.Combine("Profile2", "EBWebView"), IsTeamsOwn: false));

        Assert.Equal(expected: before, actual: Files(root: folder.Path));
    }

    /// Each file under `root`, with what it holds and when it was last written.
    static Dictionary<string, string> Files(string root) => Directory.EnumerateFiles(path: root, searchPattern: "*", searchOption: SearchOption.AllDirectories)
        .ToDictionary(
            keySelector: path => Path.GetRelativePath(relativeTo: root, path: path),
            elementSelector: path => Convert.ToHexString(inArray: SHA256.HashData(source: File.ReadAllBytes(path: path))) + " "
                + File.GetLastWriteTimeUtc(path: path).Ticks.ToString(provider: System.Globalization.CultureInfo.InvariantCulture));

    /// Teams' data as these tests write it, with its message cache: Avery wrote since you read the chat, and Sam's chat is
    /// read; your message is the newest in Launch crew; nobody has read the meeting's chat; and the muted chat has a
    /// message.
    static (TeamsCacheLocation Location, string Log) MadeUp(TemporaryFolder folder)
    {
        var jordan = new MadeUpMessage(Id: TeamsData.Id(seconds: 35), Sender: "Jordan Lee", Html: "Staging is green");
        var mine = new MadeUpMessage(Id: TeamsData.Id(seconds: 40), Sender: "Made-up Me", Html: "Shipping at 5", FromMe: true);
        var call = new MadeUpMessage(Id: TeamsData.Id(seconds: 45), Sender: "Priya Patel", Html: string.Empty, Type: "Event/Call");
        var notes = new MadeUpMessage(Id: TeamsData.Id(seconds: 50), Sender: "Priya Patel", Html: "<p>Notes are in the chat</p>");
        var muted = new MadeUpMessage(Id: TeamsData.Id(seconds: 60), Sender: "Jordan Lee", Html: "Muted chatter");
        var sam = new MadeUpMessage(Id: TeamsData.Id(seconds: 20), Sender: "Sam Rivera", Html: "Thanks!");
        return TeamsData.Write(
            folder: folder.Path,
            chats:
            [
                new MadeUpChat(Id: Fixture.Avery, Type: "Chat", ReadUpTo: TeamsData.Id(seconds: 10), Newest: Avery(seconds: 30, text: "See you there"), ShortTitle: "Avery Quinn"),
                new MadeUpChat(Id: Fixture.Sam, Type: "Chat", ReadUpTo: TeamsData.Id(seconds: 20), Newest: sam, ShortTitle: "Sam Rivera"),
                new MadeUpChat(Id: Fixture.Crew, Type: "Chat", ReadUpTo: TeamsData.Id(seconds: 10), Newest: mine, Topic: "Launch crew"),
                new MadeUpChat(Id: Fixture.Sync, Type: "Meeting", ReadUpTo: 0, Newest: notes, Topic: "Weekly sync"),
                new MadeUpChat(Id: Fixture.Big, Type: "Chat", ReadUpTo: 0, Newest: muted, Topic: "Muted chat", Alerts: "false"),
            ],
            replyChains:
            [
                Chain(chat: Fixture.Avery, Avery(seconds: 10, text: "Lunch?")),
                Chain(chat: Fixture.Avery, Avery(seconds: 20, text: "Noon works")),
                Chain(chat: Fixture.Avery, Avery(seconds: 30, text: "See you there")),
                Chain(chat: Fixture.Sam, sam),
                Chain(chat: Fixture.Crew, jordan),
                Chain(chat: Fixture.Crew, mine),
                Chain(chat: Fixture.Sync, call),
                Chain(chat: Fixture.Sync, notes),
                Chain(chat: Fixture.Big, muted),
            ]);
    }

    static MadeUpMessage Avery(double seconds, string text) => new(Id: TeamsData.Id(seconds: seconds), Sender: "Avery Quinn", Html: text);

    static MadeUpReplyChain Chain(string chat, params MadeUpMessage[] messages) => new(ConversationId: chat, Messages: messages);

    static int Messages(TeamsSnapshot snapshot, string chat) => snapshot.Messages.TryGetValue(key: chat, value: out var messages) ? messages.Count : 0;

    static long? MarkerOf(TeamsSnapshot snapshot, string chat) => snapshot.Chats.FirstOrDefault(predicate: each => each.Id == chat)?.Marker?.MessageId;

    /// The fixture's marker for a chat read up to `read` milliseconds after its base time, read 900 milliseconds later.
    static ReadMarker Marker(long read) => new(
        MessageId: Fixture.Base + read,
        ReadAt: DateTimeOffset.FromUnixTimeMilliseconds(milliseconds: Fixture.Base + read + 900));
}
