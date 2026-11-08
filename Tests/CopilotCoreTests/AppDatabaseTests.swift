import Foundation
import Testing
@testable import CopilotCore
import BriefBarCore

@Suite struct AppDatabaseTests {
    static let sessionId = "11111111-1111-4111-8111-111111111111"
    static let workspaceId = "22222222-2222-4222-8222-222222222222"
    static let chatId = "33333333-3333-4333-8333-333333333333"

    @Test(arguments: [
        (#"["a","b"]"#, ["a", "b"]),
        ("[]", []),
        (#"["a",1]"#, nil),
        (#"{"a":1}"#, nil),
        ("not json", nil),
        ("", nil),
    ] as [(String, [String]?)])
    func parsesStringArrays(_ json: String, _ expected: [String]?) {
        #expect(AppDatabase.parseStringArray(json) == expected)
    }

    @Test func findsTheSessionOnScreen() {
        let sessions = [
            SessionMeta(id: Self.sessionId, name: "Project", workspaceId: Self.workspaceId),
            SessionMeta(id: Self.chatId, name: "Chat", sessionType: "general_chat"),
        ]
        func viewed(_ route: String) -> String? {
            AppDatabase.sessionId(inRoute: route, sessions: sessions)
        }
        #expect(viewed("/chats/\(Self.chatId)") == Self.chatId)
        #expect(viewed("/chats/\(Self.chatId.uppercased())") == Self.chatId)
        #expect(viewed("/workspaces/\(Self.workspaceId)/session") == Self.sessionId)
        #expect(viewed("/projects/99999999-9999-4999-8999-999999999999/chats/\(Self.chatId)") == Self.chatId)
        #expect(viewed("/settings") == nil)
        #expect(viewed("") == nil)
    }

    @Test func loadsWhatTheAppShows() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("data.db")
            let db = try TestDatabase(at: url, journalMode: "WAL")
            defer { db.close() }
            try db.createAppSchema()
            try db.addProject("p1", name: "acme-web")

            // A project session: its live workspace's (sidebar) name wins over the session title.
            try db.addSession(Self.sessionId, title: "Session title", mode: "autopilot", running: true, updatedAt: t(10))
            try db.addWorkspace(
                "old-workspace", session: Self.sessionId, name: "Old", branch: "old", archived: true, updatedAt: t(20)
            )
            try db.addWorkspace(
                Self.workspaceId, session: Self.sessionId, name: "  Fix login  ", branch: "fix-login",
                creator: "parent-session", updatedAt: t(5)
            )
            // Chats have no workspace.
            try db.addSession(
                Self.chatId, title: "  Quick question ", type: "general_chat", interrupted: true, reason: "app_quit",
                updatedAt: t(30)
            )
            try db.addSession("untitled-chat", title: nil, type: "general_chat")
            // Not shown by the app.
            try db.addSession("archived", title: "Archived", archived: true)
            try db.addWorkspace("w-archived", session: "archived", name: "Archived")
            try db.addSession("workspace-archived", title: "Gone")
            try db.addWorkspace("w-gone", session: "workspace-archived", name: "Gone", archived: true)
            try db.addSession("no-workspace", title: "Orphan")

            try db.addActivity(session: Self.sessionId, type: "agent_asking", preview: "Older", at: t(1))
            try db.addActivity(session: Self.sessionId, type: "agent_idle", preview: "Latest", at: t(9))
            try db.setAppState("workspace-unread", "[\"\(Self.workspaceId)\"]", at: t(40))
            try db.setAppState("lastRoutePath", "/chats/\(Self.chatId)", at: t(41))

            let snapshot = try AppDatabase.load(at: url)
            let sessions = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0) })
            #expect(sessions.keys.sorted() == [Self.sessionId, Self.chatId, "untitled-chat"].sorted())

