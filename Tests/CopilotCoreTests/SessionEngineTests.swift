import Foundation
import Synchronization
import Testing
@testable import CopilotCore

@Suite struct SessionEngineTests {
    @Test func loadsSessionsWithTheirLogs() throws {
        try withTemporaryDirectory { root in
            let paths = CopilotPaths(root: root)
            let db = try TestDatabase(at: paths.database)
            defer { db.close() }
            try db.createAppSchema()
            try db.addProject("p1", name: "acme-web")
            for id in ["asking", "finished", "fresh"] {
                try db.addSession(id, title: id.capitalized, running: id == "asking", updatedAt: t(1))
                try db.addWorkspace("w-\(id)", session: id, name: id.capitalized)
            }
            try writeLog([
                Line.userMessage(at: t(1)),
                Line.toolStart("ask_user", id: "q", arguments: ["question": "Ship it?"], at: t(2)),
            ], to: paths.eventsFile("asking"))
            try writeLog(
                [Line.userMessage(at: t(1)), Line.assistantMessage(at: t(2)), Line.turnEnd(at: t(3))],
                to: paths.eventsFile("finished")
            )
            // A log the app doesn't list (e.g. a CLI-only session) is ignored.
            try writeLog([Line.userMessage(at: t(1))], to: paths.eventsFile("orphan"))

            let snapshot = SessionEngine.loadOnce(paths: paths)
            #expect(snapshot.problem == nil)
            #expect(snapshot.listedByApp)
            #expect(!snapshot.databaseMissing)
            // It says whether it read where each session's work goes.
            #expect(!snapshot.readsLinks && SessionEngine.loadOnce(paths: paths, links: true).readsLinks)
            let records = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0) })
            #expect(records.keys.sorted() == ["asking", "finished", "fresh"])
            #expect(try #require(records["fresh"]).log == nil)

            let phases = records.mapValues { StatusResolver.snapshot(for: $0, now: t(60)).phase }
            #expect(phases == ["asking": .needsYou, "finished": .done, "fresh": .idle])
        }
    }

    @Test func reportsMissingCopilotData() throws {
        try withTemporaryDirectory { directory in
            let paths = CopilotPaths(root: directory.appendingPathComponent("missing", isDirectory: true))
            let snapshot = SessionEngine.loadOnce(paths: paths)
            #expect(snapshot.records.isEmpty)
            #expect(snapshot.problem == "No Copilot data found at \(paths.root.path)")
            #expect(!snapshot.databaseMissing)
            // Nothing at all to read where each session's work goes: read, as far as it's anywhere.
            #expect(SessionEngine.loadOnce(paths: paths, links: true).readsLinks)
        }
    }

    @Test func fallsBackToSessionFoldersWithoutADatabase() throws {
        try withTemporaryDirectory { root in
            let paths = CopilotPaths(root: root)
            try writeLog([Line.userMessage(at: t(1))], to: paths.eventsFile("recent"))
            try "id: recent\nname: \"Fix the build\"\n".write(
                to: paths.sessionDirectory("recent").appendingPathComponent("workspace.yaml"),
                atomically: true, encoding: .utf8
            )
            try writeLog([Line.userMessage(at: t(1))], to: paths.eventsFile("unnamed-session"))
            try writeLog([Line.userMessage(at: t(1))], to: paths.eventsFile("old"))
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: paths.eventsFile("old").path
            )
            try FileManager.default.createDirectory(at: paths.sessionDirectory("empty"), withIntermediateDirectories: true)

            let snapshot = SessionEngine.loadOnce(paths: paths)
            let names = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0.meta.name) })
            #expect(names == ["recent": "Fix the build", "unnamed-session": "Session unnamed-"])
            #expect(snapshot.records.allSatisfy { $0.log?.phase == .running && $0.meta.isRunning == nil })
            #expect(snapshot.problem?.contains("Could not open Copilot database") == true)
            // Every recent folder, not the app's own list.
            #expect(!snapshot.listedByApp)
            // As on a Mac with only the Copilot CLI, which keeps no database.
            #expect(snapshot.databaseMissing)
            // Where each session's work goes is read as far as it's anywhere: the folders are all there is.
            #expect(SessionEngine.loadOnce(paths: paths, links: true).readsLinks)
        }
    }

    /// A database that's there but can't be read is a problem whether or not the app is installed.
    @Test func tellsAnUnreadableDatabaseFromAMissingOne() throws {
        try withTemporaryDirectory { root in
            let paths = CopilotPaths(root: root)
            try Data("not a database".utf8).write(to: paths.database)
            let snapshot = SessionEngine.loadOnce(paths: paths)
            #expect(snapshot.problem != nil)
            #expect(!snapshot.listedByApp)
            #expect(!snapshot.databaseMissing)
            // Nor is where each session's work goes read till it can be.
            #expect(!SessionEngine.loadOnce(paths: paths, links: true).readsLinks)
        }
    }

    /// Nor is one that can't be reached missing, though `FileManager.fileExists` says it isn't there.
    @Test func tellsAnUnreachableDatabaseFromAMissingOne() throws {
        try withTemporaryDirectory { directory in
            let paths = CopilotPaths(root: directory.appendingPathComponent("copilot", isDirectory: true))
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            try Data().write(to: paths.database)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: paths.root.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.root.path) }
            #expect(!FileManager.default.fileExists(atPath: paths.database.path))
            let snapshot = SessionEngine.loadOnce(paths: paths)
            #expect(snapshot.problem?.contains("Could not open Copilot database") == true)
            #expect(!snapshot.databaseMissing)
        }
    }

    /// A database that goes away after a good read, as when the app's data is removed, is missing too.
    @Test(.timeLimit(.minutes(5)))
    func saysTheDatabaseIsMissingOnceItsGone() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CopilotPaths(root: root)
        let db = try TestDatabase(at: paths.database)
        try db.createAppSchema()
        try db.addProject("p1", name: "Pulse")
        try db.addSession("live", title: "Live", updatedAt: Date())
        try db.addWorkspace("w-live", session: "live", name: "Live session")
        db.close()

        let collector = SnapshotCollector()
        let engine = SessionEngine(paths: paths, metadataThrottle: 0.05, safetyInterval: 3_600) { collector.add($0) }
        engine.start()
        defer { engine.stop() }
        let first = try await collector.wait("the initial load") { $0.records.first?.meta.name == "Live session" }
        #expect(!first.databaseMissing)

        try FileManager.default.removeItem(at: paths.database)
        engine.refresh()
        let gone = try await collector.wait("the failed reload") { $0.problem != nil }
        #expect(gone.databaseMissing)
        // Still the app's own list, as it last read it.
        #expect(gone.listedByApp)
    }

    @Test(.timeLimit(.minutes(5)))
    func keepsTheLastListWhileTheDatabaseCannotBeRead() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CopilotPaths(root: root)
        let db = try TestDatabase(at: paths.database, journalMode: "WAL")
        defer { db.close() }
        try db.createAppSchema()
        try db.addProject("p1", name: "Pulse")
        try db.addSession("live", title: "Live", running: true, updatedAt: Date())
        try db.addWorkspace("w-live", session: "live", name: "Live session")

        let collector = SnapshotCollector()
        let engine = SessionEngine(paths: paths, metadataThrottle: 0.05, safetyInterval: 3_600) { collector.add($0) }
        engine.start()
        defer { engine.stop() }
        try await collector.wait("the initial load") { $0.records.first?.meta.isRunning == true }

        // Neither the main nor the fallback query can read this.
        try db.exec("ALTER TABLE sessions RENAME TO renamed_sessions;")
        engine.refresh()
        let stale = try await collector.wait("the failed reload") { $0.problem != nil }
        #expect(stale.records.map(\.meta.name) == ["Live session"])
        // Still the app's own list, as it last read it.
        #expect(stale.listedByApp)
        // The last known running flag may be out of date by now.
        #expect(stale.records.first?.meta.isRunning == nil)
        #expect(stale.problem?.hasSuffix("The list may be out of date.") == true)

        try db.exec("ALTER TABLE renamed_sessions RENAME TO sessions;")
        engine.refresh()
        let recovered = try await collector.wait("the recovered reload") { $0.problem == nil }
        #expect(recovered.records.first?.meta.isRunning == true)
    }

    /// The point of the whole design: changes are pushed by FSEvents, nothing polls.
    @Test(.timeLimit(.minutes(5)))
    func pushesLogAndDatabaseChangesWithoutPolling() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CopilotPaths(root: root)
        let db = try TestDatabase(at: paths.database, journalMode: "WAL")
        defer { db.close() }
        try db.createAppSchema()
        try db.addProject("p1", name: "Pulse")
        try db.addSession("live", title: "Live", running: true, updatedAt: Date())
        try db.addWorkspace("w-live", session: "live", name: "Live session")
        let log = paths.eventsFile("live")
        try writeLog([
            Line.userMessage(at: Date()),
            Line.assistantMessage(toolCalls: ["c1"], at: Date()),
            Line.toolStart("bash", id: "c1", arguments: ["description": "Build"], at: Date()),
        ], to: log)

        let collector = SnapshotCollector()
        let engine = SessionEngine(paths: paths, metadataThrottle: 0.05, safetyInterval: 3_600) { collector.add($0) }
        engine.start()
        defer { engine.stop() }

        try await collector.wait("the initial load") { $0.records.first?.log?.phase == .running }

        try appendLog([
            Line.toolComplete(id: "c1", at: Date()), Line.assistantMessage(at: Date()), Line.turnEnd(at: Date()),
        ], to: log)
        try await collector.wait("the appended log lines") { $0.records.first?.log?.phase == .finished }

        // The app keeps its database open, so this commit only reaches the write-ahead log.
        try db.exec("UPDATE sessions SET is_running = 0 WHERE id = 'live';")
        try db.commitSomethingElse()
        try await collector.wait("the database update") { $0.records.first?.meta.isRunning == false }

        // The app restarting: closing its connection removes the log, and the next one starts a new log.
        db.close()
        let reopened = try TestDatabase(at: paths.database, journalMode: "WAL")
        defer { reopened.close() }
        try reopened.exec("UPDATE workspaces SET name = 'Renamed' WHERE id = 'w-live';")
        try reopened.commitSomethingElse()
        try await collector.wait("the reopened database") { $0.records.first?.meta.name == "Renamed" }
        try reopened.exec("UPDATE workspaces SET branch = 'next' WHERE id = 'w-live';")
        try reopened.commitSomethingElse()
        try await collector.wait("a write to the new log") { $0.records.first?.meta.branch == "next" }

        // With nothing changing, nothing is published.
        let published = collector.count
        try await Task.sleep(for: .seconds(1))
        #expect(collector.count == published)
    }

    @Test func readsOnceMoreForACommitItCouldntSeeYet() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CopilotPaths(root: root)
        let db = try TestDatabase(at: paths.database, journalMode: "WAL")
        defer { db.close() }
        try db.createAppSchema()
        try db.addProject("p1", name: "Pulse")
        try db.addSession("live", title: "Live", running: true, updatedAt: Date())
        try db.addWorkspace("w-live", session: "live", name: "Live session")

        let reads = HeldReads<DatabaseSnapshot>()
        let collector = SnapshotCollector()
        // No safety rescan within the test: only the engine's reads after a write can find it.
        let engine = SessionEngine(
            paths: paths, metadataThrottle: 0.05, rereadDelay: 0.1, safetyInterval: 3_600,
            loadDatabase: { url, links in try reads.read { try AppDatabase.load(at: url, links: links) } }
        ) { collector.add($0) }
        engine.start()
        defer { engine.stop() }
        try await collector.wait("the initial load") { $0.records.first?.meta.isRunning == true }

        // The session ends, but the read the app's write brings still finds it running, as when SQLite hasn't let readers
        // see the commit yet.
        reads.hold()
        try db.exec("UPDATE sessions SET is_running = 0 WHERE id = 'live';")
        try await reads.waitForAHeldRead()
        // So does the read the app's next write brings, its last for a while, though readers can see the update by then,
        // however busy the Mac: only a read after it can find the update.
        reads.release()
        try db.commitSomethingElse()
        try await collector.wait("the session ending") { $0.records.first?.meta.isRunning == false }

        // Once more, not over and over.
        try await reads.waitUntilTheyStop()
    }

    @Test func locatesCopilotData() {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot").path
        #expect(CopilotPaths.default(environment: [:]).root.path == home)
        #expect(CopilotPaths.default(environment: ["BRIEFBAR_COPILOT_DIR": ""]).root.path == home)
        #expect(CopilotPaths.default(environment: ["BRIEFBAR_COPILOT_DIR": "~/elsewhere"]).root.path
            == NSString(string: "~/elsewhere").expandingTildeInPath)

        let paths = CopilotPaths(root: URL(fileURLWithPath: "/nonexistent/copilot", isDirectory: true))
        #expect(paths.root.path == "/nonexistent/copilot")
        #expect(paths.database.path == "/nonexistent/copilot/data.db")
        #expect(paths.eventsFile("abc").path == "/nonexistent/copilot/session-state/abc/events.jsonl")
    }

    @Test(arguments: [
        ("name: Fix the build", "Fix the build"),
        ("id: abc\nname:   spaced out  \nbranch: main", "spaced out"),
        ("name: \"Double quoted\"", "Double quoted"),
        ("name: 'Single quoted'", "Single quoted"),
        ("name: \"unbalanced", "\"unbalanced"),
        ("name: \"\"", nil),
        ("name:", nil),
        ("  name: nested", nil),
        ("branch: main", nil),
        // As the CLI writes a prompt that it names a session by: its line breaks, escaped, on one line.
        (#"name: "I tried \"make\"\n\nand it failed""#, #"I tried "make" and it failed"#),
        ("name: 'Robin''s fix'", "Robin's fix"),
        (#"name: "\n""#, nil),
    ] as [(String, String?)])
    func readsWorkspaceNames(_ yaml: String, _ expected: String?) throws {
        try withTemporaryDirectory { directory in
            try yaml.write(to: directory.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
            #expect(SessionStateScanner.workspaceName(in: directory) == expected)
        }
    }

    @Test func noWorkspaceFileMeansNoName() throws {
        try withTemporaryDirectory { directory in
            #expect(SessionStateScanner.workspaceName(in: directory) == nil)
        }
    }

    /// Without the app's database, sessions are found from their folders: not the ones that wrote BriefBar's summaries,
    /// which worked in its own folder.
    @Test func theSessionsThatWroteBriefBarsSummariesArentListed() throws {
        try withTemporaryDirectory { root in
            let paths = CopilotPaths(root: root)
            let summaries = root.appendingPathComponent("Library/Application Support/BriefBar/Copilot/Summaries", isDirectory: true)
            let yours = "1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b01"
            let briefBars = "2e7c3d8f-5a1b-4c9f-8d42-6b3f8e9a7c02"
            for (id, workspace) in [
                (yours, "name: Fix the cart\ncwd: /Users/robin/src/shop\n"),
                (briefBars, "name: BriefBar summary\ncwd: \(summaries.path)/\n"),
            ] {
                try writeLog([Line.sessionStart(at: t(0))], to: paths.eventsFile(id))
                try workspace.write(to: paths.sessionDirectory(id).appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
            }
            let listed = SessionStateScanner.recentSessions(paths: paths, now: Date(), summaries: summaries)
            #expect(listed.map(\.id) == [yours])
            #expect(listed.first?.name == "Fix the cart")
        }
    }
}

private extension TestDatabase {
    /// Commits something the engine doesn't read, as the app goes on doing, so that the engine reads the commit before.
    /// SQLite writes a commit to its write-ahead log before it lets readers see it, and the engine reads
    /// `metadataThrottle` after hearing of that write and once more `rereadDelay` later: a writer held up in between for
    /// longer than both, as on a busy runner, leaves them with nothing new, and with nothing else written, only the
    /// safety rescan, an hour here, reads again. On CI on 2026-11-09, before the engine read once more, an update went
    /// unread for the four minutes the test waited. A commit is written only once the one before it can be read, so the
    /// read this one brings finds that.
    func commitSomethingElse() throws {
        // A commit whatever the value: SQLite writes the database's first page each time.
        try exec("PRAGMA user_version = 1;")
    }
}

/// Stands in for the engine's reads of the database, to hold them up as SQLite does between writing a commit to its
/// write-ahead log, which is what the engine hears of, and letting readers see it: a held read finds what the last read
/// before it did.
private final class HeldReads<Value: Sendable>: Sendable {
    private struct State {
        var last: Value?
        var holding = false
        var releasing = false
        var held = 0
        var reads = 0
    }

    private let state = Mutex(State())

    /// Holds every read from now on.
    func hold() {
        state.withLock { $0.holding = true }
    }

    /// Holds one more read, and none after it.
    func release() {
        state.withLock { $0.releasing = true }
    }

    func read(_ readForReal: () throws -> Value) rethrows -> Value {
        let held: Value? = state.withLock { state in
            state.reads += 1
            guard state.holding, let last = state.last else { return nil }
            state.held += 1
            if state.releasing {
                state.holding = false
                state.releasing = false
            }
            return last
        }
        if let held { return held }
        let value = try readForReal()
        state.withLock { $0.last = value }
        return value
    }

    func waitForAHeldRead() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: waitLimit)
        while state.withLock({ $0.held }) == 0 {
            guard clock.now < deadline else { throw TestError("Timed out waiting for a held read") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Waits until no read was made for half a second, five times the `rereadDelay` the tests give: reads that go on one
    /// after another never leave that long.
    func waitUntilTheyStop() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: waitLimit)
        var reads = state.withLock { $0.reads }
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(500))
            let now = state.withLock { $0.reads }
            if now == reads { return }
            reads = now
        }
        throw TestError("The reads hadn't stopped after \(waitLimit), at \(reads)")
    }
}
