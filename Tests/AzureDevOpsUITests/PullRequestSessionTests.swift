import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import SQLite3
import Testing
@testable import AzureDevOpsUI

/// The session `pull_request` names for agents: the one BriefBar's Send to Copilot window sends a pull request's work to
/// unless you choose another, only while Send Work to Copilot is on, and nothing when there's none. On the demo's made-up
/// !4088, with made-up sessions in a folder of their own.
@Suite struct PullRequestSessionTests {
    private let now = Date(timeIntervalSince1970: 1_792_317_600)
    private let onBranch = "44444444-4444-4444-8444-444444444444"
    private let opener = "55555555-5555-4555-8555-555555555555"
    private let linked = "66666666-6666-4666-8666-666666666666"
    private let elsewhere = "77777777-7777-4777-8777-777777777777"
    private let task = "11111111-1111-4111-8111-111111111111"

    private struct DatabaseError: Error {
        var message: String
    }

    /// A made-up session in the Copilot app's database: in a project and on a branch, or a chat.
    private struct Session {
        var id: String
        var title: String
        var project: String? = nil
        var branch: String? = nil
        var created: TimeInterval = -30 * 86_400
        var updated: TimeInterval = -300
        var running = false
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BriefBarPullRequestSession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func iso(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: now.addingTimeInterval(offset))
    }

