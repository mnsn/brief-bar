using Microsoft.Data.Sqlite;
using static BriefBar.Core.Tests.TestTimes;

namespace BriefBar.Core.Tests.Copilot;

/// A stand-in for the Copilot app's `data.db`, with only the tables and columns BriefBar reads and made-up rows. It
/// writes through its own connection, as the app does while BriefBar reads.
///
/// Tests that write while the engine reads must use WAL, as the app does: with a rollback journal, a write that overlaps
/// a read fails with "database is locked". The Swift tests' `TestDatabase`.
internal sealed class TestDatabase : IDisposable
{
    public const string AppSchema = """
        CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL);
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY NOT NULL, title TEXT, session_type TEXT NOT NULL DEFAULT 'workspace', mode TEXT,
            is_running INTEGER NOT NULL DEFAULT 0, was_interrupted INTEGER NOT NULL DEFAULT 0,
            interruption_reason TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT,
            forked_from_session_id TEXT);
        CREATE TABLE workspaces (
            id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL, session_id TEXT, branch TEXT NOT NULL,
            name TEXT NOT NULL, creator_session_id TEXT, coordinating_creator_session_id TEXT, archived_at TEXT,
            updated_at TEXT NOT NULL);
        CREATE TABLE workspace_parent_links (
            child_workspace_id TEXT PRIMARY KEY NOT NULL, parent_workspace_id TEXT NOT NULL,
            creator_session_id TEXT NOT NULL DEFAULT '');
        CREATE TABLE chat_parent_links (
            session_id TEXT PRIMARY KEY NOT NULL, parent_session_id TEXT, coordinating_creator_session_id TEXT);
        CREATE TABLE activity_items (
            id TEXT PRIMARY KEY NOT NULL, session_id TEXT, activity_type TEXT NOT NULL,
            preview TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL);
        CREATE TABLE app_state (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL, updated_at TEXT NOT NULL);
        CREATE TABLE session_context_usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, ts_ms INTEGER NOT NULL,
            current_tokens INTEGER NOT NULL, token_limit INTEGER NOT NULL);
        """;

    SqliteConnection? connection;

    public TestDatabase(string path, string journalMode = "DELETE")
    {
        connection = new SqliteConnection(connectionString: new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false,
        }.ToString());
        connection.Open();
        Exec(statements: "PRAGMA journal_mode=" + journalMode + ";");
    }

    /// SQL's text for `value`, or NULL.
    public static string Sql(string? value) => value is null ? "NULL" : "'" + value.Replace(oldValue: "'", newValue: "''", comparisonType: StringComparison.Ordinal) + "'";

    /// Closes its connection, as the app does when it quits: SQLite then removes the write-ahead log.
    public void Close()
    {
        connection?.Dispose();
        connection = null;
    }

    public void Dispose() => Close();

    public void Exec(string statements)
    {
        using var command = (connection ?? throw new InvalidOperationException(message: "It's closed.")).CreateCommand();
        command.CommandText = statements;
        command.ExecuteNonQuery();
    }

    public void CreateAppSchema() => Exec(statements: AppSchema);

    public void AddProject(string id, string name) =>
        Exec(statements: $"INSERT INTO projects (id, name) VALUES ({Sql(value: id)}, {Sql(value: name)});");

    public void AddSession(
        string id, string? title, string type = "project", string? mode = null, bool running = false, bool interrupted = false,
        string? reason = null, DateTimeOffset? updatedAt = null, bool archived = false, string? forkedFrom = null)
    {
        var updated = updatedAt ?? T(seconds: 0);
        Exec(statements: $"""
            INSERT INTO sessions (id, title, session_type, mode, is_running, was_interrupted, interruption_reason,
                                  created_at, updated_at, archived_at, forked_from_session_id)
            VALUES ({Sql(value: id)}, {Sql(value: title)}, {Sql(value: type)}, {Sql(value: mode)}, {(running ? 1 : 0)}, {(interrupted ? 1 : 0)},
                    {Sql(value: reason)}, {Sql(value: Iso(date: T(seconds: -86_400)))}, {Sql(value: Iso(date: updated))},
                    {(archived ? Sql(value: Iso(date: updated)) : "NULL")}, {Sql(value: forkedFrom)});
            """);
    }

    public void AddWorkspace(
        string id, string session, string name, string project = "p1", string branch = "main", string? creator = null,
        string? coordinator = null, bool archived = false, DateTimeOffset? updatedAt = null)
    {
        var updated = updatedAt ?? T(seconds: 0);
        Exec(statements: $"""
            INSERT INTO workspaces (id, project_id, session_id, branch, name, creator_session_id,
                                    coordinating_creator_session_id, archived_at, updated_at)
            VALUES ({Sql(value: id)}, {Sql(value: project)}, {Sql(value: session)}, {Sql(value: branch)}, {Sql(value: name)}, {Sql(value: creator)},
                    {Sql(value: coordinator)}, {(archived ? Sql(value: Iso(date: updated)) : "NULL")}, {Sql(value: Iso(date: updated))});
            """);
    }

    /// A chat that another session started, and the session that coordinates it, if any.
    public void AddChatParent(string session, string parent, string? coordinator) => Exec(statements: $"""
        INSERT INTO chat_parent_links (session_id, parent_session_id, coordinating_creator_session_id)
        VALUES ({Sql(value: session)}, {Sql(value: parent)}, {Sql(value: coordinator)});
        """);

    /// A workspace that a session in another workspace of its project started.
    public void AddWorkspaceParent(string child, string parent) => Exec(statements: $"""
        INSERT INTO workspace_parent_links (child_workspace_id, parent_workspace_id)
        VALUES ({Sql(value: child)}, {Sql(value: parent)});
        """);

    public void AddActivity(string session, string type, string preview, DateTimeOffset at) => Exec(statements: $"""
        INSERT INTO activity_items (id, session_id, activity_type, preview, created_at)
        VALUES ({Sql(value: Guid.NewGuid().ToString())}, {Sql(value: session)}, {Sql(value: type)}, {Sql(value: preview)}, {Sql(value: Iso(date: at))});
        """);

    public void SetAppState(string key, string value, DateTimeOffset at) => Exec(statements: $"""
        INSERT OR REPLACE INTO app_state (key, value, updated_at) VALUES ({Sql(value: key)}, {Sql(value: value)}, {Sql(value: Iso(date: at))});
        """);

    public void AddContextUsage(string session, long tokens, long limit, DateTimeOffset at) => Exec(statements: $"""
        INSERT INTO session_context_usage (session_id, ts_ms, current_tokens, token_limit)
        VALUES ({Sql(value: session)}, {at.ToUnixTimeMilliseconds()}, {tokens}, {limit});
        """);
}
