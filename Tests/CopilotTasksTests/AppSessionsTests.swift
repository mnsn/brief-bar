import BriefBarCore
import Foundation
import SQLite3
import Testing
@testable import CopilotTasks

/// The Copilot app's sessions that a task can go to instead of a new one: which there are, from the app's database; where
/// each works; which the app has open; and which mention a pull request or a work item in their logs.
@Suite struct AppSessionsTests {
    private let opener = "0b6c1f44-6a1e-4c55-9d0e-3f0a6f1c2a01"
    private let chat = "5d2e8a90-1f3b-4e7c-8a26-7b9c0d4e5f02"
    private let archived = "9a4f2b17-c3d8-4e61-b5a0-2e8d7c6b4a03"

    // MARK: Mentions

    private let pullRequest = SessionMentions.Target.pullRequest(organization: "Contoso", number: 4071)

    private func log(_ text: String, in folder: URL) throws -> URL {
        let file = folder.appendingPathComponent("events-\(UUID().uuidString).jsonl")
        try Data(text.utf8).write(to: file)
        return file
    }

    @Test func findsALinkToThePullRequest() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = try log(#"{"type":"tool.execution_complete","data":{"result":"Created https://dev.azure.com/contoso/Storefront/_git/checkout/pullrequest/4071"}}"# + "\n", in: folder)
        #expect(SessionMentions.mentions(pullRequest, in: page))
        // The REST API's link, as Azure DevOps' tools return it, with the organization farther back.
        let api = try log(#"{"url":"https://dev.azure.com/CONTOSO/\#(UUID().uuidString)/_apis/git/repositories/\#(UUID().uuidString)/pullRequests/4071"}"#, in: folder)
        #expect(SessionMentions.mentions(pullRequest, in: api))
        // An organization's own host.
        let host = try log("See https://contoso.visualstudio.com/Storefront/_git/checkout/pullrequest/4071.", in: folder)
        #expect(SessionMentions.mentions(pullRequest, in: host))
        // A path whatever its case, as Azure DevOps takes them and RunTranscript reads them.
        for route in ["pullRequest", "PullRequest", "PULLREQUESTS", "pullrequests"] {
            let cased = try log("https://dev.azure.com/contoso/Storefront/_git/checkout/\(route)/4071", in: folder)
            #expect(SessionMentions.mentions(pullRequest, in: cased, chunkSize: 16), "\(route)")
        }
    }

    @Test func doesNotMistakeAnotherNumberOrOrganization() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let longer = try log("https://dev.azure.com/contoso/Storefront/_git/checkout/pullrequest/40712\n", in: folder)
        #expect(!SessionMentions.mentions(pullRequest, in: longer))
        let elsewhere = try log("https://dev.azure.com/fabrikam/Storefront/_git/checkout/pullrequest/4071\n", in: folder)
        #expect(!SessionMentions.mentions(pullRequest, in: elsewhere))
        let bare = try log("I fixed !4071 and pull request 4071.\n", in: folder)
        #expect(!SessionMentions.mentions(pullRequest, in: bare))
        #expect(!SessionMentions.mentions(pullRequest, in: folder.appendingPathComponent("missing.jsonl")))
    }

