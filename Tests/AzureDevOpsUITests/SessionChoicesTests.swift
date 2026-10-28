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
        var opens = true
        store.openForTests = { opened.append(($0, $1)); return opens }
        var handed: [String] = []
        store.handedOff = { _, prompt in handed.append(prompt) }
        let handOff = CommentHandOff(key: PRKey("contoso", 4071), waiting: [], account: nil, me: "me", dismissedCutoff: .distantPast)
        let session = choice(onBranch, reasons: [.onItsBranch], active: 0)

        #expect(store.openInCopilot(session, prompt: "Fix the comments", handOff: handOff) == nil)
        #expect(opened.map(\.0) == [onBranch])
        #expect(opened.map(\.1) == ["Fix the comments"])
        // It's in your hands now: its comments leave Needs You.
        #expect(handed == ["Fix the comments"])
        // Nothing starts here.
        #expect(store.pending.isEmpty)
        #expect(store.settings.copilotRuns.isEmpty)

        // When it doesn't open, nothing's handed off: the comments still wait on you, and the window says why.
        opens = false
        #expect(store.openInCopilot(session, prompt: "Fix them again", handOff: handOff) == CopilotTasksStore.cantOpenInApp)
        #expect(opened.count == 2)
        #expect(handed == ["Fix the comments"])

        store.settings.copilotEnabled = false
        #expect(store.openInCopilot(session, prompt: "Again", handOff: nil) != nil)
        #expect(opened.count == 2)
    }

    /// Without the Copilot app, nothing opens its `ghapp://` links: BriefBar doesn't try, leaves the clipboard alone, and
    /// hands nothing off.
    @Test func handsNothingOffWhenNothingOpensTheAppsSessions() {
        let store = store(home: URL(fileURLWithPath: "/nonexistent"))
        store.opensLinksForTests = false
        var handed = 0
        store.handedOff = { _, _ in handed += 1 }
        let handOff = CommentHandOff(key: PRKey("contoso", 4071), waiting: [], account: nil, me: "me", dismissedCutoff: .distantPast)
        #expect(!store.canOpenInApp)
        #expect(store.openInCopilot(choice(onBranch, reasons: [], active: 0), prompt: "Fix it", handOff: handOff) == CopilotTasksStore.cantOpenInApp)
        #expect(handed == 0)
        store.opensLinksForTests = true
        #expect(store.canOpenInApp)
    }

    /// A session that a task of BriefBar's works in, for another pull request, is busy: it isn't suggested, nothing opens
    /// it in the app, and no second run starts in it, any of which would fork its history.
    @Test func keepsOutOfASessionThatATaskWorksIn() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home, sessions: [
            (onBranch, "Fix the totals", "project", "fix-totals", "shop", nil, "2026-10-27T10:00:00.000Z"),
        ])
        let store = store(home: home)
        // Working on pull request 5000 in the app's session, in a process that runs: this test's own stands in for it.
        var elsewhere = run(onBranch, worktree: home, onPullRequest: 5000, ended: nil)
        elsewhere.isAppSession = true
        elsewhere.process = DetachedProgram.Handle(pid: getpid(), startedAt: nil)
        store.settings.copilotRuns = [elsewhere]
        #expect(store.isWorking(inSession: onBranch))

        let choices = await store.sessionChoices(for: subject)
        let busy = try #require(choices.first { $0.id == onBranch })
        #expect(busy.isBusy)
        #expect(busy.reasons == [.onItsBranch])
        #expect(CopilotTasksStore.suggestedChoice(choices, for: subject, continuable: nil, createdAt: nil) == nil)

        var opened = 0
        store.openForTests = { _, _ in opened += 1; return true }
        #expect(store.openInCopilot(busy, prompt: "Fix the comments", handOff: nil) != nil)
        #expect(opened == 0)

        let launched = Mutex(0)
        store.launchForTests = { request, _, _ in
            launched.withLock { $0 += 1 }
            guard let run = request.continuing else { throw LaunchError.couldntStart("no session") }
            return run
        }
        var again = elsewhere
        again.onPullRequest = pullRequest.reference
        store.send(subject, prompt: "Fix the comments", options: CopilotModel.standard, repository: home, continuing: again)
        try await Task.sleep(for: .milliseconds(100))
        #expect(launched.withLock { $0 } == 0)
        #expect(store.pending.isEmpty)

        // Once its process is gone, it's free again.
        store.settings.copilotRuns[0].process = DetachedProgram.Handle(pid: 0, startedAt: nil)
        #expect(!store.isWorking(inSession: onBranch))
        store.stop()
    }

    /// Two of the app's sessions can share a checkout. While a task of BriefBar's works in one, the other is unavailable
    /// too: it isn't suggested or offered, isn't opened in the app, and no run starts in it, or their work would mix.
    @Test func keepsOutOfAFolderThatATaskWorksInForAnotherSession() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home, sessions: [
            (onBranch, "Fix the totals", "project", "fix-totals", "shop", nil, "2026-10-27T10:00:00.000Z"),
            (recorded, "Totals follow-up", "project", "fix-totals", "shop", pullRequest.url.absoluteString, "2026-10-26T10:00:00.000Z"),
        ])
        let checkout = home.appendingPathComponent("checkouts/shop-web", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        for id in [onBranch, recorded] {
            let state = home.appendingPathComponent("session-state/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try Data("cwd: \(checkout.path)\n".utf8).write(to: state.appendingPathComponent("workspace.yaml"))
            try Data().write(to: state.appendingPathComponent("events.jsonl"))
        }
        let store = store(home: home)
        defer { store.stop() }
        // Working on pull request 5000 in one of them, in a process that runs: this test's own stands in for it.
        var working = run(onBranch, worktree: checkout, onPullRequest: 5000, ended: nil)
        working.isAppSession = true
        working.process = DetachedProgram.Handle(pid: getpid(), startedAt: nil)
        store.settings.copilotRuns = [working]
        #expect(store.isWorking(inFolder: checkout))
        #expect(!store.isWorking(inFolder: home))

        let choices = await store.sessionChoices(for: subject)
        let other = try #require(choices.first { $0.id == recorded })
        #expect(!other.isBusy)
        #expect(other.isFolderBusy)
        #expect(other.isUnavailable)
        #expect(other.folder.map(CopilotTasksStore.folderKey) == CopilotTasksStore.folderKey(checkout))
        // Sharing the checkout, both are on the pull request's branch.
        #expect(other.reasons == [.recordedByCopilot, .onItsBranch])
        #expect(choices.first { $0.id == onBranch }?.isBusy == true)
        #expect(CopilotTasksStore.suggestedChoice(choices, for: subject, continuable: nil, createdAt: nil) == nil)
        #expect(store.busyReason(for: other)?.hasPrefix("Copilot is working in its checkout") == true)

        var opened = 0
        store.openForTests = { _, _ in opened += 1; return true }
        #expect(store.openInCopilot(other, prompt: "Fix the comments", handOff: nil) != nil)
        #expect(opened == 0)
        let session = try #require(other.appSession)
        #expect(await store.cliProblem(for: other, subject: subject) == "Copilot is working in the same checkout for another task BriefBar sent.")

        let launched = Mutex(0)
        store.launchForTests = { request, _, _ in
            launched.withLock { $0 += 1 }
            guard let run = request.continuing else { throw LaunchError.couldntStart("no session") }
            return run
        }
        let appRun = try #require(store.appRun(for: session, subject: subject, options: CopilotModel.standard))
        store.send(subject, prompt: "Fix the comments", options: CopilotModel.standard, repository: checkout, continuing: appRun)
        try await Task.sleep(for: .milliseconds(100))
        #expect(launched.withLock { $0 } == 0)
        #expect(store.pending.isEmpty)

        // Once that task is done, as BriefBar sees it end, the folder is free again, and the sessions the composer found
        // free up without it opening again.
        store.settings.copilotRuns[0].process = DetachedProgram.Handle(pid: 0, startedAt: nil)
        store.settings.copilotRuns[0].ended = .finished
        #expect(!store.isWorking(inFolder: checkout))
        #expect(store.busyReason(for: other) == nil)
        let freed = store.availability(of: choices)
        #expect(freed.allSatisfy { !$0.isUnavailable })
        #expect(freed.map(\.id) == choices.map(\.id))
        #expect(freed.map(\.reasons) == choices.map(\.reasons))
        #expect(CopilotTasksStore.suggestedChoice(freed, for: subject, continuable: nil, createdAt: nil) != nil)

        // A task that starts in one of them takes both again, as it gets ready.
        store.launchForTests = { _, _, _ in throw LaunchError.couldntStart("not now") }
        store.send(subject, prompt: "Fix the comments", options: CopilotModel.standard, repository: checkout, continuing: appRun)
        let taken = store.availability(of: freed)
        #expect(taken.first { $0.id == recorded }?.isBusy == true)
        #expect(taken.first { $0.id == onBranch }?.isFolderBusy == true)
    }

    /// Another of the app's sessions that works in the same folder and runs a turn now keeps the CLI out of it: only you
    /// decide, in the app, whether both work there.
    @Test func doesNotRunWhereAnotherAppSessionRunsATurn() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let checkout = home.appendingPathComponent("checkouts/shop-web", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        for id in [onBranch, recorded] {
            let state = home.appendingPathComponent("session-state/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try Data("cwd: \(checkout.path)\n".utf8).write(to: state.appendingPathComponent("workspace.yaml"))
            try Data().write(to: state.appendingPathComponent("events.jsonl"))
        }
        let store = store(home: home)
        let session = AppSession(id: onBranch, name: "Fix the totals")
        let choice = SessionChoice(kind: .app(session), name: session.name, reasons: [.onItsBranch])
        let busy = AppSession(id: recorded, name: "Totals follow-up", isRunning: true)
        #expect(await store.cliProblem(for: choice, subject: subject, others: [session, busy])
            == "Another Copilot session is working in the same checkout now, so Copilot won't work there on its own.")
        // Idle, it doesn't: the checks go on, to whether the folder is a clone of the pull request's repository.
        var idle = busy
        idle.isRunning = false
        let problem = await store.cliProblem(for: choice, subject: subject, others: [session, idle])
        #expect(problem?.contains("isn't a git repository") == true)
    }

    /// Sessions share a checkout wherever in it each works: the nearest folder with a `.git` of its own, a worktree's file
    /// too. A folder that holds checkouts is one of its own, as its sessions mostly work elsewhere. The CLI keeps out of a
    /// checkout that a task of BriefBar's, or another of the app's sessions running a turn, works in: for BriefBar's earlier
    /// tasks' sessions as for the app's, those that went on with one of the app's, and those in BriefBar's own worktrees.
    @Test func keepsOutOfACheckoutWhereverInItSessionsWork() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let repos = home.appendingPathComponent("repos", isDirectory: true)
        let checkout = repos.appendingPathComponent("shop-web", isDirectory: true)
        let cart = checkout.appendingPathComponent("Sources/Cart", isDirectory: true)
        let worktree = repos.appendingPathComponent("worktrees/shop-web-pr-4071", isDirectory: true)
        let docs = repos.appendingPathComponent("docs", isDirectory: true)
        for folder in [cart, worktree, docs.appendingPathComponent(".git"), checkout.appendingPathComponent(".git")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("gitdir: \(checkout.path)/.git/worktrees/shop-web-pr-4071\n".utf8).write(to: worktree.appendingPathComponent(".git"))
        func works(_ id: String, in folder: URL) throws {
            let state = home.appendingPathComponent("session-state/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try Data("cwd: \(folder.path)\n".utf8).write(to: state.appendingPathComponent("workspace.yaml"))
            try Data().write(to: state.appendingPathComponent("events.jsonl"))
        }
        func key(_ folder: URL) -> String { CopilotTasksStore.checkoutKey(folder) }
        #expect(key(cart) == CopilotTasksStore.folderKey(checkout))
        #expect(key(worktree) == CopilotTasksStore.folderKey(worktree))
        #expect(key(repos) == CopilotTasksStore.folderKey(repos))
        #expect(Set([checkout, worktree, docs, repos].map(key)).count == 4)

        // A task of BriefBar's in the checkout, in a process that runs: this test's own stands in for it.
        let store = store(home: home)
        defer { store.stop() }
        var working = run(elsewhere, worktree: checkout, onPullRequest: 5000, ended: nil)
        working.isAppSession = true
        working.process = DetachedProgram.Handle(pid: getpid(), startedAt: nil)
        store.settings.copilotRuns = [working]
        #expect(store.isWorking(inFolder: cart))
        #expect(![repos, worktree, docs].contains { store.isWorking(inFolder: $0) })
        try works(onBranch, in: cart)
        try works(recorded, in: repos)
        let inCart = SessionChoice(kind: .app(AppSession(id: onBranch, name: "Cart")), name: "Cart", reasons: [], appFolder: cart)
        let inRepos = SessionChoice(kind: .app(AppSession(id: recorded, name: "Repos")), name: "Repos", reasons: [], appFolder: repos)
        #expect(store.availability(of: [inCart, inRepos]).map(\.isFolderBusy) == [true, false])
        #expect(store.busyReason(for: inCart)?.hasPrefix("Copilot is working in its checkout") == true)
        #expect(store.busyReason(for: inRepos) == nil)
        #expect(await store.cliProblem(for: inCart, subject: subject) == "Copilot is working in the same checkout for another task BriefBar sent.")

        // Once it's done, another of the app's sessions runs a turn in a folder of the checkout.
        store.settings.copilotRuns = []
        let sharing = "Another Copilot session is working in the same checkout now, so Copilot won't work there on its own."
        let turn = AppSession(id: other, name: "Cart follow-up", isRunning: true)
        try works(other, in: cart)
        try works(fixing, in: checkout)
        let atRoot = SessionChoice(kind: .app(AppSession(id: fixing, name: "Fix the totals")), name: "Fix the totals", reasons: [])
        #expect(await store.cliProblem(for: atRoot, subject: subject, others: [turn]) == sharing)
        // An earlier task that went on with one of the app's sessions, there.
        var wentOn = run(opener, worktree: checkout, onPullRequest: 4071)
        wentOn.isAppSession = true
        try works(opener, in: checkout)
        let earlier = SessionChoice(kind: .task(wentOn), name: "Fix Comments", reasons: [.earlierTask])
        #expect(await store.cliProblem(for: earlier, subject: subject, others: [turn]) == sharing)
        // An earlier task in BriefBar's own worktree, which the CLI made: another of the app's sessions can work there too.
        try works(other, in: worktree)
        let made = run("99999999-9999-4999-8999-999999999999", worktree: worktree, onPullRequest: 4071)
        let own = SessionChoice(kind: .task(made), name: "Fix Comments", reasons: [.earlierTask])
        #expect(await store.cliProblem(for: own, subject: subject, others: [turn]) == sharing)
        // One in the folder that holds the checkouts works elsewhere: the checks go on, to the repository.
        try works(other, in: repos)
        for choice in [atRoot, earlier, own] {
            let problem = await store.cliProblem(for: choice, subject: subject, others: [turn])
            #expect(problem?.contains("isn't a git repository") == true)
        }
    }

    // MARK: Prompts

    /// Where Copilot works decides the prompt: BriefBar's worktree at the pull request's latest commit, for a new session
    /// or a pull request task's; elsewhere, for the Copilot app's sessions and a work item's task that kept its checkout,
    /// with the checks that go with it, Push & Reply's too.
    @Test func writesThePromptForWhereCopilotWorks() {
        let worktree = URL(fileURLWithPath: "/tmp/pr-4071")
        func prompt(_ choice: SessionChoice?, _ subject: TaskSubject? = nil) -> String {
            CopilotComposerView.writtenPrompt(
                for: choice, subject: subject ?? self.subject, template: PromptTemplate.standard, worktreePrompt: "worktree",
                sessionPrompt: "session", baseBranch: "main"
            )
        }
        let fixingRun = run(fixing, worktree: worktree, onPullRequest: 4071)
        #expect(fixingRun.worksInPullRequestWorktree)
        #expect(prompt(nil) == "worktree")
        #expect(prompt(choice(fixing, reasons: [.earlierTask], active: 0, task: fixingRun)) == "worktree")
        #expect(prompt(choice(onBranch, reasons: [.onItsBranch], active: 0)) == "session")

        // A pull request task that went on with the work item's task that opened it keeps that task's checkout.
        var kept = run(opener, worktree: worktree, onPullRequest: 4071, workItem: 4217)
        #expect(!kept.worksInPullRequestWorktree)
        #expect(prompt(choice(opener, reasons: [.earlierTask], active: 0, task: kept)) == "session")
        let opened = run(opener, worktree: worktree, workItem: 4217, opened: 4071)
        #expect(prompt(choice(opener, reasons: [.openedIt], active: 0, task: opened)) == "session")

        // One that went on with the app's session works in the app's folder, and opens in the app by default.
        kept.workItem = nil
        kept.isAppSession = true
        #expect(!kept.worksInPullRequestWorktree)
        let appTask = choice(opener, reasons: [.earlierTask], active: 0, task: kept)
        #expect(prompt(appTask) == "session")
        #expect(appTask.opensInApp)
        #expect(!choice(fixing, reasons: [.earlierTask], active: 0, task: fixingRun).opensInApp)

        // A work item's: the one in Settings for a new worktree; BriefBar's own, which checks first, for a session.
        let item = TaskWorkItem(organization: "contoso", project: "Storefront", id: 4217, type: "Task", title: "Show the total",
                                url: URL(string: "https://dev.azure.com/contoso/Storefront/_workitems/edit/4217")!)
        let fresh = prompt(nil, .workItem(item))
        #expect(fresh.contains("You're in a new git worktree of this repository, detached at origin/main."))
        let existing = prompt(choice(onBranch, reasons: [], active: 0), .workItem(item))
        #expect(existing.hasPrefix("Work on Azure DevOps Task 4217: Show the total\nhttps://dev.azure.com/contoso/Storefront/_workitems/edit/4217"))
        #expect(existing.contains("git status"))
        #expect(!existing.contains("new git worktree"))
        #expect(!existing.contains("{"))
    }

    /// Reset goes back to the prompt BriefBar wrote for the session you chose, with that session's checks, even when you'd
    /// changed the prompt before you chose it; and a prompt you changed stays as you wrote it.
    @Test func resetGoesBackToThePromptForTheSessionYouChose() {
        let worktree = "You're in a git worktree of this repository, detached at origin/fix-totals."
        let session = "Work on its branch in a clone of shop-web. If it has changes of its own, ask me where to work."
        func written(_ choice: SessionChoice?) -> String {
            CopilotComposerView.writtenPrompt(
                for: choice, subject: subject, template: "", worktreePrompt: worktree, sessionPrompt: session, baseBranch: nil
            )
        }
        let appSession = choice(onBranch, reasons: [.onItsBranch], active: 0)
        #expect(written(nil) == worktree)
        #expect(written(appSession) == session)

        // Unchanged, the prompt follows the session you choose.
        var shown = CopilotComposerView.rewritten(prompt: worktree, filledIn: worktree, written: written(appSession))
        #expect(shown.prompt == session)
        #expect(shown.filledIn == session)

        // Changed for a new session, then another session chosen: it stays as you wrote it, and Reset goes back to the
        // prompt for the session you chose, not the one for a new worktree.
        let edited = worktree + " Mind the rounding tests."
        shown = CopilotComposerView.rewritten(prompt: edited, filledIn: worktree, written: written(appSession))
        #expect(shown.prompt == edited)
        #expect(shown.filledIn == session)
        // Back to a new session: still as you wrote it, and Reset goes back to the worktree's again.
        shown = CopilotComposerView.rewritten(prompt: shown.prompt, filledIn: shown.filledIn, written: written(nil))
        #expect(shown.prompt == edited)
        #expect(shown.filledIn == worktree)
    }

    /// What BriefBar finds later doesn't move a task you chose a session for, nor one whose prompt you changed for where it
    /// goes now, nor Push & Reply.
    @Test func keepsWhereItGoesOnceYouChooseOrChangeThePrompt() {
        #expect(CopilotComposerView.followsSuggestions(choseTarget: false, mustContinue: false, promptChanged: false))
        #expect(!CopilotComposerView.followsSuggestions(choseTarget: true, mustContinue: false, promptChanged: false))
        #expect(!CopilotComposerView.followsSuggestions(choseTarget: false, mustContinue: true, promptChanged: false))
        #expect(!CopilotComposerView.followsSuggestions(choseTarget: false, mustContinue: false, promptChanged: true))
    }

    // MARK: Going on with a session

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

    /// A pull request's task that goes on with the session of the work item's task that opened it shows on the pull request's
    /// row as you send it, so no other task starts on it meanwhile. If it can't start, the run it went on with stays as it
    /// was, to go on with again; once it starts, it's the pull request's task, and still the work item's.
    @Test func showsATaskGoingOnWithTheWorkItemsSessionOnThePullRequestAtOnce() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let worktree = home.appendingPathComponent("copilot-worktrees/shop-web/wi-4217", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let store = store(home: home)
        defer { store.stop() }
        let opened = run(opener, worktree: worktree, workItem: 4217, opened: 4071)
        store.settings.copilotRuns = [opened]
        let key = PRKey("Contoso", 4071)
        let item = WorkItem(
            id: 4217, organization: "Contoso", project: "Storefront", type: "Task", title: "Show the order total in the cart",
            state: "Active", category: .inProgress
        )
        #expect(store.latest(forPullRequest: key) == nil)

        let launches = Mutex(0)
        store.launchForTests = { _, _, _ in
            launches.withLock { $0 += 1 }
            throw LaunchError.couldntStart("its worktree is busy")
        }
        store.send(subject, prompt: "Fix the comments", options: CopilotModel.quick, repository: worktree, continuing: opened)

        // As you send it, before it launches: on the pull request's row and the work item's, getting ready, and busy.
        let sending = try #require(store.latest(forPullRequest: key))
        #expect(sending.id == opener)
        #expect(sending.action == .fixComments)
        #expect(sending.options == CopilotModel.quick)
        #expect(sending.status.phase == .preparing)
        #expect(sending.run == opened)
        #expect(sending.workItem == opened.workItem)
        #expect(store.latest(for: item)?.id == opener)
        #expect(store.entries.count == 1)
        #expect(store.isWorking(inSession: opener))
        #expect(store.isWorking(inFolder: worktree))
        #expect(store.taskChoices(for: subject).first?.isBusy == true)
        #expect(store.continuable(forPullRequest: key) == nil)

        // It couldn't start: the pull request's row says so, and the run it went on with is as it was.
        for _ in 0..<100 where store.statuses[opener]?.phase != .failed {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(launches.withLock { $0 } == 1)
        let failed = try #require(store.latest(forPullRequest: key))
        #expect(failed.status.phase == .failed)
        #expect(failed.run == opened)
        #expect(store.settings.copilotRuns == [opened])
        #expect(!store.isWorking(inSession: opener))
        #expect(!store.isWorking(inFolder: worktree))
        let retry = try #require(store.continuable(forPullRequest: key))
        #expect(retry == opened)

        // Again, and it starts: the run is the pull request's task now, and still the work item's.
        store.launchForTests = { request, _, now in
            guard case .pullRequest(let pullRequest, let action) = request.subject, var run = request.continuing else {
                throw LaunchError.couldntStart("no session")
            }
            run.onPullRequest = pullRequest.reference
            run.action = action
            run.pullRequest = pullRequest.url
            run.startedAt = now
            run.ended = nil
            return run
        }
        store.send(subject, prompt: "Fix the comments", options: CopilotModel.quick, repository: worktree, continuing: retry)
        for _ in 0..<100 where store.settings.copilotRuns.first?.onPullRequest == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let started = try #require(store.settings.copilotRuns.first)
        #expect(store.settings.copilotRuns.count == 1)
        #expect(started.onPullRequest == pullRequest.reference)
        #expect(started.workItem == opened.workItem)
        #expect(store.pending.isEmpty)
        #expect(store.latest(forPullRequest: key)?.run == started)
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
