using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace BriefBar.Core.Copilot;

/// Read-only access to the Copilot app's SQLite database. Each load opens it, reads, and closes it at once. The Mac's
/// `AppDatabase`, without what only Show Links reads, which isn't on Windows yet.
public static partial class AppDatabase
{
    /// SQLite's `SQLITE_CANTOPEN`.
    const int CantOpen = 14;

    /// SQLite's "database is busy": here, the app opened it as it was read, again and again.
    const int Busy = 5;

    /// How many times the database is read when the app opens or closes it as it's read.
    const int ReadAttempts = 3;

    /// Sessions the app shows: unarchived chats, plus project sessions with a live workspace. The workspace's name, which
    /// the sidebar shows, wins over the session's title.
    internal const string VisibleSessionsQuery = """
        SELECT s.id,
               COALESCE(NULLIF(TRIM(w.name), ''), NULLIF(TRIM(s.title), ''), '') AS name,
               s.session_type, s.mode, s.is_running, s.was_interrupted, s.interruption_reason,
               s.created_at, s.updated_at, p.name, w.branch, w.creator_session_id, w.id
        FROM sessions s
        LEFT JOIN workspaces w ON w.id = (
            SELECT w2.id FROM workspaces w2
            WHERE w2.session_id = s.id
            ORDER BY (w2.archived_at IS NULL) DESC, w2.updated_at DESC
            LIMIT 1)
        LEFT JOIN projects p ON p.id = w.project_id
        WHERE s.archived_at IS NULL
          AND (s.session_type = 'general_chat' OR (w.id IS NOT NULL AND w.archived_at IS NULL))
        """;

    /// Used if a future app version changes the schema the main query depends on.
    internal const string FallbackQuery = """
        SELECT id, COALESCE(NULLIF(TRIM(title), ''), ''), session_type, updated_at
        FROM sessions
        WHERE archived_at IS NULL
        ORDER BY updated_at DESC
        LIMIT 60
        """;

    internal const string LatestActivityQuery = """
        SELECT a.session_id, a.activity_type, a.preview, a.created_at
        FROM activity_items a
        JOIN (SELECT session_id, MAX(created_at) AS latest
              FROM activity_items WHERE session_id IS NOT NULL GROUP BY session_id) l
          ON l.session_id = a.session_id AND l.latest = a.created_at
        """;

    internal const string ViewStateQuery = """
        SELECT key, value, updated_at FROM app_state WHERE key IN ('workspace-unread', 'lastRoutePath')
        """;

    /// Which session coordinates each project session's workspace: the one that created it, while it coordinates it. By
    /// workspace, as a session can have more than one: its own is the one `VisibleSessionsQuery` shows.
    internal const string CoordinatorsQuery = """
        SELECT id, coordinating_creator_session_id
        FROM workspaces
        WHERE archived_at IS NULL AND coordinating_creator_session_id IS NOT NULL
        """;

    /// Which session coordinates each chat that another session started.
    internal const string ChatCoordinatorsQuery = """
        SELECT session_id, coordinating_creator_session_id
        FROM chat_parent_links
        WHERE coordinating_creator_session_id IS NOT NULL
        """;

    /// The session of each workspace's parent workspace: the one in its project that started it.
    internal const string ParentWorkspacesQuery = """
        SELECT link.child_workspace_id, parent.session_id
        FROM workspace_parent_links link
        JOIN workspaces parent ON parent.id = link.parent_workspace_id
        WHERE parent.session_id IS NOT NULL
        """;

    /// The session each forked session was forked from.
    internal const string ForksQuery = """
        SELECT id, forked_from_session_id
        FROM sessions
        WHERE forked_from_session_id IS NOT NULL
        """;

    /// The session that started each chat that another session started.
    internal const string ChatParentsQuery = """
        SELECT session_id, parent_session_id
        FROM chat_parent_links
        WHERE parent_session_id IS NOT NULL
        """;

    /// Each session's latest context-window measurement. SQLite takes the bare columns from the row with the largest
    /// `ts_ms`.
    internal const string ContextUsageQuery = """
        SELECT session_id, current_tokens, token_limit, MAX(ts_ms)
        FROM session_context_usage
        WHERE token_limit > 0
        GROUP BY session_id
        """;

    /// Sessions, plus the app's view state. Only the session list is required; the rest is best effort. Throws
    /// `AppDatabaseException` when the database can't be opened or its sessions can't be read.
    public static DatabaseSnapshot Load(string path) => Load(path: path, afterClosedRead: null);