    /// The organization is the link's own: its path's first segment on dev.azure.com, or its host's first part, not a
    /// name that only contains it, nor the name somewhere before another organization's link.
    @Test func takesTheOrganizationFromTheLinkItself() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mentioned: [(String, Bool)] = [
            ("https://dev.azure.com/notcontoso/Storefront/_git/checkout/pullrequest/4071", false),
            ("https://dev.azure.com/contosoltd/Storefront/_git/checkout/pullrequest/4071", false),
            ("contoso asked about https://dev.azure.com/fabrikam/Storefront/_git/checkout/pullrequest/4071", false),
            (#"{"org":"contoso","url":"https://dev.azure.com/fabrikam/Storefront/_git/checkout/pullrequest/4071"}"#, false),
            ("https://notcontoso.visualstudio.com/Storefront/_git/checkout/pullrequest/4071", false),
            ("https://contoso.visualstudio.com.example.com/Storefront/_git/checkout/pullrequest/4071", false),
            ("https://example.com/contoso/Storefront/_git/checkout/pullrequest/4071", false),
            // Not a link at all: no scheme, or broken by a space.
            ("dev.azure.com/contoso/Storefront/_git/checkout/pullrequest/4071", false),
            ("https://dev.azure.com/contoso/Storefront/_git/checkout /pullrequest/4071", false),
            ("https://Dev.Azure.com/CONTOSO/Storefront/_git/checkout/pullrequest/4071", true),
            ("https://contoso@dev.azure.com/contoso/Storefront/_git/checkout/pullrequest/4071", true),
            ("https://fabrikam@dev.azure.com/contoso/Storefront/_git/checkout/pullrequest/4071", true),
            ("http://contoso.visualstudio.com/DefaultCollection/Storefront/_git/checkout/pullrequest/4071", true),
            ("[!4071](https://dev.azure.com/contoso/Storefront/_git/checkout/pullrequest/4071)", true),
            // The same number in another organization first, then this one's.
            ("https://dev.azure.com/fabrikam/x/_git/y/pullrequest/4071 and https://dev.azure.com/contoso/x/_git/y/pullrequest/4071", true),
        ]
        for (text, expected) in mentioned {
            #expect(SessionMentions.mentions(pullRequest, in: try log(text, in: folder)) == expected, "\(text)")
        }
    }

