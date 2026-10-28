import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import SQLite3
import Synchronization
import Testing
@testable import AzureDevOpsUI

private struct DatabaseError: Error {
    var message: String
}

/// Where a task goes instead of a new session: BriefBar's earlier tasks, the work item's task that opened the pull request,
/// and the Copilot app's sessions, those that go with it first, by why; and what it goes to unless you choose.
@MainActor
@Suite struct SessionChoicesTests {
    private let now = Date(timeIntervalSince1970: 1_792_317_600)
    private let fixing = "11111111-1111-4111-8111-111111111111"
    private let opener = "22222222-2222-4222-8222-222222222222"
    private let elsewhere = "33333333-3333-4333-8333-333333333333"
    private let onBranch = "44444444-4444-4444-8444-444444444444"
    private let recorded = "55555555-5555-4555-8555-555555555555"
    private let linkedChat = "66666666-6666-4666-8666-666666666666"
    private let other = "77777777-7777-4777-8777-777777777777"

    private var pullRequest: TaskPullRequest {
        TaskPullRequest(
            organization: "Contoso", project: "Storefront", repository: "shop-web", id: 4071, title: "Fix totals",
            url: URL(string: "https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/4071")!,
            sourceBranch: "fix-totals", targetBranch: "main"
        )
    }

    private var subject: TaskSubject { .pullRequest(pullRequest, .fixComments) }

    private func run(_ id: String, worktree: URL, onPullRequest: Int? = nil, workItem: Int? = nil, opened: Int? = nil, ended: RunPhase? = .finished) -> CopilotRun {
        CopilotRun(
            id: id, workItem: workItem.map { WorkItemReference(organization: "contoso", project: "Storefront", id: $0) },
            onPullRequest: onPullRequest.map { PullRequestReference(organization: "contoso", project: "Storefront", repository: "shop-web", id: $0, sourceBranch: "fix-totals") },
            action: onPullRequest == nil ? nil : .fixComments, options: CopilotModel.standard,
            repository: worktree.deletingLastPathComponent(), worktree: worktree, startedAt: now, process: DetachedProgram.Handle(pid: 0, startedAt: nil),
            ended: ended, pullRequest: opened.map { URL(string: "https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/\($0)")! }
        )
    }