    /// `Load`, with `afterClosedRead` run after each read of the database as the app closed it: for tests, the app
    /// opening it as it's read.
    internal static DatabaseSnapshot Load(string path, Action? afterClosedRead)
    {
        for (var attempt = 1; ; attempt++)
        {
            var lastAttempt = attempt == ReadAttempts;
            // SQLite removes the write-ahead log when the app closes the database. On Windows, a read-only connection would
            // make a new one, and its shared-memory index, in the app's folder, so it's read as it is, without locks.
            if (ClosedWalStamp(path: path) is { } closed)
            {
                if (ReadClosed(path: path, closed: closed, afterRead: afterClosedRead, lastAttempt: lastAttempt) is { } snapshot)
                {
                    return snapshot;
                }
                continue;
            }
            try
            {
                return LoadFrom(path: path, immutable: false);
            }
            catch (AppDatabaseException error) when (error.Code == CantOpen && !lastAttempt && ClosedWalStamp(path: path) is not null)
            {
                // The app closed it between the two looks, as the Mac finds out: it's read as it is, next time round.
            }
        }
    }

    /// `["a","b"]`'s strings; null for anything but an array of strings.
    internal static List<string>? ParseStringArray(string json)
    {
        try
        {
            if (JsonNode.Parse(json: json) is not JsonArray array)
            {
                return null;
            }
            var strings = new List<string>();
            foreach (var item in array)
            {
                if (item is not JsonValue value || value.GetValueKind() != JsonValueKind.String)
                {
                    return null;
                }
                strings.Add(item: value.GetValue<string>());
            }
            return strings;
        }
        catch (JsonException)
        {
            return null;
        }
        catch (InvalidOperationException)
        {
            // A string .NET can't hold, as half of an emoji.
            return null;
        }
    }

    /// Routes look like `/chats/<session id>`; project routes may use the workspace ID instead, so any UUID in the path
    /// is matched against both.
    internal static string? SessionId(string route, IReadOnlyList<SessionMeta> sessions)
    {
        foreach (Match match in Uuid().Matches(input: route))
        {
            var candidate = match.Value;
            var session = sessions.FirstOrDefault(predicate: session =>
                string.Equals(a: session.Id, b: candidate, comparisonType: StringComparison.OrdinalIgnoreCase)
                || string.Equals(a: session.WorkspaceId, b: candidate, comparisonType: StringComparison.OrdinalIgnoreCase));
            if (session is not null)
            {
                return session.Id;
            }
        }
        return null;
    }

    /// Each session's coordinator, best effort: an app without these tables or columns records none. A chat's is its own
    /// link's; a project session's is that of the workspace it's listed with, so a newer workspace without one has none,
    /// whatever an older one has.
    internal static List<SessionMeta> ReadCoordinators(SQLiteConnection connection, IReadOnlyList<SessionMeta> sessions)
    {
        var byWorkspace = ReadPairs(connection: connection, query: CoordinatorsQuery);
        var byChat = ReadPairs(connection: connection, query: ChatCoordinatorsQuery);
        return sessions.Select(selector: session =>
        {
            var coordinator = session.IsChat
                ? byChat.GetValueOrDefault(key: session.Id)
                : session.WorkspaceId is { } workspace ? byWorkspace.GetValueOrDefault(key: workspace) : null;
            return session with { CoordinatorSessionId = coordinator == session.Id ? null : coordinator };
        }).ToList();
    }

    /// The session the app's sidebar nests each one under, best effort: an app without these tables or columns records
    /// none, and a session it records none for stands on its own.
    ///
    /// A project session is nested under the session of the parent workspace of the workspace it's listed with, the one
    /// in its project that started it, but not under the one it was forked from. Without a parent workspace, it's under
    /// the chat that started it, whether or not that chat coordinates it. A chat is under the session that coordinates
    /// it, or else the one that started it. Detaching a session in the app forgets all of these.
    internal static List<SessionMeta> ReadParents(SQLiteConnection connection, IReadOnlyList<SessionMeta> sessions)
    {
        var forkedFrom = ReadPairs(connection: connection, query: ForksQuery);
        var byWorkspace = ReadPairs(connection: connection, query: ParentWorkspacesQuery);
        var byChat = ReadPairs(connection: connection, query: ChatParentsQuery);
        var chats = sessions.Where(predicate: session => session.IsChat).Select(selector: session => session.Id).ToHashSet(comparer: StringComparer.Ordinal);
        return sessions.Select(selector: session =>
        {
            string? parent;
            if (session.IsChat)
            {
                parent = session.CoordinatorSessionId ?? byChat.GetValueOrDefault(key: session.Id);
            }
            else
            {
                var linked = session.WorkspaceId is { } workspace ? byWorkspace.GetValueOrDefault(key: workspace) : null;
                if (linked == forkedFrom.GetValueOrDefault(key: session.Id))
                {
                    linked = null;
                }
                var creator = session.CoordinatorSessionId ?? session.CreatorSessionId;
                parent = linked ?? (creator is not null && chats.Contains(item: creator) ? creator : null);
            }
            return session with { ParentSessionId = parent == session.Id ? null : parent };
        }).ToList();
    }

