import BriefBarCore
import BriefBarUI
import Foundation
import SQLite3
import Testing
@testable import CopilotCore
@testable import CopilotUI

/// `--mcp`'s Copilot sessions, as agents read them.
@Suite struct CopilotAgentTests {
    private func session(
        _ id: String, name: String = "Add dark mode", project: String? = "shop-web", branch: String? = "dark-mode", isChat: Bool = false,
        phase: DisplayPhase = .needsYou, reason: StatusReason = .question, detail: String? = nil, choices: [String] = [], since: Date?
    ) -> SessionSnapshot {
        SessionSnapshot(
            id: id, name: name, projectName: project, branch: branch, isChat: isChat, mode: nil, phase: phase, reason: reason,
            headline: reason.headline, detail: detail, choices: choices, since: since
        )
    }

    /// A session whose question its coordinator relays waits on you there, and says where you answer it.
    @Test func aRelayedQuestionWaitsOnYouWhereItsAsked() throws {
        let worker = "0b6c1f44-6a1e-4c55-9d0e-3f0a6f1c2a01"
        let coordinator = "a3d9c5e1-7b2f-4e84-9c16-5f8e2d0b7a11"
        var relayed = session(worker, name: "Add dark mode to settings", phase: .running, reason: .relayed, since: Date())
        relayed.answerIn = RelatedSession(id: coordinator, name: "Roll out dark mode")
        let ref = try #require(ItemRef.session(worker))
        let item = CopilotAgent.item(CopilotAgent.Linked(session: relayed, ref: ref, links: []), account: nil, whole: true, now: Date())
        #expect(item.waits == [ItemStory.Wait(.you, "you, to answer in session “Roll out dark mode”", about: ItemRef.session(coordinator))])
        #expect(item.lines.first == "Answer in: “Roll out dark mode”, ghapp://sessions/\(coordinator)")
        #expect(item.status.hasPrefix("waiting for your answer in “Roll out dark mode”"))
    }

