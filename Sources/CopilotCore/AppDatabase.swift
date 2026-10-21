import BriefBarCore
import Foundation
import SQLite3

/// A session as listed by the Copilot app (from its own `data.db`).
public struct SessionMeta: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    /// `project`, `general_chat`, … (as stored by the app).
    public var sessionType: String
    public var mode: String?
    /// The app's own "a turn is in progress" flag (also true while waiting on `ask_user`).
    /// Nil when unknown: the fallback query and the folder scan can't read it.
    public var isRunning: Bool?
    public var wasInterrupted: Bool
    public var interruptionReason: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var projectName: String?
    public var branch: String?
    public var creatorSessionId: String?
    /// The app's workspace for project sessions (its unread markers are keyed by this).
    public var workspaceId: String?
    /// Latest entry in the app's activity feed for this session.
    public var lastActivity: ActivityPreview?
    /// How full the session's context window was when the app last measured it.
    public var contextUsage: ContextUsage?

    public init(
        id: String, name: String, sessionType: String = "project", mode: String? = nil,
        isRunning: Bool? = false, wasInterrupted: Bool = false, interruptionReason: String? = nil,
        createdAt: Date? = nil, updatedAt: Date? = nil, projectName: String? = nil,
        branch: String? = nil, creatorSessionId: String? = nil, workspaceId: String? = nil,
        lastActivity: ActivityPreview? = nil, contextUsage: ContextUsage? = nil
    ) {
        self.id = id
        self.name = name
        self.sessionType = sessionType
        self.mode = mode
        self.isRunning = isRunning
        self.wasInterrupted = wasInterrupted
        self.interruptionReason = interruptionReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.projectName = projectName
        self.branch = branch
        self.creatorSessionId = creatorSessionId
        self.workspaceId = workspaceId
        self.lastActivity = lastActivity
        self.contextUsage = contextUsage
    }

    public var isChat: Bool { sessionType == "general_chat" }
}

/// How much of a session's context window its conversation takes up, in tokens, as the app records it.
public struct ContextUsage: Sendable, Equatable, Codable {
    public var tokens: Int
    public var limit: Int

    public init(tokens: Int, limit: Int) {
        self.tokens = tokens
        self.limit = limit
    }

    /// The share of the window in use, from 0 to 1.
    public var fraction: Double {
        limit > 0 ? min(max(Double(tokens) / Double(limit), 0), 1) : 0
    }

    public var percent: Int { Int((fraction * 100).rounded()) }
}

public enum AppDatabaseError: Error, CustomStringConvertible {
    case open(String, code: Int32)
    case query(String, code: Int32)

    public var description: String {
        switch self {
        case .open(let message, _): return "Could not open Copilot database: \(message)"
        case .query(let message, _): return "Copilot database query failed: \(message)"
        }
    }

    /// SQLite's primary result code.
    var code: Int32 {
        switch self {
        case .open(_, let code), .query(_, let code): return code & 0xFF
        }
    }
}

/// An entry from the app's own activity feed (`agent_idle`, `agent_asking`, `agent_error`, …).
public struct ActivityPreview: Sendable, Equatable, Codable {
    public var kind: String
    public var text: String
    public var at: Date?

    public init(kind: String, text: String, at: Date?) {
        self.kind = kind
        self.text = text
        self.at = at
    }
}

/// What the Copilot app itself shows: which workspaces carry an unread dot, and which session is on screen.
public struct AppViewState: Sendable, Equatable {
    /// Workspace IDs with an unread marker; nil when the app's format couldn't be read.
    public var unreadWorkspaceIds: Set<String>?
    public var unreadUpdatedAt: Date?
    /// The session the app's window is currently showing, if it could be determined.
    public var viewedSessionId: String?

    public init(unreadWorkspaceIds: Set<String>? = nil, unreadUpdatedAt: Date? = nil, viewedSessionId: String? = nil) {
        self.unreadWorkspaceIds = unreadWorkspaceIds
        self.unreadUpdatedAt = unreadUpdatedAt
        self.viewedSessionId = viewedSessionId
    }
}

public struct DatabaseSnapshot: Sendable, Equatable {
    public var sessions: [SessionMeta]
    public var view: AppViewState
}

/// Read-only access to the Copilot app's SQLite database.
public enum AppDatabase {
    /// Sessions the app shows: unarchived chats, plus project sessions with a live workspace.
    /// The workspace name (what the sidebar shows) wins over the session title.
    static let visibleSessionsQuery = """
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
        """

    /// Used if a future app version changes the schema the main query depends on.
    static let fallbackQuery = """
        SELECT id, COALESCE(NULLIF(TRIM(title), ''), ''), session_type, updated_at
        FROM sessions
        WHERE archived_at IS NULL
        ORDER BY updated_at DESC
        LIMIT 60
        """

    static let latestActivityQuery = """
        SELECT a.session_id, a.activity_type, a.preview, a.created_at
        FROM activity_items a
        JOIN (SELECT session_id, MAX(created_at) AS latest
              FROM activity_items WHERE session_id IS NOT NULL GROUP BY session_id) l
          ON l.session_id = a.session_id AND l.latest = a.created_at
        """

    static let viewStateQuery = """
        SELECT key, value, updated_at FROM app_state WHERE key IN ('workspace-unread', 'lastRoutePath')
        """

