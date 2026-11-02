using BriefBar.Core.Copilot;
using static BriefBar.Core.Tests.Copilot.EventLogReaderTests;
using static BriefBar.Core.Tests.Copilot.Line;
using static BriefBar.Core.Tests.TestTimes;

namespace BriefBar.Core.Tests.Copilot;

public sealed class SessionEngineTests
{
    public static TheoryData<string, string?> WorkspaceNames { get; } = new()
    {
        { "name: Fix the build", "Fix the build" },
        { "id: abc\nname:   spaced out  \nbranch: main", "spaced out" },
        { "name: \"Double quoted\"", "Double quoted" },
        { "name: 'Single quoted'", "Single quoted" },
        { "name: \"unbalanced", "\"unbalanced" },
        { "name: \"\"", null },
        { "name:", null },
        { "  name: nested", null },
        { "branch: main", null },
        // As the CLI writes a prompt that it names a session by: its line breaks, escaped, on one line.
        { "name: \"I tried \\\"make\\\"\\n\\nand it failed\"", "I tried \"make\" and it failed" },
        { "name: 'Robin''s fix'", "Robin's fix" },
        { "name: \"\\n\"", null },
        // A file written on Windows ends its lines with a carriage return too.
        { "id: abc\r\nname: \"On Windows\"\r\nbranch: main\r\n", "On Windows" },
    };

    [Fact]
    public void LoadsSessionsWithTheirLogs()
    {
        using var folder = new TemporaryFolder();
        var paths = new CopilotPaths(root: folder.Path);
        using var db = new TestDatabase(path: paths.Database);
        db.CreateAppSchema();
        db.AddProject(id: "p1", name: "acme-web");
        foreach (var id in new[] { "asking", "finished", "fresh" })
        {
            db.AddSession(id: id, title: id, running: id == "asking", updatedAt: T(seconds: 1));
            db.AddWorkspace(id: "w-" + id, session: id, name: id);
        }
        WriteLog(path: paths.EventsFile(id: "asking"), lines: [UserMessage(at: T(seconds: 1)), ToolStart(name: "ask_user", id: "q", at: T(seconds: 2), arguments: new() { ["question"] = "Ship it?" })]);
        WriteLog(path: paths.EventsFile(id: "finished"), lines: [UserMessage(at: T(seconds: 1)), AssistantMessage(at: T(seconds: 2)), TurnEnd(at: T(seconds: 3))]);
        // A log the app doesn't list, such as a CLI-only session's, is ignored.
        WriteLog(path: paths.EventsFile(id: "orphan"), lines: [UserMessage(at: T(seconds: 1))]);

        var snapshot = SessionEngine.LoadOnce(paths: paths);
        Assert.Null(@object: snapshot.Problem);
        Assert.True(condition: snapshot.ListedByApp);
        Assert.False(condition: snapshot.DatabaseMissing);
        var records = snapshot.Records.ToDictionary(keySelector: record => record.Id);
        Assert.Equal(expected: ["asking", "finished", "fresh"], actual: records.Keys.Order());
        Assert.Null(@object: records["fresh"].Log);

        var phases = records.ToDictionary(keySelector: pair => pair.Key, elementSelector: pair => StatusResolver.Snapshot(record: pair.Value, now: T(seconds: 60)).Phase);
        Assert.Equal(
            expected: new Dictionary<string, DisplayPhase> { ["asking"] = DisplayPhase.NeedsYou, ["finished"] = DisplayPhase.Done, ["fresh"] = DisplayPhase.Idle },
            actual: phases);
    }

    [Fact]
    public void ReportsMissingCopilotData()
    {
        using var folder = new TemporaryFolder();
        var paths = new CopilotPaths(root: folder.Combine("missing"));
        var snapshot = SessionEngine.LoadOnce(paths: paths);
        Assert.Empty(collection: snapshot.Records);
        Assert.Equal(expected: "No Copilot data found at " + paths.Root, actual: snapshot.Problem);
        Assert.False(condition: snapshot.DatabaseMissing);
    }

