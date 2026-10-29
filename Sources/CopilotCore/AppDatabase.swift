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
    /// The session that coordinates this one: the app tells it when this one waits for you, and it can ask you for it.
    public var coordinatorSessionId: String?
    /// The session the app's sidebar nests this one under, which started it (`AppDatabase.readParents`).
    public var parentSessionId: String?
    /// The app's workspace for project sessions (its unread markers are keyed by this).
    public var workspaceId: String?
    /// Latest entry in the app's activity feed for this session.
    public var lastActivity: ActivityPreview?
    /// How full the session's context window was when the app last measured it.
    public var contextUsage: ContextUsage?
    /// Where its work goes, as the app records it: read only for Show Links.
    public var links: SessionLinks?

    public init(
        id: String, name: String, sessionType: String = "project", mode: String? = nil,
        isRunning: Bool? = false, wasInterrupted: Bool = false, interruptionReason: String? = nil,
        createdAt: Date? = nil, updatedAt: Date? = nil, projectName: String? = nil,
        branch: String? = nil, creatorSessionId: String? = nil, coordinatorSessionId: String? = nil,
        parentSessionId: String? = nil, workspaceId: String? = nil, lastActivity: ActivityPreview? = nil,
        contextUsage: ContextUsage? = nil, links: SessionLinks? = nil
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
        self.coordinatorSessionId = coordinatorSessionId
        self.parentSessionId = parentSessionId
        self.workspaceId = workspaceId
        self.lastActivity = lastActivity
        self.contextUsage = contextUsage
        self.links = links
    }

    public var isChat: Bool { sessionType == "general_chat" }
}

/// Where a session's work goes, as the Copilot app records it: its project's GitHub repository and folder, and the pull
/// requests it started from or opened. BriefBar reads it only for Show Links.
public struct SessionLinks: Sendable, Equatable, Codable {
    /// The GitHub repository of its project, `owner/name`.
    public var gitHubRepository: String?
    /// Its project's folder's name, which is usually its repository's.
    public var folder: String?
    /// The pull requests it started from or opened.
    public var pullRequests: [RecordedPullRequest]

    public init(gitHubRepository: String? = nil, folder: String? = nil, pullRequests: [RecordedPullRequest] = []) {
        self.gitHubRepository = gitHubRepository
        self.folder = folder
        self.pullRequests = pullRequests
    }
}

/// A pull request the app recorded for a session: by its repository and number, its link, or both.
public struct RecordedPullRequest: Sendable, Equatable, Codable {
    public var repository: String?
    public var number: Int?
    public var url: String?

    public init(repository: String?, number: Int?, url: String?) {
        self.repository = repository
        self.number = number
        self.url = url
    }

    /// Which pull request it is: what its link names, or a GitHub pull request by its repository and number.
    public var ref: ItemRef? {
        if let url, let ref = ItemRef.from(link: url), ref.kind.isPullRequest { return ref }
        guard let repository, let number, number > 0 else { return nil }
        return ItemRef.from(link: "https://github.com/\(repository)/pull/\(number)")
    }
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

    /// What each session's workspace records of where its work goes: its project's GitHub repository and folder, and the
    /// pull requests it started from or opened. Only for Show Links.
    static let linksQuery = """
        SELECT w.session_id, p.github_owner, p.github_repo, p.main_repo_path,
               w.source_pr_repo_full_name, w.source_pr_number, w.source_pr_html_url,
               w.created_pr_repo_full_name, w.created_pr_number, w.created_pr_html_url
        FROM workspaces w
        LEFT JOIN projects p ON p.id = w.project_id
        WHERE w.session_id IS NOT NULL AND w.archived_at IS NULL
        """

    /// The pull requests that the app's providers, such as one for another service, link workspaces to. Only for Show
    /// Links.
    static let providerLinksQuery = """
        SELECT w.session_id, l.uri
        FROM workspace_pull_request_links l
        JOIN workspaces w ON w.id = l.workspace_id
        WHERE w.session_id IS NOT NULL AND w.archived_at IS NULL
        """

    static let viewStateQuery = """
        SELECT key, value, updated_at FROM app_state WHERE key IN ('workspace-unread', 'lastRoutePath')
        """

    /// Which session coordinates each project session: the one that created it, while it coordinates it.
    static let coordinatorsQuery = """
        SELECT session_id, coordinating_creator_session_id
        FROM workspaces
        WHERE session_id IS NOT NULL AND archived_at IS NULL AND coordinating_creator_session_id IS NOT NULL
        """

    /// Which session coordinates each chat that another session started.
    static let chatCoordinatorsQuery = """
        SELECT session_id, coordinating_creator_session_id
        FROM chat_parent_links
        WHERE coordinating_creator_session_id IS NOT NULL
        """

    /// The session of each workspace's parent workspace: the one in its project that started it.
    static let parentWorkspacesQuery = """
        SELECT link.child_workspace_id, parent.session_id
        FROM workspace_parent_links link
        JOIN workspaces parent ON parent.id = link.parent_workspace_id
        WHERE parent.session_id IS NOT NULL
        """

    /// The session each forked session was forked from.
    static let forksQuery = """
        SELECT id, forked_from_session_id
        FROM sessions
        WHERE forked_from_session_id IS NOT NULL
        """