    private func store(home: URL) -> CopilotTasksStore {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        let store = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        store.appHomeForTests = home
        store.useEnvironment(["COPILOT_HOME": home.path, "PATH": "/usr/bin:/bin"])
        return store
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BriefBarSessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A stand-in for the Copilot app's `data.db`: what its session list and their links read.
    private func database(at home: URL, sessions: [(id: String, title: String, type: String, branch: String?, project: String?, link: String?, updated: String)]) throws {
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
                INSERT INTO sessions (id, title, session_type, created_at, updated_at)
                    VALUES ('\(session.id)', '\(session.title)', '\(session.type)', '2026-10-01T09:00:00.000Z', '\(session.updated)');

                """
            if let branch = session.branch, let project = session.project {
                statements += """
                    INSERT INTO workspaces (id, project_id, session_id, branch, name, updated_at)
                        VALUES ('w\(index)', '\(project)', '\(session.id)', '\(branch)', '\(session.title)', '\(session.updated)');

                    """
                if let link = session.link {
                    statements += "INSERT INTO workspace_pull_request_links (workspace_id, uri) VALUES ('w\(index)', '\(link)');\n"
                }
            }
        }
        guard sqlite3_exec(handle, statements, nil, nil, nil) == SQLITE_OK else { throw DatabaseError(message: String(cString: sqlite3_errmsg(handle))) }
    }

    // MARK: BriefBar's tasks

    @Test func findsTheTasksOnThePullRequestAndTheOneThatOpenedIt() throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let worktrees = home.appendingPathComponent("copilot-worktrees/shop-web", isDirectory: true)
        for name in ["pr-4071", "wi-4217", "pr-5000"] {
            try FileManager.default.createDirectory(at: worktrees.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let store = store(home: home)
        store.settings.copilotRuns = [
            run(fixing, worktree: worktrees.appendingPathComponent("pr-4071"), onPullRequest: 4071),
            run(opener, worktree: worktrees.appendingPathComponent("wi-4217"), workItem: 4217, opened: 4071),
            run(elsewhere, worktree: worktrees.appendingPathComponent("pr-5000"), onPullRequest: 5000),
            // Its worktree is gone: nothing to go on with.
            run("88888888-8888-4888-8888-888888888888", worktree: worktrees.appendingPathComponent("gone"), onPullRequest: 4071),
        ]
        let choices = store.taskChoices(for: subject)
        #expect(choices.map(\.id).sorted() == [fixing, opener])
        #expect(choices.first { $0.id == fixing }?.reasons == [.earlierTask])
        #expect(choices.first { $0.id == opener }?.reasons == [.openedIt])
        #expect(choices.allSatisfy { !$0.isBusy && $0.run != nil })
        // A work item's are its own tasks'.
        let item = TaskWorkItem(organization: "CONTOSO", project: "Storefront", id: 4217, type: "Task", title: "Totals",
                                url: URL(string: "https://dev.azure.com/contoso/Storefront/_workitems/edit/4217")!)
        #expect(store.taskChoices(for: .workItem(item)).map(\.id) == [opener])
    }

    // MARK: The app's sessions

    @Test func findsTheAppsSessionsThatGoWithThePullRequest() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home, sessions: [
            (onBranch, "Fix the totals", "project", "fix-totals", "shop", nil, "2026-10-27T10:00:00.000Z"),
            (recorded, "Totals follow-up", "project", "another-branch", "shop", pullRequest.url.absoluteString, "2026-10-26T10:00:00.000Z"),
            (linkedChat, "Plan the totals", "general_chat", nil, nil, nil, "2026-10-25T10:00:00.000Z"),
            (other, "Docs", "project", "fix-totals", "docs", nil, "2026-10-28T10:00:00.000Z"),
            // A task's session that you opened in the app is the task's.
            (fixing, "Fix Comments", "project", "fix-totals", "shop", nil, "2026-10-28T11:00:00.000Z"),
        ])
        let worktree = home.appendingPathComponent("copilot-worktrees/shop-web/pr-4071", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        // The app has the one on the branch open: this test's process stands in for it.
        let state = home.appendingPathComponent("session-state/\(onBranch)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data().write(to: state.appendingPathComponent("inuse.\(getpid()).lock"))

        let store = store(home: home)
        store.settings.copilotRuns = [run(fixing, worktree: worktree, onPullRequest: 4071)]
        var asked: [ItemRef] = []
        store.linkedSessions = { ref in
            asked.append(ref)
            return [LinkedSession(id: linkedChat, origins: [.you], isThrough: false)]
        }
        let choices = await store.sessionChoices(for: subject)
        #expect(asked == [.pullRequest(organization: "contoso", number: 4071)])
        #expect(choices.map(\.id) == [fixing, recorded, onBranch, linkedChat, other])
        #expect(choices.map(\.reasons) == [[.earlierTask], [.recordedByCopilot], [.onItsBranch], [.linkedByYou], []])
        #expect(choices.map(\.isOpenInApp) == [false, false, true, false, false])
        #expect(choices.first { $0.id == onBranch }?.place == "shop-web · fix-totals")
        #expect(choices.first { $0.id == linkedChat }?.place == "a chat")
        #expect(choices.first { $0.id == fixing }?.opensInApp == false)
        #expect(choices.first { $0.id == other }?.opensInApp == true)
    }

    @Test func findsTheSessionsWhoseLogsMentionIt() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = store(home: home)
        func session(_ id: String, active: Date, log: String) throws -> SessionChoice {
            let state = home.appendingPathComponent("session-state/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try Data(log.utf8).write(to: state.appendingPathComponent("events.jsonl"))
            let app = AppSession(id: id, name: id, lastActive: active)
            return SessionChoice(kind: .app(app), name: id, lastActive: active, reasons: [])
        }
        let link = #"{"data":{"content":"Opened https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/4071"}}"#
        let choices = [
            try session(onBranch, active: now, log: link),
            try session(recorded, active: now, log: "Nothing about it"),
            // Not active since it was created: not read.
            try session(other, active: now.addingTimeInterval(-90_000), log: link),
        ]
        let found = await store.sessionsMentioning(subject, among: choices, since: now.addingTimeInterval(-3_600))
        #expect(found == [onBranch])

        store.settings.copilotEnabled = false
        #expect(await store.sessionsMentioning(subject, among: choices, since: nil).isEmpty)
        #expect(await store.sessionChoices(for: subject).isEmpty)
    }

    // MARK: What it goes to

    private func choice(_ id: String, reasons: [SessionChoice.Reason], active: TimeInterval, born: TimeInterval? = nil, task: CopilotRun? = nil, busy: Bool = false) -> SessionChoice {
        let kind: SessionChoice.Kind = task.map { .task($0) }
            ?? .app(AppSession(id: id, name: id, createdAt: born.map { now.addingTimeInterval($0) }, lastActive: now.addingTimeInterval(active)))
        return SessionChoice(kind: kind, name: id, lastActive: now.addingTimeInterval(active), reasons: reasons, isBusy: busy)
    }

    @Test func goesOnWithTheLastTaskThenTheOneThatOpenedItThenTheAppsSession() {
        let worktree = URL(fileURLWithPath: "/tmp/pr-4071")
        let last = run(fixing, worktree: worktree, onPullRequest: 4071)
        let openedIt = run(opener, worktree: worktree, workItem: 4217, opened: 4071)
        let created = now.addingTimeInterval(-86_400)
        var choices = [
            choice(fixing, reasons: [.earlierTask], active: -60, task: last),
            choice(opener, reasons: [.openedIt], active: -600, task: openedIt),
            choice(onBranch, reasons: [.onItsBranch], active: -3_600),
            choice(linkedChat, reasons: [.linkedByYou], active: -60),
            choice(recorded, reasons: [.mentionsIt], active: -10, born: -172_800),
            choice(other, reasons: [.mentionsIt], active: -5, born: -3_600),
        ]
        func suggested(continuable: CopilotRun? = nil) -> String? {
            CopilotTasksStore.suggestedChoice(choices, for: subject, continuable: continuable, createdAt: created)?.id
        }
        #expect(suggested(continuable: last) == fixing)
        #expect(suggested() == opener)
        choices.removeAll { $0.id == opener }
        // Of what the app records, you linked, or works on its branch: the most recently active.
        #expect(suggested() == linkedChat)
        choices.removeAll { $0.id == linkedChat || $0.id == onBranch }
        // Else the one that mentions it and was there before it was created, which likely opened it.
        #expect(suggested() == recorded)
        choices.removeAll { $0.id == recorded }
        #expect(suggested() == nil)
        // One that's working is never where it goes.
        choices = [choice(fixing, reasons: [.earlierTask], active: -60, task: last, busy: true)]
        #expect(suggested(continuable: last) == nil)
        // A work item's starts a new session, unless you choose one.
        let item = TaskWorkItem(organization: "contoso", project: "Storefront", id: 4217, type: "Task", title: "Totals",
                                url: URL(string: "https://dev.azure.com/contoso/Storefront/_workitems/edit/4217")!)
        #expect(CopilotTasksStore.suggestedChoice([choice(onBranch, reasons: [.linkedByYou], active: 0)], for: .workItem(item), continuable: nil, createdAt: nil) == nil)
    }

    @Test func listsTheAppsSessionsByWhyThenByWhen() {
        let created = now.addingTimeInterval(-86_400)
        let sorted = CopilotTasksStore.sorted([
            choice(other, reasons: [], active: -1),
            choice(onBranch, reasons: [.onItsBranch, .mentionsIt], active: -9_000),
            choice(linkedChat, reasons: [.mentionsIt], active: -2, born: -3_600),
            choice(recorded, reasons: [.mentionsIt], active: -500, born: -172_800),
            choice(elsewhere, reasons: [.mentionsIt], active: -400, born: -200_000),
            choice(fixing, reasons: [.recordedByCopilot], active: -9_999),
        ], createdAt: created)
        // Then, of those that only mention it, the ones there before it was created, the oldest first.
        #expect(sorted.map(\.id) == [fixing, onBranch, elsewhere, recorded, linkedChat, other])
    }

    // MARK: Sending

    @Test func handsThePromptToTheSessionInTheCopilotApp() throws {
        let store = store(home: URL(fileURLWithPath: "/nonexistent"))
        var opened: [(String, String)] = []
        store.openForTests = { opened.append(($0, $1)) }
        var handed: [String] = []
        store.handedOff = { _, prompt in handed.append(prompt) }
        let handOff = CommentHandOff(key: PRKey("contoso", 4071), waiting: [], account: nil, me: "me", dismissedCutoff: .distantPast)
        let session = choice(onBranch, reasons: [.onItsBranch], active: 0)

        store.openInCopilot(session, prompt: "Fix the comments", handOff: handOff)
        #expect(opened.map(\.0) == [onBranch])
        #expect(opened.map(\.1) == ["Fix the comments"])
        // It's in your hands now: its comments leave Needs You.
        #expect(handed == ["Fix the comments"])
        // Nothing starts here.
        #expect(store.pending.isEmpty)
        #expect(store.settings.copilotRuns.isEmpty)

        store.settings.copilotEnabled = false
        store.openInCopilot(session, prompt: "Again", handOff: nil)
        #expect(opened.count == 1)
    }

    /// The CLI goes on with one of the app's sessions in the folder it works in, which isn't a repository to start new
    /// work in: it isn't remembered as one.
    @Test func goesOnWithAnAppsSessionInItsFolder() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let worktree = home.appendingPathComponent("copilot-worktrees/shop-web/fix-totals", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let state = home.appendingPathComponent("session-state/\(onBranch)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("cwd: \(worktree.path)\n".utf8).write(to: state.appendingPathComponent("workspace.yaml"))

        let store = store(home: home)
        let requests = Mutex<[CopilotLauncher.Request]>([])
        store.launchForTests = { request, _, _ in
            requests.withLock { $0.append(request) }
            guard var run = request.continuing else { throw LaunchError.couldntStart("no session") }
            run.startedAt = Date()
            return run
        }
        let session = AppSession(id: onBranch, name: "Fix the totals", projectName: "shop-web", branch: "fix-totals")
        let appRun = try #require(store.appRun(for: session, subject: subject, options: CopilotModel.quick))
        #expect(appRun.isAppSession == true)
        #expect(appRun.worktree.path == worktree.path)
        #expect(appRun.onPullRequest == pullRequest.reference)
        #expect(appRun.action == .fixComments)
        #expect(store.appRun(for: AppSession(id: other, name: "Elsewhere"), subject: subject, options: CopilotModel.quick) == nil)

        store.send(subject, prompt: "Fix the comments", options: CopilotModel.quick, repository: appRun.repository, continuing: appRun)
        #expect(store.settings.copilotRepositories.isEmpty)
        for _ in 0..<100 where store.settings.copilotRuns.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        let request = try #require(requests.withLock { $0.first })
        #expect(request.continuing?.isAppSession == true)
        #expect(request.repository.path == worktree.path)
        #expect(store.settings.copilotRuns.map(\.id) == [onBranch])
        #expect(store.settings.copilotRuns.first?.isAppSession == true)
        store.stop()
    }

    /// A task on the pull request a work item's task opened is named for the pull request.
    @Test func namesATaskOnThePullRequestForIt() {
        let store = store(home: URL(fileURLWithPath: "/nonexistent"))
        store.pullRequestTitle = { _ in "Fix totals" }
        store.title = { _ in "Show the order total" }
        let entry = CopilotTaskEntry(
            id: opener, workItem: WorkItemReference(organization: "contoso", project: "Storefront", id: 4217),
            onPullRequest: pullRequest.reference, action: .fixComments, options: CopilotModel.standard, startedAt: now,
            status: RunStatus(phase: .working)
        )
        #expect(store.subject(of: entry) == "!4071 Fix totals")
        #expect(store.name(of: entry) == "Fix Comments: !4071 Fix totals")
    }
}