    [Fact]
    public void FallsBackToSessionFoldersWithoutADatabase()
    {
        using var folder = new TemporaryFolder();
        var paths = new CopilotPaths(root: folder.Path);
        WriteLog(path: paths.EventsFile(id: "recent"), lines: [UserMessage(at: T(seconds: 1))]);
        File.WriteAllText(path: Path.Combine(path1: paths.SessionDirectory(id: "recent"), path2: "workspace.yaml"), contents: "id: recent\nname: \"Fix the build\"\n");
        WriteLog(path: paths.EventsFile(id: "unnamed-session"), lines: [UserMessage(at: T(seconds: 1))]);
        WriteLog(path: paths.EventsFile(id: "old"), lines: [UserMessage(at: T(seconds: 1))]);
        File.SetLastWriteTimeUtc(path: paths.EventsFile(id: "old"), lastWriteTimeUtc: DateTime.UtcNow.AddDays(value: -3));
        Directory.CreateDirectory(path: paths.SessionDirectory(id: "empty"));

        var snapshot = SessionEngine.LoadOnce(paths: paths);
        Assert.Equal(
            expected: new Dictionary<string, string> { ["recent"] = "Fix the build", ["unnamed-session"] = "Session unnamed-" },
            actual: snapshot.Records.ToDictionary(keySelector: record => record.Id, elementSelector: record => record.Meta.Name));
        Assert.All(collection: snapshot.Records, action: record =>
        {
            Assert.Equal(expected: LogPhase.Running, actual: record.Log?.Phase);
            Assert.Null(@object: record.Meta.IsRunning);
        });
        Assert.Contains(expectedSubstring: "Could not open Copilot database", actualString: snapshot.Problem, comparisonType: StringComparison.Ordinal);
        // Every recent folder, not the app's own list.
        Assert.False(condition: snapshot.ListedByApp);
        // As on a PC with only the Copilot CLI, which keeps no database.
        Assert.True(condition: snapshot.DatabaseMissing);
    }

    /// A database that's there but can't be read is a problem whether or not the app is installed.
    [Fact]
    public void TellsAnUnreadableDatabaseFromAMissingOne()
    {
        using var folder = new TemporaryFolder();
        var paths = new CopilotPaths(root: folder.Path);
        File.WriteAllText(path: paths.Database, contents: "not a database");
        var snapshot = SessionEngine.LoadOnce(paths: paths);
        Assert.NotNull(@object: snapshot.Problem);
        Assert.False(condition: snapshot.ListedByApp);
        Assert.False(condition: snapshot.DatabaseMissing);
    }

    /// A database that goes away after a good read, as when the app's data is removed, is missing too.
    [Fact]
    public async Task SaysTheDatabaseIsMissingOnceItsGone()
    {
        using var folder = new TemporaryFolder();
        var paths = new CopilotPaths(root: folder.Path);
        using (var db = new TestDatabase(path: paths.Database))
        {
            db.CreateAppSchema();
            db.AddProject(id: "p1", name: "Pulse");
            db.AddSession(id: "live", title: "Live", updatedAt: DateTimeOffset.UtcNow);
            db.AddWorkspace(id: "w-live", session: "live", name: "Live session");
        }

        var collector = new SnapshotCollector();
        using var engine = new SessionEngine(paths: paths, onChange: collector.Add, metadataThrottle: TimeSpan.FromMilliseconds(value: 50), safetyInterval: TimeSpan.FromHours(value: 1));
        engine.Start();
        var first = await collector.WaitAsync(what: "the first load", predicate: snapshot => First(snapshot: snapshot)?.Meta.Name == "Live session");
        Assert.False(condition: first.DatabaseMissing);

        File.Delete(path: paths.Database);
        engine.Refresh();
        var gone = await collector.WaitAsync(what: "the failed reload", predicate: snapshot => snapshot.Problem is not null);
        Assert.True(condition: gone.DatabaseMissing);
        // Still the app's own list, as it last read it.
        Assert.True(condition: gone.ListedByApp);
    }