    /// The session that started each chat that another session started.
    static let chatParentsQuery = """
        SELECT session_id, parent_session_id
        FROM chat_parent_links
        WHERE parent_session_id IS NOT NULL
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
    /// - Parameter links: also where each session's work goes (`SessionLinks`), for Show Links.
    public static func load(at url: URL, links: Bool = false) throws -> DatabaseSnapshot {
        do {
            return try load(from: open(url), links: links)
        } catch let error as AppDatabaseError where error.code == SQLITE_CANTOPEN && isClosedWALDatabase(url) {
            // A read-only connection can't recreate the write-ahead log, which SQLite removes when
            // the app closes the database. Without a log or journal, the file holds every committed
            // change, and the app only writes to it again through a new log, so read it as it is.
            guard let snapshot = try? load(from: open(url, immutable: true), links: links) else { throw error }
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

    private static func load(from connection: SQLiteConnection, links: Bool) throws -> DatabaseSnapshot {
        do {
            return try read(connection, links: links)
        } catch let error as SQLiteError {
            throw AppDatabaseError.query(error.message, code: error.code)
        }
    }

    private static func read(_ connection: SQLiteConnection, links: Bool) throws -> DatabaseSnapshot {
        var sessions = try loadSessions(connection)
        if links {
            let bySession = readLinks(connection)
            for index in sessions.indices {
                sessions[index].links = bySession[sessions[index].id]
            }
        }

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

        let coordinators = readCoordinators(connection)
        for index in sessions.indices {
            sessions[index].coordinatorSessionId = coordinators[sessions[index].id]
        }

        let parents = readParents(connection, sessions: sessions)
        for index in sessions.indices {
            sessions[index].parentSessionId = parents[sessions[index].id]
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

    /// Each session's links, best effort: an app without these tables or columns records none.
    static func readLinks(_ connection: SQLiteConnection) -> [String: SessionLinks] {
        var bySession: [String: SessionLinks] = [:]
        if let rows = try? connection.rows(linksQuery, { row in
            (row.string(0) ?? "", row.string(1), row.string(2), row.string(3),
             RecordedPullRequest(repository: row.string(4), number: row.int64(5).map { Int($0) }, url: row.string(6)),
             RecordedPullRequest(repository: row.string(7), number: row.int64(8).map { Int($0) }, url: row.string(9)))
        }) {
            for (session, owner, repository, path, source, created) in rows where !session.isEmpty {
                var links = bySession[session] ?? SessionLinks()
                if let owner, let repository, !owner.isEmpty, !repository.isEmpty { links.gitHubRepository = "\(owner)/\(repository)" }
                if let path, !path.isEmpty { links.folder = URL(fileURLWithPath: path).lastPathComponent }
                for recorded in [source, created] where recorded.ref != nil && !links.pullRequests.contains(recorded) {
                    links.pullRequests.append(recorded)
                }
                bySession[session] = links
            }
        }
        if let rows = try? connection.rows(providerLinksQuery, { row in (row.string(0) ?? "", row.string(1)) }) {
            for (session, uri) in rows where !session.isEmpty {
                let recorded = RecordedPullRequest(repository: nil, number: nil, url: uri)
                guard recorded.ref != nil else { continue }
                var links = bySession[session] ?? SessionLinks()
                if !links.pullRequests.contains(recorded) { links.pullRequests.append(recorded) }
                bySession[session] = links
            }
        }
        return bySession
    }

    /// Each session's coordinator, best effort: an app without these tables or columns records none.
    static func readCoordinators(_ connection: SQLiteConnection) -> [String: String] {
        var bySession: [String: String] = [:]
        for query in [coordinatorsQuery, chatCoordinatorsQuery] {
            guard let rows = try? connection.rows(query, { row in (row.string(0) ?? "", row.string(1) ?? "") }) else {
                continue
            }
            for (session, coordinator) in rows where !session.isEmpty && !coordinator.isEmpty && session != coordinator {
                bySession[session] = bySession[session] ?? coordinator
            }
        }
        return bySession
    }

    /// The session the app's sidebar nests each one under, best effort: an app without these tables or columns records
    /// none, and a session it records none for stands on its own.
    ///
    /// A project session is nested under the session of its workspace's parent workspace, the one in its project that
    /// started it, but not under the one it was forked from. Without a parent workspace, it's under the chat that started
    /// it, whether or not that chat coordinates it. A chat is under the session that coordinates it, or else the one that
    /// started it. Detaching a session in the app forgets all of these.
    /// - Parameter sessions: with their workspaces and coordinators, as the app lists them.
    static func readParents(_ connection: SQLiteConnection, sessions: [SessionMeta]) -> [String: String] {
        func pairs(_ query: String) -> [String: String] {
            var byKey: [String: String] = [:]
            guard let rows = try? connection.rows(query, { row in (row.string(0) ?? "", row.string(1) ?? "") }) else {
                return byKey
            }
            for (key, session) in rows where !key.isEmpty && !session.isEmpty && key != session {
                byKey[key] = byKey[key] ?? session
            }
            return byKey
        }
        let forkedFrom = pairs(forksQuery)
        let parentWorkspaces = pairs(parentWorkspacesQuery)
        let chatParents = pairs(chatParentsQuery)
        let chats = Set(sessions.filter(\.isChat).map(\.id))

        var bySession: [String: String] = [:]
        for session in sessions {
            let parent: String?
            if session.isChat {
                parent = session.coordinatorSessionId ?? chatParents[session.id]
            } else {
                var linked = session.workspaceId.flatMap { parentWorkspaces[$0] }
                if linked == forkedFrom[session.id] { linked = nil }
                let creator = session.coordinatorSessionId ?? session.creatorSessionId
                parent = linked ?? creator.flatMap { chats.contains($0) ? $0 : nil }
            }
            if let parent, parent != session.id {
                bySession[session.id] = parent
            }
        }
        return bySession
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
