using BriefBar.Core.Copilot;
using static BriefBar.Core.Tests.Copilot.TestTimes;

namespace BriefBar.Core.Tests.Copilot;

public sealed class AppDatabaseTests
{
    const string SessionId = "11111111-1111-4111-8111-111111111111";
    const string WorkspaceId = "22222222-2222-4222-8222-222222222222";
    const string ChatId = "33333333-3333-4333-8333-333333333333";

    public static TheoryData<string, string[]?> StringArrays { get; } = new()
    {
        { "[\"a\",\"b\"]", ["a", "b"] },
        { "[]", [] },
        { "[\"a\",1]", null },
        { "{\"a\":1}", null },
        { "not json", null },
        { "", null },
        // Half of an emoji, which .NET can't make a string of.
        { "[\"a\",\"\\ud83d\"]", null },
    };

    public static TheoryData<long, long, double, int> Usage { get; } = new()
    {
        { 0, 200_000, 0.0, 0 },
        { 50_000, 200_000, 0.25, 25 },
        { 198_000, 200_000, 0.99, 99 },
        { 250_000, 200_000, 1.0, 100 },
        { -5, 100, 0.0, 0 },
        { 10, 0, 0.0, 0 },
    };

    [Theory]
    [MemberData(memberName: nameof(StringArrays))]
    public void ParsesStringArrays(string json, string[]? expected) =>
        Assert.Equal(expected: expected, actual: AppDatabase.ParseStringArray(json: json));

    [Fact]
    public void FindsTheSessionOnScreen()
    {
        SessionMeta[] sessions =
        [
            new() { Id = SessionId, Name = "Project", WorkspaceId = WorkspaceId },
            new() { Id = ChatId, Name = "Chat", SessionType = "general_chat" },
        ];
        string? Viewed(string route) => AppDatabase.SessionId(route: route, sessions: sessions);
        Assert.Equal(expected: ChatId, actual: Viewed(route: "/chats/" + ChatId));
        Assert.Equal(expected: ChatId, actual: Viewed(route: "/chats/" + ChatId.ToUpperInvariant()));
        Assert.Equal(expected: SessionId, actual: Viewed(route: "/workspaces/" + WorkspaceId + "/session"));
        Assert.Equal(expected: ChatId, actual: Viewed(route: "/projects/99999999-9999-4999-8999-999999999999/chats/" + ChatId));
        Assert.Null(@object: Viewed(route: "/settings"));
        Assert.Null(@object: Viewed(route: ""));
    }

    [Fact]
    public void LoadsWhatTheAppShows()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("data.db");
        using var db = new TestDatabase(path: path, journalMode: "WAL");
        db.CreateAppSchema();
        db.AddProject(id: "p1", name: "acme-web");

        // A project session: its live workspace's name, which the sidebar shows, wins over the session's title.
        db.AddSession(id: SessionId, title: "Session title", mode: "autopilot", running: true, updatedAt: T(seconds: 10));
        db.AddWorkspace(id: "old-workspace", session: SessionId, name: "Old", branch: "old", archived: true, updatedAt: T(seconds: 20));
        db.AddWorkspace(id: WorkspaceId, session: SessionId, name: "  Fix login  ", branch: "fix-login", creator: "parent-session", updatedAt: T(seconds: 5));
        // Chats have no workspace.
        db.AddSession(id: ChatId, title: "  Quick question ", type: "general_chat", interrupted: true, reason: "app_quit", updatedAt: T(seconds: 30));
        db.AddSession(id: "untitled-chat", title: null, type: "general_chat");
        // Not shown by the app.
        db.AddSession(id: "archived", title: "Archived", archived: true);
        db.AddWorkspace(id: "w-archived", session: "archived", name: "Archived");
        db.AddSession(id: "workspace-archived", title: "Gone");
        db.AddWorkspace(id: "w-gone", session: "workspace-archived", name: "Gone", archived: true);
        db.AddSession(id: "no-workspace", title: "Orphan");

        db.AddActivity(session: SessionId, type: "agent_asking", preview: "Older", at: T(seconds: 1));
        db.AddActivity(session: SessionId, type: "agent_idle", preview: "Latest", at: T(seconds: 9));
        db.SetAppState(key: "workspace-unread", value: "[\"" + WorkspaceId + "\"]", at: T(seconds: 40));
        db.SetAppState(key: "lastRoutePath", value: "/chats/" + ChatId, at: T(seconds: 41));