    [GeneratedRegex(pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", options: RegexOptions.CultureInvariant)]
    private static partial Regex Uuid();

    /// SQLite's own message, from Microsoft.Data.Sqlite's "SQLite Error 14: 'unable to open database file'.".
    [GeneratedRegex(pattern: "^SQLite Error -?[0-9]+: '(?<message>.*)'\\.?$", options: RegexOptions.CultureInvariant | RegexOptions.Singleline)]
    private static partial Regex NativeError();

    static DatabaseSnapshot LoadFrom(string path, bool immutable)
    {
        SQLiteConnection connection;
        try
        {
            connection = new SQLiteConnection(path: path, immutable: immutable);
        }
        catch (SqliteException error)
        {
            throw new AppDatabaseException(failure: AppDatabaseFailure.Open, detail: Detail(error: error), code: error.SqliteErrorCode, innerException: error);
        }
        using (connection)
        {
            try
            {
                return Read(connection: connection);
            }
            catch (SqliteException error)
            {
                throw new AppDatabaseException(failure: AppDatabaseFailure.Query, detail: Detail(error: error), code: error.SqliteErrorCode, innerException: error);
            }
        }
    }

    /// The database as the app closed it, read without locks. Without a log or journal, the file holds every committed
    /// change, but only while the app leaves it alone: a checkpoint could change it under the read. Null when the app
    /// opened or changed it meanwhile, to read it again, the usual way once the app has it open; on the last attempt,
    /// that throws instead.
    static DatabaseSnapshot? ReadClosed(string path, FileStamp closed, Action? afterRead, bool lastAttempt)
    {
        DatabaseSnapshot? snapshot;
        AppDatabaseException? failure = null;
        try
        {
            snapshot = LoadFrom(path: path, immutable: true);
        }
        catch (AppDatabaseException error) when (ClosedWalStamp(path: path) != closed)
        {
            // A file that changes under the read can look damaged.
            snapshot = null;
            failure = error;
        }
        afterRead?.Invoke();
        if (snapshot is not null && ClosedWalStamp(path: path) == closed)
        {
            return snapshot;
        }
        return lastAttempt
            ? throw new AppDatabaseException(failure: AppDatabaseFailure.Query, detail: "it kept changing as it was read", code: Busy, innerException: failure)
            : null;
    }

    /// The database's stamp while it's in WAL mode, as its header says (bytes 18 and 19 are 2), without its log or a
    /// journal: closed by the app that writes it. Null otherwise. A checkpoint changes it, and needs the log, which stays
    /// until the app closes the database, so an unchanged stamp means no write reached the file between two looks.
    static FileStamp? ClosedWalStamp(string path) =>
        !File.Exists(path: path + "-wal") && !File.Exists(path: path + "-journal")
        && FileStamp.Of(path: path) is { } stamp
        && SharedFile.Read(path: path, start: 18, end: 20) is [2, 2]
            ? stamp
            : null;

    static DatabaseSnapshot Read(SQLiteConnection connection)
    {
        var sessions = LoadSessions(connection: connection);

        if (TryRows(connection: connection, sql: LatestActivityQuery, map: row => (
            Session: row.AsText(column: 0) ?? string.Empty,
            Activity: new ActivityPreview(Kind: row.AsText(column: 1) ?? string.Empty, Text: row.AsText(column: 2) ?? string.Empty, At: row.Date(column: 3))))
            is { } latest)
        {
            var bySession = FirstByKey(pairs: latest.Select(selector: entry => (entry.Session, entry.Activity)));
            sessions = sessions.Select(selector: session => session with { LastActivity = bySession.GetValueOrDefault(key: session.Id) }).ToList();
        }

        if (TryRows(connection: connection, sql: ContextUsageQuery, map: row => (
            Session: row.AsText(column: 0) ?? string.Empty,
            Usage: new ContextUsage(Tokens: row.NumberOrZero(column: 1), Limit: row.NumberOrZero(column: 2))))
            is { } usage)
        {
            var bySession = FirstByKey(pairs: usage.Select(selector: entry => (entry.Session, entry.Usage)));
            sessions = sessions.Select(selector: session => session with { ContextUsage = bySession.GetValueOrDefault(key: session.Id) }).ToList();
        }

        sessions = ReadCoordinators(connection: connection, sessions: sessions);
        sessions = ReadParents(connection: connection, sessions: sessions);

        var view = new AppViewState();
        if (TryRows(connection: connection, sql: ViewStateQuery, map: row => (
            Key: row.AsText(column: 0) ?? string.Empty, Value: row.AsText(column: 1) ?? string.Empty, UpdatedAt: row.Date(column: 2)))
            is { } entries)
        {
            foreach (var (key, value, updatedAt) in entries)
            {
                switch (key)
                {
                    case "workspace-unread" when ParseStringArray(json: value) is { } ids:
                        view = view with { UnreadWorkspaceIds = ids.ToHashSet(comparer: StringComparer.Ordinal), UnreadUpdatedAt = updatedAt };
                        break;
                    case "lastRoutePath":
                        view = view with { ViewedSessionId = SessionId(route: value, sessions: sessions) };
                        break;
                    default:
                        break;
                }
            }
        }
        return new DatabaseSnapshot(Sessions: new ValueList<SessionMeta>(items: sessions), View: view);
    }

    static List<SessionMeta> LoadSessions(SQLiteConnection connection)
    {
        List<SessionMeta> sessions;
        try
        {
            sessions = connection.Rows(sql: VisibleSessionsQuery, map: row => new SessionMeta
            {
                Id = row.AsText(column: 0) ?? string.Empty,
                Name = row.AsText(column: 1) ?? string.Empty,
                SessionType = row.AsText(column: 2) ?? string.Empty,
                Mode = row.AsText(column: 3),
                IsRunning = row.Bool(column: 4),
                WasInterrupted = row.Bool(column: 5),
                InterruptionReason = row.AsText(column: 6),
                CreatedAt = row.Date(column: 7),
                UpdatedAt = row.Date(column: 8),
                ProjectName = row.AsText(column: 9),
                Branch = row.AsText(column: 10),
                CreatorSessionId = row.AsText(column: 11),
                WorkspaceId = row.AsText(column: 12),
            });
        }
        catch (SqliteException)
        {
            // The schema changed: names only, without the running flag, projects or branches.
            sessions = connection.Rows(sql: FallbackQuery, map: row => new SessionMeta
            {
                Id = row.AsText(column: 0) ?? string.Empty,
                Name = row.AsText(column: 1) ?? string.Empty,
                SessionType = row.AsText(column: 2) ?? string.Empty,
                IsRunning = null,
                UpdatedAt = row.Date(column: 3),
            });
        }
        return sessions.Where(predicate: session => session.Id.Length > 0).ToList();
    }

    /// The rows, or null when the query fails, as for a table an older app doesn't have.
    static List<T>? TryRows<T>(SQLiteConnection connection, string sql, Func<SQLiteRow, T> map)
    {
        try
        {
            return connection.Rows(sql: sql, map: map);
        }
        catch (SqliteException)
        {
            return null;
        }
    }

    /// Two columns of names, without empty ones, the first for each key; none when the query fails.
    static Dictionary<string, string> ReadPairs(SQLiteConnection connection, string query)
    {
        var rows = TryRows(connection: connection, sql: query, map: row => (Key: row.AsText(column: 0) ?? string.Empty, Value: row.AsText(column: 1) ?? string.Empty)) ?? [];
        return FirstByKey(pairs: rows.Where(predicate: pair => pair.Key.Length > 0 && pair.Value.Length > 0));
    }

    static Dictionary<string, T> FirstByKey<T>(IEnumerable<(string Key, T Value)> pairs)
    {
        var result = new Dictionary<string, T>(comparer: StringComparer.Ordinal);
        foreach (var (key, value) in pairs)
        {
            result.TryAdd(key: key, value: value);
        }
        return result;
    }

    static string Detail(SqliteException error)
    {
        var match = NativeError().Match(input: error.Message);
        return match.Success ? match.Groups["message"].Value : error.Message;
    }
}
