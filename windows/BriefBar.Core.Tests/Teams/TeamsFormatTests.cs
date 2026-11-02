using System.Globalization;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using BriefBar.Core.Teams;
using BriefBar.Core.Tests.ChromiumIndexedDB;
using BriefBar.Core.Tests.Copilot;

namespace BriefBar.Core.Tests.Teams;

/// Teams' own formats: read markers, conversation IDs and kinds, messages' text and types, the links that open a chat, its
/// databases' names, and where the new Teams app keeps them. The Mac's `ReadMarkerTests`, `ParsingTests` and
/// `DeepLinkTests`, where Windows reads the same.
public sealed class TeamsFormatTests
{
    [Fact]
    public void ReadsTeamsConsumptionHorizon()
    {
        var marker = ReadMarker.Parse(consumptionHorizon: "1792317605000;1792317605900;1792317605007");
        Assert.Equal(expected: 1_792_317_605_000, actual: marker?.MessageId);
        Assert.Equal(expected: DateTimeOffset.FromUnixTimeMilliseconds(milliseconds: 1_792_317_605_900), actual: marker?.ReadAt);
        Assert.Null(@object: ReadMarker.Parse(consumptionHorizon: "1792317605000")?.ReadAt);
        Assert.Equal(expected: 1_792_317_605_000, actual: ReadMarker.Parse(consumptionHorizon: "1792317605000")?.MessageId);
        foreach (var never in new[] { "0;0;0", "", "0;900;7", "-5;1;1", "abc;1;1", ";1792317605000;1", null })
        {
            Assert.Null(@object: ReadMarker.Parse(consumptionHorizon: never));
        }

        // Every chat has the field, read or not: a chat never read has it as `0;…`.
        foreach (var horizon in new[] { "1792317605000;1792317605900;1792317605007", "1792317605000", "0;0;0", "0;900;7" })
        {
            Assert.True(condition: ReadMarker.IsHorizon(consumptionHorizon: horizon));
        }
        foreach (var other in new[] { "", "-5;1;1", "abc;1;1", ";1792317605000;1", "{\"id\":1}", null })
        {
            Assert.False(condition: ReadMarker.IsHorizon(consumptionHorizon: other));
        }
    }

    [Fact]
    public void CoversMessagesUpToTheNewestRead()
    {
        var marker = new ReadMarker(MessageId: TeamsData.Id(seconds: 20));
        Assert.True(condition: marker.Covers(messageId: TeamsData.Id(seconds: 19)));
        Assert.True(condition: marker.Covers(messageId: TeamsData.Id(seconds: 20)));
        Assert.False(condition: marker.Covers(messageId: TeamsData.Id(seconds: 21)));
    }

    /// Teams' `type` decides, as its own list does: a chat is a 1:1 chat or a group chat by its ID, a meeting's chat is its
    /// own type, and channels, communities and Teams' own streams aren't chats. Without a type, the ID tells, as the Mac
    /// tells a notification's chat.
    [Fact]
    public void ClassifiesConversations()
    {
        Assert.Equal(expected: ConversationKind.OneOnOne, actual: ConversationIds.Kind(type: "Chat", id: Fixture.Avery));
        Assert.Equal(expected: ConversationKind.Group, actual: ConversationIds.Kind(type: "Chat", id: Fixture.Crew));
        Assert.Equal(expected: ConversationKind.Meeting, actual: ConversationIds.Kind(type: "Meeting", id: Fixture.Sync));
        Assert.Null(@object: ConversationIds.Kind(type: "Topic", id: Fixture.Channel));
        Assert.Null(@object: ConversationIds.Kind(type: "Space", id: "19:abcdefabcdefabcdefabcdefabcdef12@thread.skype"));
        Assert.Null(@object: ConversationIds.Kind(type: "EngageCommunity", id: "19:abcdefabcdefabcdefabcdefabcdef12@thread.v2"));
        Assert.Null(@object: ConversationIds.Kind(type: "StreamOfNotes", id: "48:notes"));

        Assert.Equal(expected: ConversationKind.OneOnOne, actual: ConversationIds.Kind(type: null, id: Fixture.Avery));
        Assert.Equal(expected: ConversationKind.Group, actual: ConversationIds.Kind(type: string.Empty, id: Fixture.Crew));
        Assert.Equal(expected: ConversationKind.Meeting, actual: ConversationIds.Kind(type: null, id: Fixture.Sync));
        Assert.Null(@object: ConversationIds.Kind(type: null, id: Fixture.Channel));

        Assert.Equal(expected: ChatGroup.Chats, actual: ConversationIds.Group(kind: ConversationKind.OneOnOne));
        Assert.Equal(expected: ChatGroup.Groups, actual: ConversationIds.Group(kind: ConversationKind.Group));
        Assert.Equal(expected: ChatGroup.Groups, actual: ConversationIds.Group(kind: ConversationKind.Meeting));
    }