    /// A stand-in for the Copilot app's `data.db`, with what its session list reads.
    private func database(at home: URL, _ sessions: [Session]) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("data.db").path, &handle) == SQLITE_OK else { throw DatabaseError(message: "no database") }
        defer { sqlite3_close(handle) }
        var statements = """
            CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, github_owner TEXT, github_repo TEXT, main_repo_path TEXT);
            CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL, title TEXT, session_type TEXT NOT NULL, mode TEXT,
                is_running INTEGER NOT NULL DEFAULT 0, was_interrupted INTEGER NOT NULL DEFAULT 0, interruption_reason TEXT,
                created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT);
            CREATE TABLE workspaces (id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL, session_id TEXT, branch TEXT NOT NULL,
                name TEXT NOT NULL, creator_session_id TEXT, archived_at TEXT, updated_at TEXT NOT NULL,
                source_pr_repo_full_name TEXT, source_pr_number INTEGER, source_pr_html_url TEXT,
                created_pr_repo_full_name TEXT, created_pr_number INTEGER, created_pr_html_url TEXT);
            CREATE TABLE workspace_pull_request_links (workspace_id TEXT PRIMARY KEY NOT NULL, uri TEXT NOT NULL);
            INSERT INTO projects (id, name) VALUES ('shop', 'shop-web'), ('docs', 'docs');

            """
        for (index, session) in sessions.enumerated() {
            statements += """
                INSERT INTO sessions (id, title, session_type, is_running, created_at, updated_at)
                    VALUES ('\(session.id)', '\(session.title)', '\(session.project == nil ? "general_chat" : "project")',
                        \(session.running ? 1 : 0), '\(iso(session.created))', '\(iso(session.updated))');

                """
            if let project = session.project, let branch = session.branch {
                statements += """
                    INSERT INTO workspaces (id, project_id, session_id, branch, name, updated_at)
                        VALUES ('w\(index)', '\(project)', '\(session.id)', '\(branch)', '\(session.title)', '\(iso(session.updated))');

                    """
            }
        }
        guard sqlite3_exec(handle, statements, nil, nil, nil) == SQLITE_OK else { throw DatabaseError(message: String(cString: sqlite3_errmsg(handle))) }
    }

    /// The reader `--mcp` makes, outside the demo, with the app's settings in memory and its Copilot files in `home`.
    /// - Parameter links: the links you made in Show Links, which is on with them.
    private func reader(home: URL, sending: Bool = true, links: LinkEdits? = nil) -> AzureDevOpsReader {
        let defaults = MemoryDefaults()
        defaults.set(sending, forKey: SettingsKey.copilotEnabled)
        if let links {
            links.save(to: defaults)
            defaults.set(true, forKey: Links.enabledKey)
        }
        return AzureDevOpsReader(demo: false, organizations: ["contoso"], defaults: defaults, appHome: home)
    }

    /// The demo's pull request, made up: !4088 in shop-web, from delivery-estimates into main, created 50 hours before now.
    private func pullRequest(_ number: Int = 4088) async throws -> PRRecord {
        let read = await AzureDevOpsReader(demo: true, organizations: [], defaults: MemoryDefaults()).pullRequests(now: now)
        return try #require(read.records.first { $0.id.number == number })
    }

    /// A task BriefBar sent to Copilot on !4088, as `copilot_tasks` finds it, in a worktree that's there.
    private func sent(_ phase: RunPhase, ended: RunPhase? = nil, worktree: URL) throws -> CopilotTaskEntry {
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let reference = PullRequestReference(
            organization: "contoso", project: "Storefront", repository: "shop-web", id: 4088, sourceBranch: "delivery-estimates"
        )
        let run = CopilotRun(
            id: task, workItem: nil, onPullRequest: reference, action: .fixBuild, options: CopilotModel.standard,
            repository: worktree.deletingLastPathComponent(), worktree: worktree, startedAt: now.addingTimeInterval(-3_600),
            process: DetachedProgram.Handle(pid: 0, startedAt: nil), ended: ended
        )
        return CopilotTaskEntry(
            id: task, workItem: nil, onPullRequest: reference, action: .fixBuild, options: CopilotModel.standard,
            startedAt: run.startedAt, status: RunStatus(phase: phase, since: now.addingTimeInterval(-600)), run: run
        )
    }

    @Test func namesTheAppsSessionOnItsBranch() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home, [
            Session(id: onBranch, title: "Delivery estimates", project: "shop", branch: "delivery-estimates", running: true),
            Session(id: elsewhere, title: "Docs", project: "docs", branch: "delivery-estimates", updated: -60),
        ])
        let record = try await pullRequest()

        let choice = try #require(await reader(home: home).session(for: record, tasks: [], now: now))
        #expect(choice.id == onBranch)
        #expect(choice.reasons == [.onItsBranch])
        #expect(AgentText.session(choice, now: now) == """
            Its session, where BriefBar sends its work unless you choose another: “Delivery estimates”, in the Copilot app, \
            on its branch.
              shop-web · delivery-estimates · working now · active 5m ago · session \(onBranch)
            """)
        // In the pull request's details, under Copilot, before the tasks sent for it.
        let details = AgentText.details(record, item: nil, actions: [.fixBuild], tasks: [], session: choice, now: now)
        let copilot = try #require(details.components(separatedBy: "\n## Copilot\n").last)
        #expect(copilot.hasPrefix("pull_request_prompt has the prompt to: fix_build."))
        #expect(copilot.contains("\nIts session, where BriefBar sends its work unless you choose another: “Delivery estimates”"))
        #expect(!AgentText.details(record, item: nil, actions: [.fixBuild], tasks: [], now: now).contains("Its session"))
    }

    @Test func goesOnWithItsLastTaskUnlessItsStillWorking() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home, [Session(id: onBranch, title: "Delivery estimates", project: "shop", branch: "delivery-estimates")])
        let record = try await pullRequest()
        let worktree = home.appendingPathComponent("copilot-worktrees/shop-web/pr-4088", isDirectory: true)

        // Its log says it finished, though the app hasn't heard yet.
        let finished = try sent(.finished, worktree: worktree)
        let choice = try #require(await reader(home: home).session(for: record, tasks: [finished], now: now))
        #expect(choice.id == task)
        #expect(choice.reasons == [.earlierTask])
        #expect(AgentText.session(choice, now: now) == """
            Its session, where BriefBar sends its work unless you choose another: “Fix the Build: !4088 Show delivery \
            estimates on the product page”, the session of its last task, which BriefBar runs with the Copilot CLI and the \
            Copilot app doesn't have.
              worktree \(worktree.path) · session \(task)
            """)

        // Copilot still works in it: the app's session on its branch, then.
        let working = try sent(.working, worktree: worktree)
        #expect(await reader(home: home).session(for: record, tasks: [working], now: now)?.id == onBranch)
    }

    @Test func namesTheSessionYouLinkedWhileShowLinksIsOn() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home, [Session(id: linked, title: "Plan the estimates")])
        let record = try await pullRequest()
        var edits = LinkEdits()
        try edits.link(.pullRequest(organization: "contoso", number: 4088), #require(ItemRef.session(linked)), at: now)

        // Not while Show Links is off.
        #expect(await reader(home: home).session(for: record, tasks: [], now: now) == nil)
        let choice = try #require(await reader(home: home, links: edits).session(for: record, tasks: [], now: now))
        #expect(choice.id == linked)
        #expect(choice.reasons == [.linkedByYou])
        #expect(AgentText.session(choice, now: now).hasSuffix("“Plan the estimates”, in the Copilot app, linked by you.\n  a chat · active 5m ago · session \(linked)"))
    }

    @Test func lastNamesTheOneThatMentionsItAndWasThereBefore() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        // Created before the pull request was, three days ago, and active since.
        try database(at: home, [Session(id: opener, title: "Estimate delivery dates", created: -3 * 86_400)])
        let state = home.appendingPathComponent("session-state/\(opener)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let link = #"{"data":{"content":"Opened https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/4088"}}"#
        try Data(link.utf8).write(to: state.appendingPathComponent("events.jsonl"))
        let record = try await pullRequest()

        let choice = try #require(await reader(home: home).session(for: record, tasks: [], now: now))
        #expect(choice.id == opener)
        #expect(choice.reasons == [.mentionsIt])
        #expect(AgentText.session(choice, now: now).contains(
            "“Estimate delivery dates”, in the Copilot app, which has a link to it and was there before it was created: it likely opened it."
        ))
    }

    @Test func namesNoneWhileSendingIsOffInTheDemoOrWhenTheresNone() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home, [
            Session(id: onBranch, title: "Delivery estimates", project: "shop", branch: "delivery-estimates"),
            Session(id: elsewhere, title: "Docs", project: "docs", branch: "main"),
        ])
        let record = try await pullRequest()
        #expect(await reader(home: home).session(for: record, tasks: [], now: now)?.id == onBranch)

        // The window reads no sessions while Send Work to Copilot is off, nor in the demo.
        #expect(await reader(home: home, sending: false).session(for: record, tasks: [], now: now) == nil)
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: SettingsKey.copilotEnabled)
        let demo = AzureDevOpsReader(demo: true, organizations: [], defaults: defaults, appHome: home)
        #expect(await demo.session(for: record, tasks: [], now: now) == nil)
        // Nothing goes to Copilot for a pull request that's closed.
        #expect(await reader(home: home).session(for: try await pullRequest(4085), tasks: [], now: now) == nil)

        let none = try folder()
        defer { try? FileManager.default.removeItem(at: none) }
        try database(at: none, [Session(id: elsewhere, title: "Docs", project: "docs", branch: "main")])
        #expect(await reader(home: none).session(for: record, tasks: [], now: now) == nil)
    }
}