    [Fact]
    public async Task KeepsTheLastListWhileTheDatabaseCannotBeRead()
    {
        using var folder = new TemporaryFolder();
        var paths = new CopilotPaths(root: folder.Path);
        using var db = new TestDatabase(path: paths.Database, journalMode: "WAL");
        db.CreateAppSchema();
        db.AddProject(id: "p1", name: "Pulse");
        db.AddSession(id: "live", title: "Live", running: true, updatedAt: DateTimeOffset.UtcNow);
        db.AddWorkspace(id: "w-live", session: "live", name: "Live session");

        var collector = new SnapshotCollector();
        using var engine = new SessionEngine(paths: paths, onChange: collector.Add, metadataThrottle: TimeSpan.FromMilliseconds(value: 50), safetyInterval: TimeSpan.FromHours(value: 1));
        engine.Start();
        await collector.WaitAsync(what: "the first load", predicate: snapshot => First(snapshot: snapshot)?.Meta.IsRunning == true);

        // Neither the main nor the fallback query can read this.
        db.Exec(statements: "ALTER TABLE sessions RENAME TO renamed_sessions;");
        engine.Refresh();
        var stale = await collector.WaitAsync(what: "the failed reload", predicate: snapshot => snapshot.Problem is not null);
        Assert.Equal(expected: ["Live session"], actual: stale.Records.Select(selector: record => record.Meta.Name));
        // Still the app's own list, as it last read it, though its running flags may be out of date by now.
        Assert.True(condition: stale.ListedByApp);
        Assert.Null(@object: stale.Records[0].Meta.IsRunning);
        Assert.EndsWith(expectedEndString: "The list may be out of date.", actualString: stale.Problem, comparisonType: StringComparison.Ordinal);

        db.Exec(statements: "ALTER TABLE renamed_sessions RENAME TO sessions;");
        engine.Refresh();
        var recovered = await collector.WaitAsync(what: "the recovered reload", predicate: snapshot => snapshot.Problem is null);
        Assert.True(condition: recovered.Records[0].Meta.IsRunning);
    }

    /// The point of the whole design: changes are pushed by the watchers, nothing polls. Windows reports the app's writes
    /// to SQLite's write-ahead log while it keeps the log open.
    [Fact]
    public async Task PushesLogAndDatabaseChangesWithoutPolling()
    {
        using var folder = new TemporaryFolder();
        var paths = new CopilotPaths(root: folder.Path);
        var db = new TestDatabase(path: paths.Database, journalMode: "WAL");
        try
        {
            db.CreateAppSchema();
            db.AddProject(id: "p1", name: "Pulse");
            db.AddSession(id: "live", title: "Live", running: true, updatedAt: DateTimeOffset.UtcNow);
            db.AddWorkspace(id: "w-live", session: "live", name: "Live session");
            var log = paths.EventsFile(id: "live");
            WriteLog(path: log, lines:
            [
                UserMessage(at: DateTimeOffset.UtcNow),
                AssistantMessage(at: DateTimeOffset.UtcNow, toolCalls: ["c1"]),
                ToolStart(name: "bash", id: "c1", at: DateTimeOffset.UtcNow, arguments: new() { ["description"] = "Build" }),
            ]);

            var collector = new SnapshotCollector();
            using var engine = new SessionEngine(paths: paths, onChange: collector.Add, metadataThrottle: TimeSpan.FromMilliseconds(value: 50), safetyInterval: TimeSpan.FromHours(value: 1));
            engine.Start();
            await collector.WaitAsync(what: "the first load", predicate: snapshot => First(snapshot: snapshot)?.Log?.Phase == LogPhase.Running);

            AppendLog(path: log, lines: [ToolComplete(id: "c1", at: DateTimeOffset.UtcNow), AssistantMessage(at: DateTimeOffset.UtcNow), TurnEnd(at: DateTimeOffset.UtcNow)]);
            await collector.WaitAsync(what: "the appended log lines", predicate: snapshot => First(snapshot: snapshot)?.Log?.Phase == LogPhase.Finished);

            // The app keeps its database open, so this commit only reaches the write-ahead log.
            db.Exec(statements: "UPDATE sessions SET is_running = 0 WHERE id = 'live';");
            await collector.WaitAsync(what: "the database update", predicate: snapshot => First(snapshot: snapshot)?.Meta.IsRunning == false);

            // The app restarting: closing its connection removes the log, and the next one starts a new log.
            db.Close();
            db = new TestDatabase(path: paths.Database, journalMode: "WAL");
            db.Exec(statements: "UPDATE workspaces SET name = 'Renamed' WHERE id = 'w-live';");
            await collector.WaitAsync(what: "the reopened database", predicate: snapshot => First(snapshot: snapshot)?.Meta.Name == "Renamed");
            db.Exec(statements: "UPDATE workspaces SET branch = 'next' WHERE id = 'w-live';");
            await collector.WaitAsync(what: "a write to the new log", predicate: snapshot => First(snapshot: snapshot)?.Meta.Branch == "next");

            // With nothing changing, nothing is handed over.
            var published = collector.Count;
            await Task.Delay(millisecondsDelay: 1_000, cancellationToken: TestContext.Current.CancellationToken);
            Assert.Equal(expected: published, actual: collector.Count);
        }
        finally
        {
            db.Dispose();
        }
    }