    /// Channels, communities and Teams' own threads and streams aren't chats. A conversation of a type BriefBar doesn't
    /// know may be one, as after an update to Teams, so it isn't taken for one that isn't.
    [Fact]
    public void TellsWhatIsntAChat()
    {
        Assert.True(condition: ConversationIds.IsNotChat(type: "Topic", id: Fixture.Channel));
        Assert.True(condition: ConversationIds.IsNotChat(type: "Space", id: "19:abcdefabcdefabcdefabcdefabcdef12@thread.skype"));
        Assert.True(condition: ConversationIds.IsNotChat(type: "EngageCommunity", id: "19:abcdefabcdefabcdefabcdefabcdef12@thread.v2"));
        Assert.True(condition: ConversationIds.IsNotChat(type: "StreamOfMentions", id: "48:mentions"));
        Assert.True(condition: ConversationIds.IsNotChat(type: "SomethingNew", id: "48:notes"));
        Assert.True(condition: ConversationIds.IsNotChat(type: null, id: Fixture.Channel));
        Assert.True(condition: ConversationIds.IsNotChat(type: string.Empty, id: "19:abcdefabcdefabcdefabcdefabcdef12@thread.skype"));

        Assert.False(condition: ConversationIds.IsNotChat(type: "Chat", id: Fixture.Avery));
        Assert.False(condition: ConversationIds.IsNotChat(type: "Meeting", id: Fixture.Sync));
        Assert.False(condition: ConversationIds.IsNotChat(type: null, id: Fixture.Crew));
        Assert.False(condition: ConversationIds.IsNotChat(type: "SomethingNew", id: Fixture.Crew));
    }

    [Fact]
    public void AcceptsOnlyTeamsThreadIDs()
    {
        Assert.True(condition: ConversationIds.IsValid(id: Fixture.Avery));
        Assert.True(condition: ConversationIds.IsValid(id: Fixture.Sync));
        foreach (var id in new[] { null, string.Empty, "48:notes", "19:x@thread.v2/../evil", "https://example.com", "19:a b@thread.v2", "19:x@thread.v2?y=1" })
        {
            Assert.False(condition: ConversationIds.IsValid(id: id));
        }
    }

    [Fact]
    public void ReadsAMessagesHTMLAsOneLine()
    {
        Assert.Equal(expected: "Staging is green 🎉", actual: MessageText.Plain(html: "<p>Staging is green <emoji id=\"party\" alt=\"🎉\" title=\"Party\"></emoji></p>"));
        Assert.Equal(
            expected: "Hi Jordan Lee, can you look?",
            actual: MessageText.Plain(html: "<p>Hi <span itemtype=\"http://schema.skype.com/Mention\" itemscope=\"\" itemid=\"0\">Jordan Lee</span>, can you look?</p>"));
        Assert.Equal(expected: "First line Second line", actual: MessageText.Plain(html: "<div>First line<br>Second line</div>"));
        Assert.Equal(expected: "One Two", actual: MessageText.Plain(html: "<ul><li>One</li><li>Two</li></ul>"));
        Assert.Equal(expected: "Fish & chips <3", actual: MessageText.Plain(html: "<p>Fish&nbsp;&amp; chips &lt;3</p>"));
        Assert.Equal(expected: "Plain text", actual: MessageText.Plain(html: "  Plain\ntext "));
        Assert.Equal(expected: string.Empty, actual: MessageText.Plain(html: null));
        Assert.Equal(expected: string.Empty, actual: MessageText.Plain(html: "<p></p>"));
    }

    [Fact]
    public void ShortensVeryLongMessages()
    {
        var text = MessageText.Plain(html: string.Concat(values: Enumerable.Repeat(element: "👍🏽", count: 1_000)));
        Assert.Equal(expected: MessageText.Limit, actual: new StringInfo(value: text).LengthInTextElements);
        Assert.EndsWith(expectedEndString: "👍🏽…", actualString: text, comparisonType: StringComparison.Ordinal);
    }