        var snapshot = AppDatabase.Load(path: path);
        var sessions = snapshot.Sessions.ToDictionary(keySelector: session => session.Id);
        Assert.Equal(expected: new[] { SessionId, ChatId, "untitled-chat" }.Order(), actual: sessions.Keys.Order());

        Assert.Equal(
            expected: new SessionMeta
            {
                Id = SessionId,
                Name = "Fix login",
                SessionType = "project",
                Mode = "autopilot",
                IsRunning = true,
                CreatedAt = T(seconds: -86_400),
                UpdatedAt = T(seconds: 10),
                ProjectName = "acme-web",
                Branch = "fix-login",
                CreatorSessionId = "parent-session",
                WorkspaceId = WorkspaceId,
                LastActivity = new ActivityPreview(Kind: "agent_idle", Text: "Latest", At: T(seconds: 9)),
            },
            actual: sessions[SessionId]);
        Assert.Equal(
            expected: new SessionMeta
            {
                Id = ChatId,
                Name = "Quick question",
                SessionType = "general_chat",
                WasInterrupted = true,
                InterruptionReason = "app_quit",
                CreatedAt = T(seconds: -86_400),
                UpdatedAt = T(seconds: 30),
            },
            actual: sessions[ChatId]);
        Assert.Equal(expected: "", actual: sessions["untitled-chat"].Name);
        Assert.Equal(
            expected: new AppViewState { UnreadWorkspaceIds = new HashSet<string> { WorkspaceId }, UnreadUpdatedAt = T(seconds: 40), ViewedSessionId = ChatId },
            actual: snapshot.View);
    }

    [Fact]
    public void ReadsAlongsideTheAppsWriter()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("data.db");
        using var db = new TestDatabase(path: path, journalMode: "WAL");
        db.CreateAppSchema();
        db.AddSession(id: ChatId, title: "Committed", type: "general_chat");

        // The app is mid-write: readers must neither wait for nor see the uncommitted row.
        db.Exec(statements: "BEGIN IMMEDIATE;");
        db.AddSession(id: "pending", title: "Uncommitted", type: "general_chat");
        var started = System.Diagnostics.Stopwatch.StartNew();
        var during = AppDatabase.Load(path: path);
        Assert.Equal(expected: [ChatId], actual: during.Sessions.Select(selector: session => session.Id));
        Assert.True(condition: started.Elapsed < TimeSpan.FromSeconds(value: 1));

        db.Exec(statements: "COMMIT;");
        Assert.Equal(expected: new[] { ChatId, "pending" }.Order(), actual: AppDatabase.Load(path: path).Sessions.Select(selector: session => session.Id).Order());
    }

    [Fact]
    public void FallsBackToAMinimalQueryWhenTheSchemaChanges()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("data.db");
        using var db = new TestDatabase(path: path);
        db.Exec(statements: $"""
            CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT, session_type TEXT, updated_at TEXT, archived_at TEXT);
            INSERT INTO sessions VALUES ('a', '  Alpha ', 'project', {TestDatabase.Sql(value: Iso(date: T(seconds: 1)))}, NULL);
            INSERT INTO sessions VALUES ('b', NULL, 'general_chat', {TestDatabase.Sql(value: Iso(date: T(seconds: 2)))}, NULL);
            INSERT INTO sessions VALUES ('c', 'Archived', 'project', {TestDatabase.Sql(value: Iso(date: T(seconds: 3)))}, {TestDatabase.Sql(value: Iso(date: T(seconds: 3)))});
            """);

        var snapshot = AppDatabase.Load(path: path);
        Assert.Equal(
            expected:
            [
                new SessionMeta { Id = "b", Name = "", SessionType = "general_chat", IsRunning = null, UpdatedAt = T(seconds: 2) },
                new SessionMeta { Id = "a", Name = "Alpha", SessionType = "project", IsRunning = null, UpdatedAt = T(seconds: 1) },
            ],
            actual: snapshot.Sessions);
        Assert.Equal(expected: new AppViewState(), actual: snapshot.View);
    }

    [Fact]
    public void ReadsEachSessionsLatestContextUsage()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("data.db");
        using var db = new TestDatabase(path: path);
        db.CreateAppSchema();
        db.AddSession(id: ChatId, title: "Chat", type: "general_chat");
        db.AddSession(id: "other-chat", title: "Other", type: "general_chat");
        db.AddSession(id: "unmeasured", title: "Unmeasured", type: "general_chat");
        // The latest measurement counts, whatever order the rows are in. Rows without a limit don't.
        db.AddContextUsage(session: ChatId, tokens: 90_000, limit: 200_000, at: T(seconds: 20));
        db.AddContextUsage(session: ChatId, tokens: 30_000, limit: 200_000, at: T(seconds: 10));
        db.AddContextUsage(session: "other-chat", tokens: 64_000, limit: 128_000, at: T(seconds: 5));
        db.AddContextUsage(session: "other-chat", tokens: 5_000, limit: 0, at: T(seconds: 30));

        var sessions = AppDatabase.Load(path: path).Sessions.ToDictionary(keySelector: session => session.Id);
        Assert.Equal(expected: new ContextUsage(Tokens: 90_000, Limit: 200_000), actual: sessions[ChatId].ContextUsage);
        Assert.Equal(expected: new ContextUsage(Tokens: 64_000, Limit: 128_000), actual: sessions["other-chat"].ContextUsage);
        Assert.Null(@object: sessions["unmeasured"].ContextUsage);
    }

    /// The session that coordinates each one: a project session's workspace records it, and a chat's own link.
    [Fact]
    public void ReadsWhichSessionCoordinatesEachOne()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("data.db");
        using var db = new TestDatabase(path: path);
        db.CreateAppSchema();
        db.AddProject(id: "p1", name: "acme-web");
        db.AddSession(id: "coordinator", title: "Release 2.5", type: "general_chat");
        db.AddSession(id: "child", title: "Pick colors");
        db.AddWorkspace(id: "w-child", session: "child", name: "Pick colors", creator: "coordinator", coordinator: "coordinator");
        db.AddSession(id: "detached", title: "Pick fonts");
        db.AddWorkspace(id: "w-detached", session: "detached", name: "Pick fonts", creator: "coordinator");
        db.AddSession(id: "chat-child", title: "Ask about icons", type: "general_chat");
        db.AddChatParent(session: "chat-child", parent: "coordinator", coordinator: "coordinator");
        db.AddSession(id: "chat-detached", title: "Ask about sizes", type: "general_chat");
        db.AddChatParent(session: "chat-detached", parent: "coordinator", coordinator: null);
        // A session with two live workspaces is listed with the newer one, and only its coordinator counts.
        db.AddSession(id: "moved", title: "Pick sizes");
        db.AddWorkspace(id: "w-moved-old", session: "moved", name: "Pick sizes", creator: "coordinator", coordinator: "coordinator", updatedAt: T(seconds: 1));
        db.AddWorkspace(id: "w-moved-new", session: "moved", name: "Pick sizes", updatedAt: T(seconds: 2));
        db.AddSession(id: "adopted", title: "Pick icons");
        db.AddWorkspace(id: "w-adopted-old", session: "adopted", name: "Pick icons", updatedAt: T(seconds: 1));
        db.AddWorkspace(id: "w-adopted-new", session: "adopted", name: "Pick icons", coordinator: "coordinator", updatedAt: T(seconds: 2));

        var sessions = AppDatabase.Load(path: path).Sessions.ToDictionary(keySelector: session => session.Id);
        Assert.Equal(
            expected: new Dictionary<string, string?>
            {
                ["coordinator"] = null,
                ["child"] = "coordinator",
                ["detached"] = null,
                ["chat-child"] = "coordinator",
                ["chat-detached"] = null,
                ["moved"] = null,
                ["adopted"] = "coordinator",
            },
            actual: sessions.ToDictionary(keySelector: pair => pair.Key, elementSelector: pair => pair.Value.CoordinatorSessionId));
        Assert.Equal(expected: "coordinator", actual: sessions["detached"].CreatorSessionId);
        Assert.Equal(expected: "w-moved-new", actual: sessions["moved"].WorkspaceId);

        // Older app versions record neither.
        db.Exec(statements: "ALTER TABLE workspaces DROP COLUMN coordinating_creator_session_id; DROP TABLE chat_parent_links;");
        var older = AppDatabase.Load(path: path).Sessions;
        Assert.Equal(expected: 7, actual: older.Count);
        Assert.All(collection: older, action: session => Assert.Null(@object: session.CoordinatorSessionId));
        Assert.Equal(expected: "acme-web", actual: older.First(predicate: session => session.Id == "child").ProjectName);
    }

    /// The session each one is nested under, as the app's sidebar nests it: a project session under its parent
    /// workspace's session, or else the chat that started it; a chat under the session that coordinates it, or else the
    /// one that started it.
    [Fact]
    public void ReadsWhichSessionEachOneIsNestedUnder()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("data.db");
        using var db = new TestDatabase(path: path);
        db.CreateAppSchema();
        db.AddProject(id: "p1", name: "acme-web");
        db.AddProject(id: "p2", name: "acme-docs");
        db.AddSession(id: "plan", title: "Release 2.5", type: "general_chat");
        db.AddSession(id: "lead", title: "Ship the API");
        db.AddWorkspace(id: "w-lead", session: "lead", name: "Ship the API");
        // Started by a session in its project: its workspace's parent.
        db.AddSession(id: "linked", title: "Write the changelog");
        db.AddWorkspace(id: "w-linked", session: "linked", name: "Write the changelog", creator: "lead", coordinator: "lead");
        db.AddWorkspaceParent(child: "w-linked", parent: "w-lead");
        // Started by a chat, which has no workspace: whether or not the chat coordinates it.
        db.AddSession(id: "coordinated", title: "Pick colors");
        db.AddWorkspace(id: "w-coordinated", session: "coordinated", name: "Pick colors", creator: "plan", coordinator: "plan");
        db.AddSession(id: "uncoordinated", title: "Pick fonts");
        db.AddWorkspace(id: "w-uncoordinated", session: "uncoordinated", name: "Pick fonts", creator: "plan");
        // A fork links to the session it was forked from, which the sidebar doesn't nest it under.
        db.AddSession(id: "fork", title: "Ship the API, again", forkedFrom: "lead");
        db.AddWorkspace(id: "w-fork", session: "fork", name: "Ship the API, again", creator: "lead");
        db.AddWorkspaceParent(child: "w-fork", parent: "w-lead");
        // Started by a session in another project, which links no workspace, and one that was detached.
        db.AddSession(id: "elsewhere", title: "Document the API");
        db.AddWorkspace(id: "w-elsewhere", session: "elsewhere", project: "p2", name: "Document the API", creator: "lead");
        db.AddSession(id: "detached", title: "Pick sizes");
        db.AddWorkspace(id: "w-detached", session: "detached", name: "Pick sizes");
        // Only the workspace the app shows counts, not an archived one that had a parent.
        db.AddSession(id: "moved", title: "Pick icons");
        db.AddWorkspace(id: "w-moved-old", session: "moved", name: "Pick icons", archived: true);
        db.AddWorkspaceParent(child: "w-moved-old", parent: "w-lead");
        db.AddWorkspace(id: "w-moved", session: "moved", name: "Pick icons", updatedAt: T(seconds: -10));
        // Chats: under the session that coordinates them, or else the one that started them.
        db.AddSession(id: "asked", title: "Ask about icons", type: "general_chat");
        db.AddChatParent(session: "asked", parent: "lead", coordinator: null);
        db.AddSession(id: "handed-over", title: "Ask about logos", type: "general_chat");
        db.AddChatParent(session: "handed-over", parent: "lead", coordinator: "plan");

        var sessions = AppDatabase.Load(path: path).Sessions.ToDictionary(keySelector: session => session.Id);
        Assert.Equal(
            expected: new Dictionary<string, string?>
            {
                ["plan"] = null,
                ["lead"] = null,
                ["linked"] = "lead",
                ["coordinated"] = "plan",
                ["uncoordinated"] = "plan",
                ["fork"] = null,
                ["elsewhere"] = null,
                ["detached"] = null,
                ["moved"] = null,
                ["asked"] = "lead",
                ["handed-over"] = "plan",
            },
            actual: sessions.ToDictionary(keySelector: pair => pair.Key, elementSelector: pair => pair.Value.ParentSessionId));

        // Older app versions record no links: only the chats that started sessions are known.
        db.Exec(statements: """
            DROP TABLE workspace_parent_links; DROP TABLE chat_parent_links;
            ALTER TABLE sessions DROP COLUMN forked_from_session_id;
            """);
        var older = AppDatabase.Load(path: path).Sessions;
        Assert.Equal(expected: 11, actual: older.Count);
        Assert.Equal(
            expected: new Dictionary<string, string> { ["coordinated"] = "plan", ["uncoordinated"] = "plan" },
            actual: older.Where(predicate: session => session.ParentSessionId is not null).ToDictionary(keySelector: session => session.Id, elementSelector: session => session.ParentSessionId!));
    }

    /// Older app versions don't record context usage.
    [Fact]
    public void LoadsSessionsWithoutContextUsage()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("data.db");
        using var db = new TestDatabase(path: path);
        db.CreateAppSchema();
        db.Exec(statements: "DROP TABLE session_context_usage;");
        db.AddSession(id: ChatId, title: "Chat", type: "general_chat");

        var sessions = AppDatabase.Load(path: path).Sessions;
        Assert.Equal(expected: [ChatId], actual: sessions.Select(selector: session => session.Id));
        Assert.Null(@object: sessions[0].ContextUsage);
    }

    [Theory]
    [MemberData(memberName: nameof(Usage))]
    public void ContextUsageIsAShareOfTheWindow(long tokens, long limit, double fraction, int percent)
    {
        var usage = new ContextUsage(Tokens: tokens, Limit: limit);
        Assert.Equal(expected: fraction, actual: usage.Fraction, precision: 9);
        Assert.Equal(expected: percent, actual: usage.Percent);
    }

    /// SQLite removes the write-ahead log when the app closes the database, and a read-only connection can't recreate
    /// it: it's read as it is, and nothing is added to its folder.
    [Fact]
    public void ReadsTheDatabaseWhileTheAppIsClosed()
    {
        using var folder = new TemporaryFolder();
        var data = folder.Combine("Copilot data");
        Directory.CreateDirectory(path: data);
        var path = Path.Combine(path1: data, path2: "data.db");
        using (var db = new TestDatabase(path: path, journalMode: "WAL"))
        {
            db.CreateAppSchema();
            db.AddSession(id: ChatId, title: "Saved", type: "general_chat");
        }
        foreach (var suffix in new[] { "-wal", "-shm" })
        {
            File.Delete(path: path + suffix);
        }

        Assert.Equal(expected: [ChatId], actual: AppDatabase.Load(path: path).Sessions.Select(selector: session => session.Id));
        Assert.Equal(expected: ["data.db"], actual: Directory.GetFiles(path: data).Select(selector: Path.GetFileName));
    }

    [Fact]
    public void AMissingDatabaseIsAnErrorAndIsNotCreated()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("data.db");
        var error = Assert.Throws<AppDatabaseException>(testCode: () => AppDatabase.Load(path: path));
        Assert.Equal(expected: AppDatabaseFailure.Open, actual: error.Failure);
        Assert.StartsWith(expectedStartString: "Could not open Copilot database: ", actualString: error.Message, comparisonType: StringComparison.Ordinal);
        Assert.False(condition: File.Exists(path: path));
    }

    [Fact]
    public void ReadsDatesInAnyStoredForm()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("data.db");
        using var db = new TestDatabase(path: path);
        // An untyped column keeps each value's own storage class.
        db.Exec(statements: """
            CREATE TABLE dates (value);
            INSERT INTO dates VALUES ('2026-10-18T10:00:00.000Z'), (1792317600), (1792317600000), (1792317600.5),
                                     (NULL), ('not a date'), (x'00');
            """);
        using var connection = new SQLiteConnection(path: path);
        var dates = connection.Rows(sql: "SELECT value FROM dates ORDER BY rowid", map: row => row.Date(column: 0));
        Assert.Equal(expected: [T(seconds: 0), T(seconds: 0), T(seconds: 0), T(seconds: 0.5), null, null, null], actual: dates);
    }

    /// Opening the database while the app writes it changes nothing it reads: a read leaves no connection open, so the
    /// app can delete or replace the database's files at any moment, as it does closing it and updating itself.
    [Fact]
    public void LeavesNothingOpenOnceItsRead()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("data.db");
        using (var db = new TestDatabase(path: path, journalMode: "WAL"))
        {
            db.CreateAppSchema();
            db.AddSession(id: ChatId, title: "Saved", type: "general_chat");
            Assert.Single(collection: AppDatabase.Load(path: path).Sessions);
            Assert.Single(collection: AppDatabase.Load(path: path).Sessions);
        }
        // With the writer gone too, nothing holds the files: they can be renamed, as an update would.
        File.Move(sourceFileName: path, destFileName: path + ".moved");
        Assert.True(condition: File.Exists(path: path + ".moved"));
    }
}