    /// A running engine holds none of the app's files open between reads, so the app can rename or delete any of them,
    /// as it does closing its database or removing a session, which Windows wouldn't let it do otherwise.
    [Fact]
    public async Task NeverHoldsTheAppsFilesOpenBetweenReads()
    {
        using var folder = new TemporaryFolder();
        var paths = new CopilotPaths(root: folder.Path);
        using (var db = new TestDatabase(path: paths.Database))
        {
            db.CreateAppSchema();
            db.AddProject(id: "p1", name: "Pulse");
            db.AddSession(id: "live", title: "Live", running: true, updatedAt: DateTimeOffset.UtcNow);
            db.AddWorkspace(id: "w-live", session: "live", name: "Live session");
        }
        var log = paths.EventsFile(id: "live");
        WriteLog(path: log, lines: [UserMessage(at: DateTimeOffset.UtcNow), ToolStart(name: "bash", id: "c1", at: DateTimeOffset.UtcNow)]);

        var collector = new SnapshotCollector();
        using var engine = new SessionEngine(paths: paths, onChange: collector.Add, metadataThrottle: TimeSpan.FromMilliseconds(value: 50), safetyInterval: TimeSpan.FromHours(value: 1));
        engine.Start();
        await collector.WaitAsync(what: "the first load", predicate: snapshot => First(snapshot: snapshot)?.Log?.Phase == LogPhase.Running);

        File.Move(sourceFileName: paths.Database, destFileName: paths.Database + ".moved");
        File.Move(sourceFileName: paths.Database + ".moved", destFileName: paths.Database);
        File.Delete(path: log);
        Assert.False(condition: File.Exists(path: log));
    }

    [Fact]
    public void LocatesCopilotData()
    {
        var home = Path.Combine(path1: Environment.GetFolderPath(folder: Environment.SpecialFolder.UserProfile), path2: ".copilot");
        Assert.Equal(expected: home, actual: CopilotPaths.Default(environment: new Dictionary<string, string?>()).Root);
        Assert.Equal(expected: home, actual: CopilotPaths.Default(environment: new Dictionary<string, string?> { [CopilotPaths.DirectoryVariable] = "" }).Root);
        using var folder = new TemporaryFolder();
        Assert.Equal(expected: folder.Path, actual: CopilotPaths.Default(environment: new Dictionary<string, string?> { [CopilotPaths.DirectoryVariable] = folder.Path }).Root);

        var paths = new CopilotPaths(root: @"C:\nonexistent\copilot\");
        Assert.Equal(expected: @"C:\nonexistent\copilot", actual: paths.Root);
        Assert.Equal(expected: @"C:\nonexistent\copilot\data.db", actual: paths.Database);
        Assert.Equal(expected: @"C:\nonexistent\copilot\data.db-wal", actual: paths.DatabaseWal);
        Assert.Equal(expected: @"C:\nonexistent\copilot\session-state\abc\events.jsonl", actual: paths.EventsFile(id: "abc"));
    }

    [Theory]
    [MemberData(memberName: nameof(WorkspaceNames))]
    public void ReadsWorkspaceNames(string yaml, string? expected)
    {
        using var folder = new TemporaryFolder();
        File.WriteAllText(path: folder.Combine("workspace.yaml"), contents: yaml);
        Assert.Equal(expected: expected, actual: SessionStateScanner.WorkspaceName(directory: folder.Path));
    }

    [Fact]
    public void NoWorkspaceFileMeansNoName()
    {
        using var folder = new TemporaryFolder();
        Assert.Null(@object: SessionStateScanner.WorkspaceName(directory: folder.Path));
    }

    static SessionRecord? First(EngineSnapshot snapshot) => snapshot.Records.Count > 0 ? snapshot.Records[0] : null;
}