    /// A log is read in chunks: a link across two of them, or at the very end, still counts.
    @Test func findsALinkAcrossChunksAndAtTheEnd() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let padding = String(repeating: "x", count: 5_000)
        let link = "https://dev.azure.com/contoso/Storefront/_git/checkout/pullrequest/4071"
        let across = try log(padding + link + "\n" + padding, in: folder)
        for size in [16, 333, 1_024, 4_096] {
            #expect(SessionMentions.mentions(pullRequest, in: across, chunkSize: size), "\(size)")
        }
        let atTheEnd = try log(padding + link, in: folder)
        #expect(SessionMentions.mentions(pullRequest, in: atTheEnd, chunkSize: 64))
        let cutShort = try log(padding + link + "9", in: folder)
        #expect(!SessionMentions.mentions(pullRequest, in: cutShort, chunkSize: 64))
    }

    @Test func findsAWorkItemByItsLinks() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = SessionMentions.Target.workItem(organization: "contoso", id: 4217)
        let page = try log("https://dev.azure.com/contoso/Storefront/_workitems/edit/4217/", in: folder)
        #expect(SessionMentions.mentions(item, in: page))
        let api = try log(#""url":"https://dev.azure.com/contoso/_apis/wit/workItems/4217""#, in: folder)
        #expect(SessionMentions.mentions(item, in: api))
        let cased = try log("https://dev.azure.com/contoso/Storefront/_workItems/Edit/4217", in: folder)
        #expect(SessionMentions.mentions(item, in: cased))
        #expect(!SessionMentions.mentions(pullRequest, in: page))
    }

    /// BriefBar may have Full Disk Access: a log that's a symbolic link is never followed.
    @Test func doesNotFollowASymbolicLink() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = try log("https://dev.azure.com/contoso/Storefront/_git/checkout/pullrequest/4071", in: folder)
        let link = folder.appendingPathComponent("events.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(!SessionMentions.mentions(pullRequest, in: link))
    }

    /// BriefBar may have Full Disk Access: a session's folder that's a symbolic link, a log that's one, or a `session-state`
    /// that's one, leads nowhere, so neither the search nor finding where a session works reads outside the app's own
    /// sessions. The app's folder itself may be one, as `~/.copilot` can.
    @Test func readsOnlyTheAppsOwnSessionFolders() throws {
        let home = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer { for folder in [home, outside] { try? FileManager.default.removeItem(at: folder) } }
        let text = "https://dev.azure.com/contoso/Storefront/_git/checkout/pullrequest/4071"
        let sessions = home.appendingPathComponent("session-state", isDirectory: true)
        let own = sessions.appendingPathComponent(opener, isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: own.appendingPathComponent("events.jsonl"))
        try Data("cwd: \(outside.path)\n".utf8).write(to: own.appendingPathComponent("workspace.yaml"))
        #expect(SessionMentions.mentions(pullRequest, inSession: opener, home: home))
        #expect(AppSessions.folder(of: opener, home: home)?.path == outside.path)

        // A session's folder that's a link to one elsewhere, with a log and a workspace that would say as much.
        try Data(text.utf8).write(to: outside.appendingPathComponent("events.jsonl"))
        try Data("cwd: \(outside.path)\n".utf8).write(to: outside.appendingPathComponent("workspace.yaml"))
        try FileManager.default.createSymbolicLink(at: sessions.appendingPathComponent(chat), withDestinationURL: outside)
        #expect(!SessionMentions.mentions(pullRequest, inSession: chat, home: home))
        #expect(AppSessions.folder(of: chat, home: home) == nil)

        // A log that's a link to one elsewhere.
        let linked = sessions.appendingPathComponent(archived, isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("events.jsonl"), withDestinationURL: outside.appendingPathComponent("events.jsonl"))
        #expect(!SessionMentions.mentions(pullRequest, inSession: archived, home: home))

        // Nor an ID that isn't a session's, nor a path that steps out.
        #expect(!SessionMentions.mentions(pullRequest, inSession: "../\(opener)", home: home))
        #expect(LocalFile.openFile(below: home, ["session-state", "..", "session-state", opener, "events.jsonl"]) == -1)

        // The app's folder may be a link; a `session-state` in it that's one leads nowhere.
        let alias = outside.appendingPathComponent("copilot-home")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)
        #expect(SessionMentions.mentions(pullRequest, inSession: opener, home: alias))
        let elsewhere = outside.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: elsewhere.appendingPathComponent("session-state"), withDestinationURL: sessions)
        #expect(!SessionMentions.mentions(pullRequest, inSession: opener, home: elsewhere))
        #expect(AppSessions.folder(of: opener, home: elsewhere) == nil)
    }

    // MARK: The app's sessions

    /// A stand-in for the app's `data.db`, with what the session list and its links read.
    private func database(at home: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("data.db").path, &handle) == SQLITE_OK else { throw TestError("no database") }
        defer { sqlite3_close(handle) }
        let statements = """
            CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, github_owner TEXT, github_repo TEXT, main_repo_path TEXT);
            CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL, title TEXT, session_type TEXT NOT NULL, mode TEXT,
                is_running INTEGER NOT NULL DEFAULT 0, was_interrupted INTEGER NOT NULL DEFAULT 0, interruption_reason TEXT,
                created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT);
            CREATE TABLE workspaces (id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL, session_id TEXT, branch TEXT NOT NULL,
                name TEXT NOT NULL, creator_session_id TEXT, archived_at TEXT, updated_at TEXT NOT NULL,
                source_pr_repo_full_name TEXT, source_pr_number INTEGER, source_pr_html_url TEXT,
                created_pr_repo_full_name TEXT, created_pr_number INTEGER, created_pr_html_url TEXT);
            CREATE TABLE workspace_pull_request_links (workspace_id TEXT PRIMARY KEY NOT NULL, uri TEXT NOT NULL);
            INSERT INTO projects (id, name, main_repo_path) VALUES ('p1', 'checkout', '/Users/robin/dev/checkout');
            INSERT INTO sessions (id, title, session_type, is_running, created_at, updated_at)
                VALUES ('\(opener)', 'Fix the checkout total', 'project', 1, '2026-10-20T09:00:00.000Z', '2026-10-27T10:00:00.000Z');
            INSERT INTO workspaces (id, project_id, session_id, branch, name, updated_at)
                VALUES ('w1', 'p1', '\(opener)', 'users/robin/fix-total', 'Fix the total', '2026-10-27T10:00:00.000Z');
            INSERT INTO workspace_pull_request_links (workspace_id, uri)
                VALUES ('w1', 'https://dev.azure.com/contoso/Storefront/_git/checkout/pullrequest/4071');
            INSERT INTO sessions (id, title, session_type, created_at, updated_at)
                VALUES ('\(chat)', 'Plan the release', 'general_chat', '2026-10-21T09:00:00.000Z', '2026-10-28T10:00:00.000Z');
            INSERT INTO sessions (id, title, session_type, created_at, updated_at, archived_at)
                VALUES ('\(archived)', 'Old work', 'general_chat', '2026-10-01T09:00:00.000Z', '2026-10-02T10:00:00.000Z', '2026-10-03T10:00:00.000Z');
            INSERT INTO sessions (id, title, session_type, created_at, updated_at)
                VALUES ('../../not-a-session', 'Odd', 'general_chat', '2026-10-21T09:00:00.000Z', '2026-10-28T11:00:00.000Z');
            """
        guard sqlite3_exec(handle, statements, nil, nil, nil) == SQLITE_OK else {
            throw TestError(String(cString: sqlite3_errmsg(handle)))
        }
    }

    @Test func listsTheAppsSessionsWithTheirBranchesAndPullRequests() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home)
        let sessions = try AppSessions.load(home: home)
        // The newest first; not an archived one, nor one whose ID isn't a session's.
        #expect(sessions.map(\.id) == [chat, opener])
        let session = try #require(sessions.last)
        #expect(session.name == "Fix the total")
        #expect(session.projectName == "checkout")
        #expect(session.branch == "users/robin/fix-total")
        #expect(session.folder == "checkout")
        #expect(session.pullRequests == [.pullRequest(organization: "contoso", number: 4071)])
        #expect(session.isRunning)
        #expect(!session.isChat)
        let hint = try #require(session.branchHint)
        #expect(BranchLinks.matches(session: hint, pullRequest: BranchHint(branch: "refs/heads/users/robin/fix-total", target: "main", repositories: ["checkout"])))
        #expect(sessions.first?.isChat == true)
        #expect(sessions.first?.branchHint == nil)
        #expect(throws: (any Error).self) { try AppSessions.load(home: home.appendingPathComponent("nowhere")) }
    }

    @Test func findsTheFolderASessionWorksInWithoutFollowingLinks() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let worktree = home.appendingPathComponent("copilot-worktrees/checkout/fix-total", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let state = home.appendingPathComponent("session-state/\(opener)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("id: \(opener)\ncwd: \(worktree.path)\nbranch: users/robin/fix-total\n".utf8).write(to: state.appendingPathComponent("workspace.yaml"))
        #expect(AppSessions.folder(of: opener, home: home)?.path == worktree.path)
        #expect(AppSessions.events(of: opener, home: home)?.pathComponents.suffix(3) == ["session-state", opener, "events.jsonl"])
        #expect(AppSessions.folder(of: "../\(opener)", home: home) == nil)
        #expect(AppSessions.events(of: opener.uppercased(), home: home) == nil)

        // A folder that isn't there anymore, and a workspace that's a symbolic link, say nothing.
        let other = home.appendingPathComponent("session-state/\(chat)", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("cwd: \(home.path)/gone\n".utf8).write(to: other.appendingPathComponent("workspace.yaml"))
        #expect(AppSessions.folder(of: chat, home: home) == nil)
        try FileManager.default.removeItem(at: other.appendingPathComponent("workspace.yaml"))
        try FileManager.default.createSymbolicLink(at: other.appendingPathComponent("workspace.yaml"), withDestinationURL: state.appendingPathComponent("workspace.yaml"))
        #expect(AppSessions.folder(of: chat, home: home) == nil)

        // Open in the app while a running program holds its lock.
        #expect(!AppSessions.isOpen(opener, home: home))
        try Data().write(to: state.appendingPathComponent("inuse.\(getpid()).lock"))
        #expect(AppSessions.isOpen(opener, home: home))
    }
}