    /// What someone wrote can be unread: not a call, a meeting's recording or transcript, or a change to the chat.
    [Fact]
    public void CountsOnlyWhatSomeoneWrote()
    {
        foreach (var type in new[] { "RichText/Html", "Text", "RichText", "RichText/Media_Card", "RichText/Media_GenericFile", "RichText/UriObject" })
        {
            Assert.True(condition: TeamsMessageTypes.IsContent(type: type));
        }
        foreach (var type in new[] { "Event/Call", "RichText/Media_CallRecording", "RichText/Media_CallTranscript", "ThreadActivity/AddMember", "ThreadActivity/TopicUpdate", "Control/Typing", string.Empty, null })
        {
            Assert.False(condition: TeamsMessageTypes.IsContent(type: type));
        }
    }

    [Fact]
    public void LinksToAMessageInAChat()
    {
        var link = DeepLink.Message(conversationId: Fixture.Crew, messageId: 1_792_317_600_123);
        const string expected = "msteams:/l/message/19%3A0123456789abcdef0123456789abcdef%40thread.v2/1792317600123?context=%7B%22contextType%22%3A%22chat%22%7D";
        Assert.Equal(expected: expected, actual: link?.AbsoluteUri);
        Assert.Equal(expected: expected, actual: link?.OriginalString);
    }

    [Fact]
    public void LinksToAChatWithoutAMessage()
    {
        Assert.Equal(
            expected: "msteams:/l/chat/19%3A11111111-aaaa-4aaa-8aaa-111111111111_99999999-ffff-4fff-8fff-999999999999%40unq.gbl.spaces/0",
            actual: DeepLink.Chat(conversationId: Fixture.Avery)?.AbsoluteUri);
        var never = new ConversationSummary(Id: Fixture.Avery, Kind: ConversationKind.OneOnOne, Title: "Avery Quinn", FullTitle: null, Unread: [], Latest: null, LastActivity: null);
        Assert.Equal(expected: DeepLink.Chat(conversationId: Fixture.Avery), actual: DeepLink.To(conversation: never));
    }

    [Fact]
    public void RefusesWhatIsNotAnIDOrAMessageNumber()
    {
        Assert.Null(@object: DeepLink.Message(conversationId: "19:x@thread.v2/../evil", messageId: 1));
        Assert.Null(@object: DeepLink.Message(conversationId: Fixture.Avery, messageId: 0));
        Assert.Null(@object: DeepLink.Chat(conversationId: "https://example.com"));
    }

    [Fact]
    public void ReadsTeamsDatabaseNames()
    {
        var conversations = TeamsDatabaseName.Parse(name: Fixture.ConversationsDatabase);
        Assert.Equal(expected: TeamsDatabaseName.Conversations, actual: conversations?.Manager);
        Assert.Equal(expected: "react-web-client:" + Fixture.Tenant + ":" + Fixture.Me + ":en-us", actual: conversations?.Account);
        Assert.Equal(expected: Fixture.Me, actual: conversations?.UserId);
        var replyChains = TeamsDatabaseName.Parse(name: Fixture.ReplyChainsDatabase);
        Assert.Equal(expected: TeamsDatabaseName.ReplyChains, actual: replyChains?.Manager);
        Assert.Equal(expected: conversations?.Account, actual: replyChains?.Account);
        Assert.Equal(
            expected: Fixture.Me,
            actual: TeamsDatabaseName.Parse(name: "Teams:conversation-manager:react-web-client:" + Fixture.Tenant + ":" + Fixture.Me.ToUpperInvariant() + ":en-us")?.UserId);
        foreach (var name in new[] { "Teams:conversation-manager", "Other:conversation-manager:react-web-client:" + Fixture.Me, "Teams:settings:react-web-client:en-us", string.Empty })
        {
            Assert.Null(@object: TeamsDatabaseName.Parse(name: name));
        }
    }

    [Fact]
    public void FindsTeamsFoldersOnly()
    {
        using var folder = new TemporaryFolder();
        var root = folder.Combine("EBWebView");
        foreach (var path in new[]
        {
            @"WV2Profile_tfw\IndexedDB\https_teams.microsoft.com_0.indexeddb.leveldb",
            @"WV2Profile_tfw\IndexedDB\https_teams.cloud.microsoft_0.indexeddb.leveldb",
            @"WV2Profile_tfw\IndexedDB\https_teams.microsoft.com_0.indexeddb.blob",
            @"WV2Profile_tfw\IndexedDB\https_outlook.office.com_0.indexeddb.leveldb",
            @"WV2Profile_tfl\IndexedDB\https_teams.live.com_0.indexeddb.leveldb",
            "Crashpad",
        })
        {
            Directory.CreateDirectory(path: Path.Combine(path1: root, path2: path));
        }

        var location = new TeamsCacheLocation(Root: root, IsTeamsOwn: false);

        Assert.Equal(
            expected:
            [
                @"WV2Profile_tfl\IndexedDB\https_teams.live.com_0.indexeddb.leveldb",
                @"WV2Profile_tfw\IndexedDB\https_teams.cloud.microsoft_0.indexeddb.leveldb",
                @"WV2Profile_tfw\IndexedDB\https_teams.microsoft.com_0.indexeddb.leveldb",
            ],
            actual: location.Folders().Select(selector: path => Path.GetRelativePath(relativeTo: root, path: path)));
        Assert.Empty(collection: new TeamsCacheLocation(Root: folder.Combine("nowhere"), IsTeamsOwn: false).Folders());
    }