    /// Each session's latest context-window measurement. SQLite takes the bare columns from the row
    /// with the largest `ts_ms`.
    static let contextUsageQuery = """
        SELECT session_id, current_tokens, token_limit, MAX(ts_ms)
        FROM session_context_usage
        WHERE token_limit > 0
        GROUP BY session_id
        """

    public static func loadVisibleSessions(at url: URL) throws -> [SessionMeta] {
        try load(at: url).sessions
    }

    /// Sessions plus the app's view state. Only the session list is required; the rest is best effort.
    public static func load(at url: URL) throws -> DatabaseSnapshot {
        do {
            return try load(from: open(url))
        } catch let error as AppDatabaseError where error.code == SQLITE_CANTOPEN && isClosedWALDatabase(url) {
            // A read-only connection can't recreate the write-ahead log, which SQLite removes when
            // the app closes the database. Without a log or journal, the file holds every committed
            // change, and the app only writes to it again through a new log, so read it as it is.
            guard let snapshot = try? load(from: open(url, immutable: true)) else { throw error }
            return snapshot
        }
    }

    private static func open(_ url: URL, immutable: Bool = false) throws -> SQLiteConnection {
        do {
            return try SQLiteConnection(readOnly: url, immutable: immutable)
        } catch let error as SQLiteError {
            throw AppDatabaseError.open(error.message, code: error.code)
        }
    }

    private static func isClosedWALDatabase(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: url.path)
            && !fileManager.fileExists(atPath: url.path + "-wal")
            && !fileManager.fileExists(atPath: url.path + "-journal")
    }

    private static func load(from connection: SQLiteConnection) throws -> DatabaseSnapshot {
        do {
            return try read(connection)
        } catch let error as SQLiteError {
            throw AppDatabaseError.query(error.message, code: error.code)
        }
    }

    private static func read(_ connection: SQLiteConnection) throws -> DatabaseSnapshot {
        var sessions = try loadSessions(connection)

        if let latest = try? connection.rows(latestActivityQuery, { row in
            (row.string(0) ?? "", ActivityPreview(kind: row.string(1) ?? "", text: row.string(2) ?? "", at: row.date(3)))
        }) {
            let bySession = Dictionary(latest, uniquingKeysWith: { first, _ in first })
            for index in sessions.indices {
                sessions[index].lastActivity = bySession[sessions[index].id]
            }
        }

        if let usage = try? connection.rows(contextUsageQuery, { row in
            (row.string(0) ?? "", ContextUsage(tokens: row.int(1), limit: row.int(2)))
        }) {
            let bySession = Dictionary(usage, uniquingKeysWith: { first, _ in first })
            for index in sessions.indices {
                sessions[index].contextUsage = bySession[sessions[index].id]
            }
        }

        var view = AppViewState()
        if let entries = try? connection.rows(viewStateQuery, { row in (row.string(0) ?? "", row.string(1) ?? "", row.date(2)) }) {
            for (key, value, updatedAt) in entries {
                switch key {
                case "workspace-unread":
                    if let ids = parseStringArray(value) {
                        view.unreadWorkspaceIds = Set(ids)
                        view.unreadUpdatedAt = updatedAt
                    }
                case "lastRoutePath":
                    view.viewedSessionId = sessionId(inRoute: value, sessions: sessions)
                default:
                    break
                }
            }
        }
        return DatabaseSnapshot(sessions: sessions, view: view)
    }

    private static func loadSessions(_ connection: SQLiteConnection) throws -> [SessionMeta] {
        do {
            return try connection.rows(visibleSessionsQuery) { row in
                SessionMeta(
                    id: row.string(0) ?? "",
                    name: row.string(1) ?? "",
                    sessionType: row.string(2) ?? "",
                    mode: row.string(3),
                    isRunning: row.bool(4),
                    wasInterrupted: row.bool(5),
                    interruptionReason: row.string(6),
                    createdAt: row.date(7),
                    updatedAt: row.date(8),
                    projectName: row.string(9),
                    branch: row.string(10),
                    creatorSessionId: row.string(11),
                    workspaceId: row.string(12)
                )
            }.filter { !$0.id.isEmpty }
        } catch {
            return try connection.rows(fallbackQuery) { row in
                SessionMeta(
                    id: row.string(0) ?? "",
                    name: row.string(1) ?? "",
                    sessionType: row.string(2) ?? "",
                    isRunning: nil,
                    updatedAt: row.date(3)
                )
            }.filter { !$0.id.isEmpty }
        }
    }

    static func parseStringArray(_ json: String) -> [String]? {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }
        let strings = array.compactMap { $0 as? String }
        return strings.count == array.count ? strings : nil
    }

    /// Routes look like `/chats/<session id>`; project routes may use the workspace ID instead,
    /// so any UUID in the path is matched against both.
    static func sessionId(inRoute route: String, sessions: [SessionMeta]) -> String? {
        let pattern = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/
        for match in route.matches(of: pattern) {
            let candidate = String(match.output).lowercased()
            if let session = sessions.first(where: { $0.id.lowercased() == candidate || $0.workspaceId?.lowercased() == candidate }) {
                return session.id
            }
        }
        return nil
    }
}