            #expect(sessions[Self.sessionId] == SessionMeta(
                id: Self.sessionId, name: "Fix login", sessionType: "project", mode: "autopilot", isRunning: true,
                createdAt: t(-86_400), updatedAt: t(10), projectName: "acme-web", branch: "fix-login",
                creatorSessionId: "parent-session", workspaceId: Self.workspaceId,
                lastActivity: ActivityPreview(kind: "agent_idle", text: "Latest", at: t(9))
            ))
            #expect(sessions[Self.chatId] == SessionMeta(
                id: Self.chatId, name: "Quick question", sessionType: "general_chat", wasInterrupted: true,
                interruptionReason: "app_quit", createdAt: t(-86_400), updatedAt: t(30)
            ))
            #expect(sessions["untitled-chat"]?.name == "")
            #expect(snapshot.view == AppViewState(
                unreadWorkspaceIds: [Self.workspaceId], unreadUpdatedAt: t(40), viewedSessionId: Self.chatId
            ))
        }
    }

    @Test func readsAlongsideTheAppsWriter() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("data.db")
            let db = try TestDatabase(at: url, journalMode: "WAL")
            defer { db.close() }
            try db.createAppSchema()
            try db.addSession(Self.chatId, title: "Committed", type: "general_chat")

            // The app is mid-write: readers must neither wait for nor see the uncommitted row.
            try db.exec("BEGIN IMMEDIATE;")
            try db.addSession("pending", title: "Uncommitted", type: "general_chat")
            var during: DatabaseSnapshot?
            let elapsed = try ContinuousClock().measure { during = try AppDatabase.load(at: url) }
            #expect(during?.sessions.map(\.id) == [Self.chatId])
            #expect(elapsed < .seconds(1))

            try db.exec("COMMIT;")
            #expect(try AppDatabase.load(at: url).sessions.map(\.id).sorted() == [Self.chatId, "pending"].sorted())
        }
    }

    @Test func fallsBackToAMinimalQueryWhenTheSchemaChanges() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("data.db")
            let db = try TestDatabase(at: url)
            defer { db.close() }
            try db.exec("""
                CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT, session_type TEXT, updated_at TEXT, archived_at TEXT);
                INSERT INTO sessions VALUES ('a', '  Alpha ', 'project', \(sql(iso(t(1)))), NULL);
                INSERT INTO sessions VALUES ('b', NULL, 'general_chat', \(sql(iso(t(2)))), NULL);
                INSERT INTO sessions VALUES ('c', 'Archived', 'project', \(sql(iso(t(3)))), \(sql(iso(t(3)))));
                """)

            let snapshot = try AppDatabase.load(at: url)
            #expect(snapshot.sessions == [
                SessionMeta(id: "b", name: "", sessionType: "general_chat", isRunning: nil, updatedAt: t(2)),
                SessionMeta(id: "a", name: "Alpha", sessionType: "project", isRunning: nil, updatedAt: t(1)),
            ])
            #expect(snapshot.view == AppViewState())
        }
    }

    @Test func readsEachSessionsLatestContextUsage() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("data.db")
            let db = try TestDatabase(at: url)
            defer { db.close() }
            try db.createAppSchema()
            try db.addSession(Self.chatId, title: "Chat", type: "general_chat")
            try db.addSession("other-chat", title: "Other", type: "general_chat")
            try db.addSession("unmeasured", title: "Unmeasured", type: "general_chat")
            // The latest measurement counts, whatever order the rows are in. Rows without a limit don't.
            try db.addContextUsage(session: Self.chatId, tokens: 90_000, limit: 200_000, at: t(20))
            try db.addContextUsage(session: Self.chatId, tokens: 30_000, limit: 200_000, at: t(10))
            try db.addContextUsage(session: "other-chat", tokens: 64_000, limit: 128_000, at: t(5))
            try db.addContextUsage(session: "other-chat", tokens: 5_000, limit: 0, at: t(30))

            let sessions = Dictionary(uniqueKeysWithValues: try AppDatabase.load(at: url).sessions.map { ($0.id, $0) })
            #expect(sessions[Self.chatId]?.contextUsage == ContextUsage(tokens: 90_000, limit: 200_000))
            #expect(sessions["other-chat"]?.contextUsage == ContextUsage(tokens: 64_000, limit: 128_000))
            #expect(sessions["unmeasured"]?.contextUsage == nil)
        }
    }

    /// The session that coordinates each one: a project session's workspace records it, and a chat's own link.
    @Test func readsWhichSessionCoordinatesEachOne() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("data.db")
            let db = try TestDatabase(at: url)
            defer { db.close() }
            try db.createAppSchema()
            try db.addProject("p1", name: "acme-web")
            try db.addSession("coordinator", title: "Release 2.5", type: "general_chat")
            try db.addSession("child", title: "Pick colors")
            try db.addWorkspace("w-child", session: "child", name: "Pick colors", creator: "coordinator", coordinator: "coordinator")
            try db.addSession("detached", title: "Pick fonts")
            try db.addWorkspace("w-detached", session: "detached", name: "Pick fonts", creator: "coordinator")
            try db.addSession("chat-child", title: "Ask about icons", type: "general_chat")
            try db.addChatParent(session: "chat-child", parent: "coordinator", coordinator: "coordinator")
            try db.addSession("chat-detached", title: "Ask about sizes", type: "general_chat")
            try db.addChatParent(session: "chat-detached", parent: "coordinator", coordinator: nil)
            // A session with two live workspaces is listed with the newer one, and only its coordinator counts.
            try db.addSession("moved", title: "Pick sizes")
            try db.addWorkspace("w-moved-old", session: "moved", name: "Pick sizes", creator: "coordinator", coordinator: "coordinator", updatedAt: t(1))
            try db.addWorkspace("w-moved-new", session: "moved", name: "Pick sizes", updatedAt: t(2))
            try db.addSession("adopted", title: "Pick icons")
            try db.addWorkspace("w-adopted-old", session: "adopted", name: "Pick icons", updatedAt: t(1))
            try db.addWorkspace("w-adopted-new", session: "adopted", name: "Pick icons", coordinator: "coordinator", updatedAt: t(2))

            let sessions = Dictionary(uniqueKeysWithValues: try AppDatabase.load(at: url).sessions.map { ($0.id, $0) })
            #expect(sessions.mapValues(\.coordinatorSessionId) == [
                "coordinator": nil, "child": "coordinator", "detached": nil, "chat-child": "coordinator", "chat-detached": nil,
                "moved": nil, "adopted": "coordinator",
            ])
            #expect(sessions["detached"]?.creatorSessionId == "coordinator")
            #expect(sessions["moved"]?.workspaceId == "w-moved-new")

            // Older app versions record neither.
            try db.exec("ALTER TABLE workspaces DROP COLUMN coordinating_creator_session_id; DROP TABLE chat_parent_links;")
            let older = try AppDatabase.load(at: url).sessions
            #expect(older.count == 7)
            #expect(older.allSatisfy { $0.coordinatorSessionId == nil })
            #expect(older.first { $0.id == "child" }?.projectName == "acme-web")
        }
    }

    /// The session each one is nested under, as the app's sidebar nests it: a project session under its parent
    /// workspace's session, or else the chat that started it; a chat under the session that coordinates it, or else the
    /// one that started it.
    @Test func readsWhichSessionEachOneIsNestedUnder() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("data.db")
            let db = try TestDatabase(at: url)
            defer { db.close() }
            try db.createAppSchema()
            try db.addProject("p1", name: "acme-web")
            try db.addProject("p2", name: "acme-docs")
            try db.addSession("plan", title: "Release 2.5", type: "general_chat")
            try db.addSession("lead", title: "Ship the API")
            try db.addWorkspace("w-lead", session: "lead", name: "Ship the API")
            // Started by a session in its project: its workspace's parent.
            try db.addSession("linked", title: "Write the changelog")
            try db.addWorkspace("w-linked", session: "linked", name: "Write the changelog", creator: "lead", coordinator: "lead")
            try db.addWorkspaceParent(child: "w-linked", parent: "w-lead")
            // Started by a chat, which has no workspace: whether or not the chat coordinates it.
            try db.addSession("coordinated", title: "Pick colors")
            try db.addWorkspace("w-coordinated", session: "coordinated", name: "Pick colors", creator: "plan", coordinator: "plan")
            try db.addSession("uncoordinated", title: "Pick fonts")
            try db.addWorkspace("w-uncoordinated", session: "uncoordinated", name: "Pick fonts", creator: "plan")
            // A fork links to the session it was forked from, which the sidebar doesn't nest it under.
            try db.addSession("fork", title: "Ship the API, again", forkedFrom: "lead")
            try db.addWorkspace("w-fork", session: "fork", name: "Ship the API, again", creator: "lead")
            try db.addWorkspaceParent(child: "w-fork", parent: "w-lead")
            // Started by a session in another project, which links no workspace, and one that was detached.
            try db.addSession("elsewhere", title: "Document the API")
            try db.addWorkspace("w-elsewhere", session: "elsewhere", project: "p2", name: "Document the API", creator: "lead")
            try db.addSession("detached", title: "Pick sizes")
            try db.addWorkspace("w-detached", session: "detached", name: "Pick sizes")
            // Only the workspace the app shows counts, not an archived one that had a parent.
            try db.addSession("moved", title: "Pick icons")
            try db.addWorkspace("w-moved-old", session: "moved", name: "Pick icons", archived: true)
            try db.addWorkspaceParent(child: "w-moved-old", parent: "w-lead")
            try db.addWorkspace("w-moved", session: "moved", name: "Pick icons", updatedAt: t(-10))
            // Chats: under the session that coordinates them, or else the one that started them.
            try db.addSession("asked", title: "Ask about icons", type: "general_chat")
            try db.addChatParent(session: "asked", parent: "lead", coordinator: nil)
            try db.addSession("handed-over", title: "Ask about logos", type: "general_chat")
            try db.addChatParent(session: "handed-over", parent: "lead", coordinator: "plan")

            let sessions = Dictionary(uniqueKeysWithValues: try AppDatabase.load(at: url).sessions.map { ($0.id, $0) })
            #expect(sessions.mapValues(\.parentSessionId) == [
                "plan": nil, "lead": nil, "linked": "lead", "coordinated": "plan", "uncoordinated": "plan", "fork": nil,
                "elsewhere": nil, "detached": nil, "moved": nil, "asked": "lead", "handed-over": "plan",
            ])
            // What each fork was forked from, for Send to a Fork to confirm the fork it made.
            let forks = try AppDatabase.load(at: url).forks
            #expect(forks?.mapValues(\.original) == ["fork": "lead"])
            #expect(forks?["fork"]?.createdAt != nil)

            // Older app versions record no links: only the chats that started sessions are known.
            try db.exec("""
                DROP TABLE workspace_parent_links; DROP TABLE chat_parent_links;
                ALTER TABLE sessions DROP COLUMN forked_from_session_id;
                """)
            let older = Dictionary(uniqueKeysWithValues: try AppDatabase.load(at: url).sessions.map { ($0.id, $0) })
            #expect(older.count == 11)
            #expect(older.compactMapValues(\.parentSessionId) == ["coordinated": "plan", "uncoordinated": "plan"])
            #expect(try AppDatabase.load(at: url).forks == nil)
        }
    }

    /// Older app versions don't record context usage.
    @Test func loadsSessionsWithoutContextUsage() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("data.db")
            let db = try TestDatabase(at: url)
            defer { db.close() }
            try db.createAppSchema()
            try db.exec("DROP TABLE session_context_usage;")
            try db.addSession(Self.chatId, title: "Chat", type: "general_chat")

            let sessions = try AppDatabase.load(at: url).sessions
            #expect(sessions.map(\.id) == [Self.chatId])
            #expect(sessions.first?.contextUsage == nil)
        }
    }

    @Test(arguments: [
        (0, 200_000, 0.0, 0),
        (50_000, 200_000, 0.25, 25),
        (198_000, 200_000, 0.99, 99),
        (250_000, 200_000, 1.0, 100),
        (-5, 100, 0.0, 0),
        (10, 0, 0.0, 0),
    ] as [(Int, Int, Double, Int)])
    func contextUsageIsAShareOfTheWindow(_ tokens: Int, _ limit: Int, _ fraction: Double, _ percent: Int) {
        let usage = ContextUsage(tokens: tokens, limit: limit)
        #expect(usage.fraction == fraction)
        #expect(usage.percent == percent)
    }

    /// Standard SQLite builds remove the write-ahead log when the app closes the database, and a
    /// read-only connection can't recreate it.
    @Test func readsTheDatabaseWhileTheAppIsClosed() throws {
        try withTemporaryDirectory { directory in
            let folder = directory.appendingPathComponent("Copilot data", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("data.db")
            let db = try TestDatabase(at: url, journalMode: "WAL")
            try db.createAppSchema()
            try db.addSession(Self.chatId, title: "Saved", type: "general_chat")
            db.close()
            // macOS's SQLite keeps an empty log and the index instead; remove them as other builds do.
            for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
                try FileManager.default.removeItem(atPath: url.path + suffix)
            }

            #expect(try AppDatabase.load(at: url).sessions.map(\.id) == [Self.chatId])
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["data.db"])
        }
    }

    /// Read as the app closed it, without locks, the database is only what the app committed while the app leaves it alone:
    /// one that opens it as it's read could change the file under the read. Its log appears, so it's read again, the usual
    /// way.
    @Test func readsAgainTheUsualWayWhenTheAppOpensTheDatabaseAsItsRead() throws {
        try withTemporaryDirectory { directory in
            let url = try Self.closedDatabase(in: directory)
            var app: TestDatabase?
            defer { app?.close() }
            var closedReads = 0
            let snapshot = try AppDatabase.load(at: url, links: false) {
                closedReads += 1
                guard app == nil else { return }
                do {
                    let opened = try TestDatabase(at: url, journalMode: "WAL")
                    try opened.addSession("added", title: "Added", type: "general_chat")
                    app = opened
                } catch {
                    Issue.record(error)
                }
            }
            #expect(closedReads == 1)
            #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))
            #expect(snapshot.sessions.map(\.id).sorted() == [Self.chatId, "added"].sorted())
        }
    }

    /// The app opened the database, wrote to it and closed it again, all as it was read: the file changed under the read,
    /// so it's read again.
    @Test func readsAgainWhenTheAppChangesTheDatabaseAsItsRead() throws {
        try withTemporaryDirectory { directory in
            let url = try Self.closedDatabase(in: directory)
            var closedReads = 0
            let snapshot = try AppDatabase.load(at: url, links: false) {
                closedReads += 1
                if closedReads == 1 { Self.writeAsTheApp(url, id: "added", title: "Added") }
            }
            #expect(closedReads == 2)
            #expect(snapshot.sessions.map(\.id).sorted() == [Self.chatId, "added"].sorted())
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["data.db"])
        }
    }

    /// The app wrote to the database each time it was read: after three reads, BriefBar says so, and the list keeps what
    /// it last read.
    @Test func saysWhenTheDatabaseKeepsChangingAsItsRead() throws {
        try withTemporaryDirectory { directory in
            let url = try Self.closedDatabase(in: directory)
            var closedReads = 0
            do {
                _ = try AppDatabase.load(at: url, links: false) {
                    closedReads += 1
                    // A long title takes new pages, so the file grows each time, however close together the writes.
                    Self.writeAsTheApp(url, id: "added \(closedReads)", title: String(repeating: "x", count: 20_000))
                }
                Issue.record("Expected the database to keep changing as it was read")
            } catch let error as AppDatabaseError {
                #expect(error.description == "Copilot database query failed: it kept changing as it was read")
            }
            #expect(closedReads == 3)
        }
    }

    /// A database in WAL mode with one session, as the app leaves it when it quits, an hour ago: without its log.
    private static func closedDatabase(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("data.db")
        let db = try TestDatabase(at: url, journalMode: "WAL")
        try db.createAppSchema()
        try db.addSession(chatId, title: "Saved", type: "general_chat")
        db.close()
        try removeLogs(of: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: url.path)
        return url
    }

    /// Opens the database, adds a chat and closes it again, as the app does when it starts, writes and quits.
    private static func writeAsTheApp(_ url: URL, id: String, title: String) {
        do {
            let app = try TestDatabase(at: url, journalMode: "WAL")
            try app.addSession(id, title: title, type: "general_chat")
            app.close()
            try removeLogs(of: url)
        } catch {
            Issue.record(error)
        }
    }

    /// Removes the write-ahead log and its index, as the Copilot app's SQLite does when it closes the database. macOS's
    /// keeps an empty log and the index instead.
    private static func removeLogs(of url: URL) throws {
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            try FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    @Test func aMissingDatabaseIsAnErrorAndIsNotCreated() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("data.db")
            #expect(throws: AppDatabaseError.self) { try AppDatabase.load(at: url) }
            #expect(throws: AppDatabaseError.self) { try AppDatabase.turns(at: url) }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// Each session's running flag, by its ID, as `turns(at:)` reads it.
    private static func turns(at url: URL) throws -> [String: Bool?]? {
        try AppDatabase.turns(at: url).map { Dictionary(uniqueKeysWithValues: $0.map { ($0.id, $0.isRunning) }) }
    }

    /// The running flag, read alone: whatever else the app changes of what the session list reads, which leaves `load`
    /// without the flag, it's read as the app keeps it, of the sessions that aren't archived; of every session, when the
    /// app doesn't record which are. Nil once the app doesn't keep the flag as BriefBar reads it, and nil for a session it
    /// doesn't say it for.
    @Test func readsWhichSessionsRunATurnByTheirFlagAlone() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("data.db")
            let db = try TestDatabase(at: url)
            defer { db.close() }
            try db.createAppSchema()
            try db.addSession(Self.sessionId, title: "Working", running: true)
            try db.addSession(Self.chatId, title: "Idle", type: "general_chat")
            try db.addSession("archived", title: "Archived", running: true, archived: true)
            #expect(try Self.turns(at: url) == [Self.sessionId: true, Self.chatId: false])

            // Its workspaces gone, or kept another way: the list goes without the flag, which is read all the same.
            try db.exec("DROP TABLE workspaces;")
            #expect(try AppDatabase.load(at: url).sessions.map(\.isRunning) == [nil, nil])
            #expect(try Self.turns(at: url) == [Self.sessionId: true, Self.chatId: false])

            // An app that doesn't record which sessions are archived, as BriefBar reads it: every session's.
            let unarchived = directory.appendingPathComponent("unarchived.db")
            let other = try TestDatabase(at: unarchived)
            defer { other.close() }
            try other.exec("""
                CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL, is_running INTEGER);
                INSERT INTO sessions (id, is_running) VALUES ('a', 1), ('b', 0);
                """)
            #expect(try Self.turns(at: unarchived) == ["a": true, "b": false])
            // Nor for a session it doesn't say it for.
            try other.exec("INSERT INTO sessions (id, is_running) VALUES ('c', NULL);")
            #expect(try Self.turns(at: unarchived) == ["a": true, "b": false, "c": nil])
            // One that keeps the flag another way.
            try other.exec("ALTER TABLE sessions RENAME COLUMN is_running TO running;")
            #expect(try Self.turns(at: unarchived) == nil)

            // A file that isn't a database: it can't be read.
            let garbled = directory.appendingPathComponent("garbled.db")
            try Data("Not a database".utf8).write(to: garbled)
            #expect(throws: AppDatabaseError.self) { try AppDatabase.turns(at: garbled) }
        }
    }

    /// The running flag of a database as the app closed it is read as `load` reads the rest: as it is, without locks.
    @Test func readsWhichSessionsRunATurnWhileTheAppIsClosed() throws {
        try withTemporaryDirectory { directory in
            let url = try Self.closedDatabase(in: directory)
            var closedReads = 0
            let turns = try AppDatabase.turns(at: url) { closedReads += 1 }
            #expect(turns?.map { $0.id } == [Self.chatId])
            #expect(turns?.map { $0.isRunning } == [false])
            #expect(closedReads == 1)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["data.db"])
        }
    }

    @Test func readsDatesInAnyStoredForm() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("data.db")
            let db = try TestDatabase(at: url)
            defer { db.close() }
            // An untyped column keeps each value's own storage class.
            try db.exec("""
                CREATE TABLE dates (value);
                INSERT INTO dates VALUES ('2026-10-18T10:00:00.000Z'), (1792317600), (1792317600000), (1792317600.5),
                                         (NULL), ('not a date'), (x'00');
                """)
            let connection = try SQLiteConnection(readOnly: url)
            let dates = try connection.rows("SELECT value FROM dates ORDER BY rowid") { $0.date(0) }
            #expect(dates == [t(0), t(0), t(0), t(0.5), nil, nil, nil])
        }
    }
}