    /// A folder that can't be listed may hold Teams' data: it's counted, with the folders that could be listed.
    [Fact]
    [SupportedOSPlatform(platformName: "windows")]
    public void CountsTheFoldersItCantList()
    {
        Assert.SkipUnless(condition: OperatingSystem.IsWindows(), reason: "Only Windows' access control keeps a folder from being listed here.");
        using var folder = new TemporaryFolder();
        var root = folder.Combine("EBWebView");
        var teams = Path.Combine(paths: [root, "WV2Profile_tfw", "IndexedDB", "https_teams.microsoft.com_0.indexeddb.leveldb"]);
        Directory.CreateDirectory(path: teams);
        var location = new TeamsCacheLocation(Root: root, IsTeamsOwn: false);

        using (new DeniedFolder(path: Path.Combine(paths: [root, "WV2Profile_tfl", "IndexedDB"])))
        {
            var partly = location.FindFolders();
            Assert.Equal(expected: [teams], actual: partly.Folders);
            Assert.Equal(expected: 1, actual: partly.Unlistable);
        }
        using (new DeniedFolder(path: root))
        {
            var none = location.FindFolders();
            Assert.Empty(collection: none.Folders);
            Assert.Equal(expected: 1, actual: none.Unlistable);
        }

        var all = location.FindFolders();
        Assert.Equal(expected: [teams], actual: all.Folders);
        Assert.Equal(expected: 0, actual: all.Unlistable);
    }

    /// Where Windows can't say whether a folder is there, as when you can't read its attributes or list the folder it's
    /// in, it counts as one that couldn't be listed, rather than as one that isn't there.
    [Fact]
    [SupportedOSPlatform(platformName: "windows")]
    public void CountsAFolderWindowsCantSayIsThere()
    {
        Assert.SkipUnless(condition: OperatingSystem.IsWindows(), reason: "Only Windows' access control keeps a folder's attributes from being read here.");
        using var folder = new TemporaryFolder();
        var root = folder.Combine("EBWebView");
        var profile = Path.Combine(path1: root, path2: "WV2Profile_tfw");
        var indexedDB = Path.Combine(path1: profile, path2: "IndexedDB");
        Directory.CreateDirectory(path: Path.Combine(path1: indexedDB, path2: "https_teams.microsoft.com_0.indexeddb.leveldb"));
        using var attributes = new DeniedFolder(path: indexedDB, rights: FileSystemRights.ReadAttributes);
        using var listing = new DeniedFolder(path: profile);
        Assert.False(condition: Directory.Exists(path: indexedDB));

        var found = new TeamsCacheLocation(Root: root, IsTeamsOwn: false).FindFolders();

        Assert.Empty(collection: found.Folders);
        Assert.Equal(expected: 1, actual: found.Unlistable);
    }

    [Fact]
    public void IsTeamsOwnUnlessAVariableSaysOtherwise()
    {
        var teams = TeamsCacheLocation.Default(environment: new Dictionary<string, string?>());
        Assert.True(condition: teams.IsTeamsOwn);
        Assert.Equal(
            expected: Path.Combine(paths: [Environment.GetFolderPath(folder: Environment.SpecialFolder.LocalApplicationData), "Packages", "MSTeams_8wekyb3d8bbwe", "LocalCache", "Microsoft", "MSTeams", "EBWebView"]),
            actual: teams.Root);
        Assert.True(condition: TeamsCacheLocation.Default(environment: new Dictionary<string, string?> { [TeamsCacheLocation.Variable] = string.Empty }).IsTeamsOwn);
        Assert.Equal(
            expected: new TeamsCacheLocation(Root: @"C:\made-up\EBWebView", IsTeamsOwn: false),
            actual: TeamsCacheLocation.Default(environment: new Dictionary<string, string?> { [TeamsCacheLocation.Variable] = @"C:\made-up\EBWebView" }));
    }
}