    @Test func describesWhatASessionAsksAndWhere() {
        let now = Date()
        let asking = session("abc", detail: "Should dark mode follow the system?", choices: ["Yes", "No"], since: now.addingTimeInterval(-120))
        #expect(CopilotAgent.line(asking, now: now) == """
            - “Add dark mode” (shop-web, dark-mode): Waiting for your answer, 2m ago. Should dark mode follow the system?
              Choices: Yes · No
              session abc
            """)
        let chat = session("c1", name: "", project: nil, branch: nil, isChat: true, phase: .running, reason: .working, since: now)
        #expect(CopilotAgent.line(chat, now: now) == "- “Untitled chat” (a chat): Working, just now\n  session c1")
    }

    @Test func saysWhereAQuestionAskedForAnotherSessionIsAnswered() {
        let now = Date()
        var coordinator = session("p1", name: "Release 2.5", project: nil, branch: nil, isChat: true, detail: "Which color?", since: now)
        coordinator.asksFor = [RelatedSession(id: "abc", name: "Add dark mode")]
        #expect(CopilotAgent.line(coordinator, now: now) == """
            - “Release 2.5” (a chat): Waiting for your answer, just now. Which color?
              Asks this for “Add dark mode” (session abc)
              session p1
            """)
        var waiting = session("abc", phase: .running, reason: .relayed, detail: "Which color?", since: now)
        waiting.headline = "Answer in “Release 2.5”"
        waiting.answerIn = RelatedSession(id: "p1", name: "Release 2.5")
        #expect(CopilotAgent.line(waiting, now: now) == """
            - “Add dark mode” (shop-web, dark-mode): Answer in “Release 2.5”, just now. Which color?
              Its coordinator asks it: answer in session p1
              session abc
            """)
    }

    @Test func namesPhasesTheWayAgentsCallThem() {
        #expect(DisplayPhase.allCases.map(\.agentName) == ["needs_you", "running", "done", "stopped", "idle"])
        #expect(DisplayPhase.named("needsYou") == .needsYou)
        #expect(DisplayPhase.named("STOPPED") == .stopped)
        #expect(DisplayPhase.named("later") == nil)
    }

    @Test func offersOneToolThatOnlyReads() {
        let agent = CopilotAgent(paths: CopilotPaths(root: URL(fileURLWithPath: "/nonexistent")))
        #expect(agent.tools.map(\.name) == ["copilot_sessions"])
        #expect(agent.tools.allSatisfy { $0.readOnly })
    }

    // MARK: The sessions on another source's pull requests

    private static let savedItems = ItemRef.pullRequest(organization: "contoso", number: 4120)
    private static let coupons = ItemRef.pullRequest(organization: "contoso", number: 4091)

    /// A work item's pull requests, as `work_item` asks about them: !4120 on saved-items in shop-web, and !4091 on
    /// coupon-rounding in payments-api.
    private static let query = MCPRelated.Query(
        items: [.workItem(organization: "contoso", id: 5101), savedItems, coupons],
        branches: [
            savedItems: BranchHint(branch: "saved-items", target: "main", repositories: ["shop-web"]),
            coupons: BranchHint(branch: "coupon-rounding", target: "main", repositories: ["payments-api"]),
        ]
    )

    @Test func linksSessionsToPullRequestsAsShowLinksDoes() throws {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let finished = session(
            "c3e8f1a2-6b4d-4e97-a1c5-2f7d9b0e8a11", name: "Save items for later", branch: "saved-items", phase: .idle, reason: .finished,
            since: ago(175)
        )
        var opened = session(
            "1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b01", name: "Round coupons half up", project: "payments-api", branch: "coupon-rounding",
            phase: .done, reason: .finished, since: ago(12)
        )
        opened.links = SessionLinks(pullRequests: [RecordedPullRequest(
            repository: nil, number: 4091, url: "https://dev.azure.com/contoso/Storefront/_git/payments-api/pullrequest/4091", role: .opened
        )])
        var startedFrom = session(
            "5d2e8a90-1f3b-4e7c-8a26-7b9c0d4e5f02", name: "Review the coupons", project: "storefront", branch: "review-4091",
            phase: .running, reason: .working, since: ago(3)
        )
        startedFrom.links = SessionLinks(pullRequests: [RecordedPullRequest(
            repository: nil, number: 4091, url: "https://dev.azure.com/contoso/Storefront/_git/payments-api/pullrequest/4091",
            role: .startedFrom
        )])
        let asking = session("0b6c1f44-6a1e-4c55-9d0e-3f0a6f1c2a01", name: "Show saved items", branch: "saved-items", since: ago(4))
        let sessions = [
            finished, opened, startedFrom, asking,
            // On main, which everybody works on; on the same branch in another repository; and a chat.
            session("9a4f2b17-c3d8-4e61-b5a0-2e8d7c6b4a03", name: "Release", branch: "main", since: ago(1)),
            session("3c7e9d21-8b4a-4f10-a6e2-5d1c0b9a8e04", name: "Elsewhere", project: "acme-api", branch: "saved-items", since: ago(2)),
            session("e81b5c63-2d9f-4a7e-9c34-1f6a8b2d0c05", name: "A chat", project: nil, branch: nil, isChat: true, since: ago(1)),
            // Not a session's ID.
            session("not-a-session", name: "Odd", branch: "saved-items", since: ago(1)),
        ]

        let linked = CopilotAgent.linked(sessions, to: Self.query)
        // The one that needs you first, then what's at work and what's done, then the rest.
        #expect(linked.map(\.session.name) == ["Show saved items", "Review the coupons", "Round coupons half up", "Save items for later"])
        #expect(linked.map { $0.links.map(\.reason) } == [
            ["on !4120's branch"], ["started from !4091"], ["opened !4091, on its branch"], ["on !4120's branch"],
        ])
        #expect(linked[0].links.map(\.item) == [Self.savedItems])
        #expect(CopilotAgent.linked(sessions, to: MCPRelated.Query(items: [.workItem(organization: "contoso", id: 5101)])).isEmpty)
    }

    @Test func saysWhereASessionStandsAndSinceWhen() {
        let now = Date()
        func status(_ reason: StatusReason, _ seconds: TimeInterval?) -> String {
            CopilotAgent.status(session("s", reason: reason, since: seconds.map { now.addingTimeInterval(-$0) }), now: now)
        }
        #expect(status(.question, 240) == "waiting for your answer since 4m ago")
        #expect(status(.planApproval, 120) == "waiting for you to review its plan since 2m ago")
        #expect(status(.permission, 20) == "waiting for your permission, just now")
        #expect(status(.working, 420) == "working since 7m ago")
        #expect(status(.finished, 10_500) == "finished 2h 55m ago")
        #expect(status(.failed, 1_200) == "stopped with an error 20m ago")
        #expect(status(.idle, 3 * 86_400) == "idle, last active 3d ago")
        #expect(status(.interrupted, nil) == "interrupted")
    }

    @Test func tellsWhatASessionAsksAndWhatCopilotRecordedBriefly() {
        let asking = session(
            "s", detail: "Should dark mode follow the system appearance?", choices: ["Yes", "No"], since: Date()
        )
        let notes = ItemStory.Account(
            source: SessionAccount.fromCheckpoints, milestones: ["Planned", "Built"],
            overview: """
                Each item in the cart now has a Save for later button, which saves it through the new API and takes it out of \
                the cart; guests don't see it. The cart and cart service tests pass. Showing saved items under the cart, and \
                moving one back, are work items of their own, so they're left for later.
                """,
            done: ["Added a Save for later button"], next: ["Push the saved-items branch to Sam's pull request !4120", "Show saved items"],
            lastMessage: "Pushed the saved-items branch, so Sam's pull request !4120 has all of it."
        )
        #expect(CopilotAgent.lines(asking, account: notes) == [
            "Asks: Should dark mode follow the system appearance?",
            "Choices: Yes · No",
            """
            Did: Each item in the cart now has a Save for later button, which saves it through the new API and takes it out of \
            the cart; guests don't see it. The cart and cart service tests pass.
            """,
            "Next: Push the saved-items branch to Sam's pull request !4120",
            "Said last: Pushed the saved-items branch, so Sam's pull request !4120 has all of it.",
        ])
        // Once it's no longer at work, what it said after its last checkpoint is how it ended, and the next step planned at
        // that checkpoint is left out.
        let ended = session("s", phase: .done, reason: .finished, detail: "Pushed it.", since: Date())
        #expect(CopilotAgent.lines(ended, account: notes).map { String($0.prefix(10)) } == ["Did: Each ", "Said last:"])
        // Without checkpoints: the summary it finished with is what it did, and a last message is only what it said.
        let finished = session("s", phase: .done, reason: .finished, detail: "Replaced the screenshots.", since: Date())
        #expect(CopilotAgent.lines(finished, account: ItemStory.Account(source: SessionAccount.fromReport, overview: "Replaced them."))
            == ["Did: Replaced them."])
        #expect(CopilotAgent.lines(finished, account: ItemStory.Account(source: SessionAccount.fromLastMessage, overview: "Use an actor."))
            == ["Said last: Use an actor."])
        #expect(CopilotAgent.lines(finished, account: nil) == ["Did: Replaced the screenshots."])
    }

    @Test func keepsTheFirstSentencesThatFit() {
        #expect(CopilotAgent.brief("One. Two.", limit: 240) == "One. Two.")
        #expect(CopilotAgent.brief("The first sentence. The second one is longer.", limit: 30) == "The first sentence.")
        #expect(CopilotAgent.brief("Done with !4120 and v1.2.3 today. More", limit: 34) == "Done with !4120 and v1.2.3 today.")
        // One sentence that's too long is cut at a word.
        #expect(CopilotAgent.brief("A sentence without an end that goes on and on", limit: 20) == "A sentence without…")
        #expect(CopilotAgent.brief("Line one\nline two", limit: 240) == "Line one line two")
    }

    /// Read from a Copilot folder as the app keeps it: its database, with the pull request one session opened, and the
    /// other's checkpoints.
    @Test func readsTheSessionsOnAPullRequestAndWhatCopilotRecorded() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BriefBarCopilotAgent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let paths = CopilotPaths(root: folder.resolvingSymlinksInPath())
        let savedItems = "c3e8f1a2-6b4d-4e97-a1c5-2f7d9b0e8a11"
        let coupons = "1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b01"
        try FileManager.default.createDirectory(at: paths.sessionState, withIntermediateDirectories: true)
        func updated(hoursAgo: Double) -> String {
            Date().addingTimeInterval(-hoursAgo * 3_600).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        try sqlite(paths.database, """
            CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, github_owner TEXT, github_repo TEXT,
                                   main_repo_path TEXT);
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY NOT NULL, title TEXT, session_type TEXT NOT NULL DEFAULT 'workspace', mode TEXT,
                is_running INTEGER NOT NULL DEFAULT 0, was_interrupted INTEGER NOT NULL DEFAULT 0,
                interruption_reason TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT);
            CREATE TABLE workspaces (
                id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL, session_id TEXT, branch TEXT NOT NULL,
                name TEXT NOT NULL, creator_session_id TEXT, archived_at TEXT, updated_at TEXT NOT NULL,
                source_pr_repo_full_name TEXT, source_pr_number INTEGER, source_pr_html_url TEXT,
                created_pr_repo_full_name TEXT, created_pr_number INTEGER, created_pr_html_url TEXT);
            INSERT INTO projects (id, name) VALUES ('p1', 'shop-web'), ('p2', 'payments-api');
            INSERT INTO sessions (id, title, session_type, created_at, updated_at) VALUES
                ('\(savedItems)', 'Save items for later', 'project', '\(updated(hoursAgo: 5))', '\(updated(hoursAgo: 3))'),
                ('\(coupons)', 'Round coupons half up', 'project', '\(updated(hoursAgo: 5))', '\(updated(hoursAgo: 4))');
            INSERT INTO workspaces (id, project_id, session_id, branch, name, updated_at, created_pr_number, created_pr_html_url) VALUES
                ('w1', 'p1', '\(savedItems)', 'saved-items', 'Save items for later', '\(updated(hoursAgo: 3))', NULL, NULL),
                ('w2', 'p2', '\(coupons)', 'fix-coupons', 'Round coupons half up', '\(updated(hoursAgo: 4))', 4091,
                 'https://dev.azure.com/contoso/Storefront/_git/payments-api/pullrequest/4091');
            """)
        let checkpoints = paths.sessionDirectory(savedItems).appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        try """
            | # | Title | File |
            |---|-------|------|
            | 1 | Save for later added | 001-save-for-later-added.md |
            """.write(to: checkpoints.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        try """
            <overview>
            Each cart item has a Save for later button now.
            </overview>
            <next_steps>
            1. Push the saved-items branch to Sam's pull request !4120
            </next_steps>
            """.write(to: checkpoints.appendingPathComponent("001-save-for-later-added.md"), atomically: true, encoding: .utf8)

        let agent = CopilotAgent(paths: paths, isDemo: true)
        let items = try await agent.teller.tell(Self.query)
        #expect(items.map(\.title) == ["Save items for later", "Round coupons half up"])
        #expect(items.map { $0.links.map(\.reason) } == [["on !4120's branch"], ["opened !4091"]])
        #expect(items[0].url?.absoluteString == "ghapp://sessions/\(savedItems)")
        #expect(items[0].status == "idle, last active 3h ago")
        #expect(items[0].lines == ["Did: Each cart item has a Save for later button now.", "Next: Push the saved-items branch to Sam's pull request !4120"])
        #expect(items[1].lines.isEmpty)

        // Only the first ones are told in full.
        var one = Self.query
        one.limit = 1
        #expect(try await agent.related(one).map(\.lines.isEmpty) == [false, true])
        // Nothing to look for without a pull request.
        #expect(try await agent.related(MCPRelated.Query(items: [.workItem(organization: "contoso", id: 5101)])).isEmpty)
    }

    /// Runs SQL in a new database.
    private func sqlite(_ url: URL, _ statements: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw MCPToolError("Couldn't create \(url.path)") }
        defer { sqlite3_close(database) }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, statements, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw MCPToolError(message.map { String(cString: $0) } ?? "SQLite error")
        }
    }
}
