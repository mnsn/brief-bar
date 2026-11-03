import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import SQLite3
import SwiftUI
import Synchronization
import Testing
@testable import AzureDevOpsUI

/// The Copilot session of a pull request whose details show (`PullRequestSessions`), kept up to date while they show it: as
/// you choose another, as Send Work to Copilot goes off and on, as the Copilot app opens it and as BriefBar's tasks work in
/// its checkout; only what Show Links knows without Send Work to Copilot, and nothing without either; and the demo's, made
/// up. On the demo's made-up !4088, with made-up sessions in a folder of their own.
@MainActor
@Suite struct PullRequestSessionsTests {
    private let now = Date()
    private let onBranch = "44444444-4444-4444-8444-444444444444"
    private let other = "77777777-7777-4777-8777-777777777777"
    private let task = "11111111-1111-4111-8111-111111111111"
    private let key = PRKey("contoso", 4088)

    private struct DatabaseError: Error {
        var message: String
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BriefBarPullRequestSessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A stand-in for the Copilot app's `data.db`: two sessions in shop-web, one on !4088's branch; or these, in docs, on no
    /// pull request's branch.
    private func database(at home: URL, elsewhere: [String] = []) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("data.db").path, &handle) == SQLITE_OK else { throw DatabaseError(message: "no database") }
        defer { sqlite3_close(handle) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let (created, updated, older) = (formatter.string(from: now.addingTimeInterval(-30 * 86_400)),
                                         formatter.string(from: now.addingTimeInterval(-300)),
                                         formatter.string(from: now.addingTimeInterval(-7_200)))
        let sessions = elsewhere.isEmpty
            ? """
                INSERT INTO sessions (id, title, session_type, created_at, updated_at)
                    VALUES ('\(onBranch)', 'Delivery estimates', 'project', '\(created)', '\(updated)'),
                           ('\(other)', 'Shipping rules', 'project', '\(created)', '\(older)');
                INSERT INTO workspaces (id, project_id, session_id, branch, name, updated_at)
                    VALUES ('w1', 'shop', '\(onBranch)', 'delivery-estimates', 'Delivery estimates', '\(updated)'),
                           ('w2', 'shop', '\(other)', 'shipping', 'Shipping rules', '\(older)');
                """
            : elsewhere.enumerated().map { index, id in
                """
                INSERT INTO sessions (id, title, session_type, created_at, updated_at) VALUES ('\(id)', 'Docs', 'project', '\(created)', '\(updated)');
                INSERT INTO workspaces (id, project_id, session_id, branch, name, updated_at) VALUES ('w\(index)', 'shop', '\(id)', 'docs-\(index)', 'Docs', '\(updated)');
                """
            }.joined(separator: "\n")
        let statements = """
            BEGIN;
            CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, github_owner TEXT, github_repo TEXT, main_repo_path TEXT);
            CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL, title TEXT, session_type TEXT NOT NULL, mode TEXT,
                is_running INTEGER NOT NULL DEFAULT 0, was_interrupted INTEGER NOT NULL DEFAULT 0, interruption_reason TEXT,
                created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT);
            CREATE TABLE workspaces (id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL, session_id TEXT, branch TEXT NOT NULL,
                name TEXT NOT NULL, creator_session_id TEXT, archived_at TEXT, updated_at TEXT NOT NULL,
                source_pr_repo_full_name TEXT, source_pr_number INTEGER, source_pr_html_url TEXT,
                created_pr_repo_full_name TEXT, created_pr_number INTEGER, created_pr_html_url TEXT);
            CREATE TABLE workspace_pull_request_links (workspace_id TEXT PRIMARY KEY NOT NULL, uri TEXT NOT NULL);
            INSERT INTO projects (id, name) VALUES ('shop', 'shop-web');
            \(sessions)
            COMMIT;
            """
        guard sqlite3_exec(handle, statements, nil, nil, nil) == SQLITE_OK else { throw DatabaseError(message: String(cString: sqlite3_errmsg(handle))) }
    }

    /// The session on !4088's branch, as the Copilot CLI and the app keep it: its log, and the folder it works in.
    private func sessionState(_ id: String, home: URL, folder: URL) throws {
        let state = home.appendingPathComponent("session-state/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data().write(to: state.appendingPathComponent("events.jsonl"))
        try Data("cwd: \(folder.path)\n".utf8).write(to: state.appendingPathComponent("workspace.yaml"))
    }

    private func copilot(home: URL?, mode: PRStore.Mode = .live) -> CopilotTasksStore {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        let store = CopilotTasksStore(settings: settings, mode: mode, notifier: nil)
        if let home {
            store.appHomeForTests = home
            store.useEnvironment(["COPILOT_HOME": home.path, "PATH": "/usr/bin:/bin"])
        }
        store.opensLinksForTests = true
        return store
    }

    /// The demo's pull request, made up: !4088 in shop-web, from delivery-estimates into main.
    private func pullRequest(_ number: Int = 4088) async throws -> (PRSnapshot, PRRecord) {
        let read = await AzureDevOpsReader(demo: true, organizations: [], defaults: MemoryDefaults()).pullRequests(now: now)
        let record = try #require(read.records.first { $0.id.number == number })
        let item = try #require(read.items.first { $0.key.number == number })
        return (item, record)
    }

    /// Between reads, in the tests that follow a pull request: often enough for them, without holding up the tests that run
    /// beside them on the one thread they share (`LIBDISPATCH_COOPERATIVE_POOL_STRICT`).
    private let refresh: Duration = .milliseconds(250)

    /// The window's page the details are on, which a window shows on screen unless a test says otherwise.
    private let page = PullRequestCodeStore.page(.azureDevOpsPullRequests, window: "1")

    /// Follows a pull request as its details on `page` do, while a window shows `page` on screen.
    private func followOnScreen(_ sessions: PullRequestSessions, _ item: PRSnapshot, record: PRRecord?) -> Task<Void, Never> {
        sessions.setVisible(true, for: page)
        return Task { await sessions.follow(item, record: record, on: page) }
    }

    /// Waits, a little at a time, until something is so, as the store reads and keeps up off the main thread: for as long
    /// as a busy Mac may take, since it stops as soon as it is.
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<2_400 where !condition() {
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: Following it

    @Test func followsItsSessionAsYouChooseAndAsSendingGoesOffAndOn() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home)
        let store = copilot(home: home)
        let sessions = PullRequestSessions(copilot: store, links: Links(defaults: MemoryDefaults(), isDemo: false))
        sessions.refreshEvery = refresh
        let (item, record) = try await pullRequest()
        sessions.record = { $0 == item.key ? record : nil }

        let following = followOnScreen(sessions, item, record: record)
        try await until { sessions.session(for: key)?.session?.id == onBranch }
        var session = try #require(sessions.session(for: key))
        #expect(session.basis == .onItsBranch)
        #expect(session.canChoose)
        #expect(session.candidates.map(\.id) == [onBranch])
        #expect(session.others.map(\.id) == [other])

        // You choose another for its work: from then on, wherever it's from.
        let shipping = try #require(session.others.first)
        sessions.use(shipping, for: key)
        try await until { sessions.session(for: key)?.basis == .chosenByYou }
        session = try #require(sessions.session(for: key))
        #expect(session.session?.id == other)
        #expect(store.settings.chosenSession(for: key)?.session == ItemRef.session(other))
        sessions.use(nil, for: key)
        try await until { sessions.session(for: key)?.pick == .newSession(chosenByYou: true) }
        sessions.letBriefBarChoose(for: key)
        try await until { sessions.session(for: key)?.basis == .onItsBranch }
        #expect(store.settings.chosenSession(for: key) == nil)

        // Send Work to Copilot off: without Show Links, nothing; what was read goes, and nothing can be chosen.
        store.settings.copilotEnabled = false
        try await until { sessions.session(for: key) == nil }
        #expect(sessions.session(for: key) == nil)
        sessions.use(shipping, for: key)
        #expect(store.settings.chosenSession(for: key) == nil)
        // On again: read again.
        store.settings.copilotEnabled = true
        try await until { sessions.session(for: key)?.session?.id == onBranch }
        #expect(sessions.session(for: key)?.session?.id == onBranch)

        // Closed: no longer followed, nor read, but kept a while, for its details to show it at once when they show again.
        following.cancel()
        await following.value
        #expect(sessions.session(for: key)?.session?.id == onBranch)
    }

    /// Of the pull requests no longer followed, the last eight whose details showed keep their sessions; the others go.
    @Test func keepsTheSessionsOfTheLastFewWhoseDetailsShowed() async throws {
        let store = copilot(home: nil, mode: .demo)
        let sessions = PullRequestSessions(copilot: store, links: Links(defaults: MemoryDefaults(), isDemo: false))
        let read = await AzureDevOpsReader(demo: true, organizations: [], defaults: MemoryDefaults()).pullRequests(now: now)
        let open = read.items.filter { item in read.records.first { $0.id == item.key }?.pullRequest.status == .active }
        #expect(open.count > PullRequestSessions.keptLimit)
        sessions.record = { key in read.records.first { $0.id == key } }
        for item in open {
            let following = followOnScreen(sessions, item, record: sessions.record(item.key))
            try await until { sessions.session(for: item.key) != nil }
            following.cancel()
            await following.value
        }
        let kept = open.filter { sessions.session(for: $0.key) != nil }.map(\.key)
        #expect(kept == open.suffix(PullRequestSessions.keptLimit).map(\.key))
        sessions.stopAll()
        #expect(open.allSatisfy { sessions.session(for: $0.key) == nil })
    }

    /// How work would reach its session, kept up to date while its details show, as the Send to Copilot window would send
    /// it: its last task's session with the CLI while it's free; in the Copilot app once the app opens it, as BriefBar's
    /// extension can reach it; busy while another task of BriefBar's works in its checkout; and, once there's no task, the
    /// app's session on its branch in the app.
    @Test func saysHowWorkWouldReachItAsThatChanges() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home)
        let worktree = home.appendingPathComponent("copilot-worktrees/shop-web/pr-4088", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let store = copilot(home: home)
        let reference = PullRequestReference(
            organization: "contoso", project: "Storefront", repository: "shop-web", id: 4088, sourceBranch: "delivery-estimates"
        )
        let lastTask = CopilotRun(
            id: task, workItem: nil, onPullRequest: reference, action: .fixBuild, options: CopilotModel.standard,
            repository: worktree.deletingLastPathComponent(), worktree: worktree, startedAt: now.addingTimeInterval(-3_600),
            process: DetachedProgram.Handle(pid: 0, startedAt: nil), ended: .finished
        )
        store.settings.copilotRuns = [lastTask]
        let sessions = PullRequestSessions(copilot: store, links: Links(defaults: MemoryDefaults(), isDemo: false))
        sessions.refreshEvery = refresh
        let (item, record) = try await pullRequest()
        sessions.record = { $0 == item.key ? record : nil }
        let following = followOnScreen(sessions, item, record: record)
        defer { following.cancel() }

        try await until { sessions.session(for: key)?.delivery == .cli }
        #expect(sessions.session(for: key)?.basis == .lastTask)
        #expect(sessions.session(for: key)?.delivery == .cli)

        // The Copilot app opens it: this test's process stands in for it. Send Prompts to Copilot Sessions is off, so the
        // prompt would be copied for you to paste there.
        let state = home.appendingPathComponent("session-state/\(task)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let lock = state.appendingPathComponent("inuse.\(getpid()).lock")
        try Data().write(to: lock)
        let opened = PullRequestSession.Delivery.app(
            reach: .off, reason: "The Copilot app has it open: Copilot can go on with it only there, where its history is."
        )
        try await until { sessions.session(for: key)?.delivery == opened }
        #expect(sessions.session(for: key)?.delivery == opened)
        try FileManager.default.removeItem(at: lock)
        try await until { sessions.session(for: key)?.delivery == .cli }
        #expect(sessions.session(for: key)?.delivery == .cli)

        // A task BriefBar sent for another pull request works in the same checkout.
        let elsewhere = worktree.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        store.settings.copilotRuns = [lastTask, CopilotRun(
            id: other, workItem: nil,
            onPullRequest: PullRequestReference(organization: "contoso", project: "Storefront", repository: "shop-web", id: 5000, sourceBranch: "other"),
            action: .fixComments, options: CopilotModel.standard, repository: worktree, worktree: elsewhere, startedAt: now,
            process: DetachedProgram.Handle(pid: getpid(), startedAt: nil)
        )]
        let busy = PullRequestSession.Delivery.busy("Copilot is working in its checkout for another task BriefBar sent.")
        try await until { sessions.session(for: key)?.delivery == busy }
        #expect(sessions.session(for: key)?.session?.isFolderBusy == true)
        #expect(sessions.session(for: key)?.delivery == busy)
        // It's done.
        store.settings.copilotRuns = [lastTask]
        try await until { sessions.session(for: key)?.delivery == .cli }
        #expect(sessions.session(for: key)?.delivery == .cli)

        // No task: the app's session on its branch, in the app.
        store.settings.copilotRuns = []
        try await until { sessions.session(for: key)?.session?.id == onBranch && sessions.session(for: key)?.delivery != nil }
        #expect(sessions.session(for: key)?.delivery == .app(reach: .off, reason: nil))
    }

    /// How work would reach its session is checked once, then with each read: not again and again as it's kept.
    @Test func checksHowWorkWouldReachItOnceEachRead() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home)
        let store = copilot(home: home)
        let sessions = PullRequestSessions(copilot: store, links: Links(defaults: MemoryDefaults(), isDemo: false))
        // Between reads, an hour: one read, however slow the Mac.
        sessions.refreshEvery = .seconds(3_600)
        let (item, record) = try await pullRequest()
        sessions.record = { $0 == item.key ? record : nil }
        var checked: [String] = []
        sessions.deliveryCheckedForTests = { checked.append($0) }
        let following = followOnScreen(sessions, item, record: record)
        defer { following.cancel() }

        try await until { sessions.session(for: key)?.delivery != nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(checked == [onBranch])
    }

    /// Its sessions are read only while a window shows its details' page on screen: as it does, at once, with how work
    /// would reach its session; not while it's minimized, hidden or covered, however often it would be; nor for another
    /// window's page.
    @Test func readsOnlyWhileAWindowShowsItsDetailsOnScreen() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home)
        let store = copilot(home: home)
        let sessions = PullRequestSessions(copilot: store, links: Links(defaults: MemoryDefaults(), isDemo: false))
        // Between reads, an hour: what's read is what showing it reads.
        sessions.refreshEvery = .seconds(3_600)
        let (item, record) = try await pullRequest()
        sessions.record = { $0 == item.key ? record : nil }
        var checked = 0
        sessions.deliveryCheckedForTests = { _ in checked += 1 }
        let following = Task { await sessions.follow(item, record: record, on: page) }
        defer { following.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(sessions.session(for: item.key) == nil && checked == 0)

        sessions.setVisible(true, for: page)
        try await until { sessions.session(for: item.key)?.delivery != nil }
        #expect(sessions.session(for: item.key)?.session?.id == onBranch && checked == 1)

        sessions.setVisible(false, for: page)
        sessions.setVisible(true, for: PullRequestCodeStore.page(.azureDevOpsSprint, window: "2"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(checked == 1)
        sessions.setVisible(true, for: page)
        try await until { checked == 2 }
        #expect(checked == 2)
        following.cancel()

        // Every quarter second, while covered: nothing's read.
        sessions.setVisible(false, for: page)
        sessions.refreshEvery = refresh
        let covered = Task { await sessions.follow(item, record: record, on: page) }
        defer { covered.cancel() }
        try await Task.sleep(for: .milliseconds(1_000))
        #expect(checked == 2)
    }

    /// Shown again while a read that going off screen called off is still ending, it's read again as that read ends, rather
    /// than at the next turn.
    @Test func readsAgainWhenShownWhileAReadWasCalledOff() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        // Sessions on other branches, whose logs are searched since none goes with it.
        let ids = ["aaaaaaaa-aaaa-4aaa-8aaa-000000000001", "aaaaaaaa-aaaa-4aaa-8aaa-000000000002", "aaaaaaaa-aaaa-4aaa-8aaa-000000000003"]
        try database(at: home, elsewhere: ids)
        for id in ids {
            let state = home.appendingPathComponent("session-state/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: state.appendingPathComponent("events.jsonl"))
        }
        let store = copilot(home: home)
        let sessions = PullRequestSessions(copilot: store, links: Links(defaults: MemoryDefaults(), isDemo: false))
        sessions.refreshEvery = .seconds(3_600)
        let (item, record) = try await pullRequest()
        sessions.record = { $0 == item.key ? record : nil }
        var searched = 0
        store.mentionReadForTests = { _ in
            searched += 1
            // Covered, then shown again, as the first log is read.
            if searched == 1 {
                sessions.setVisible(false, for: self.page)
                sessions.setVisible(true, for: self.page)
            }
        }
        let following = followOnScreen(sessions, item, record: record)
        defer { following.cancel() }
        try await until { searched >= 1 + ids.count }
        #expect(searched == 1 + ids.count)
    }

    /// Two pull requests whose work goes to the same session each say how work would reach it.
    @Test func checksTheSessionOfEachPullRequestItsWorkGoesFrom() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home)
        let store = copilot(home: home)
        let sessions = PullRequestSessions(copilot: store, links: Links(defaults: MemoryDefaults(), isDemo: false))
        sessions.refreshEvery = .seconds(3_600)
        let (first, firstRecord) = try await pullRequest()
        let (second, secondRecord) = try await pullRequest(4091)
        let records = [first.key: firstRecord, second.key: secondRecord]
        sessions.record = { records[$0] }
        store.settings.choose(session: onBranch, for: second.key)
        let one = followOnScreen(sessions, first, record: firstRecord)
        let two = followOnScreen(sessions, second, record: secondRecord)
        defer {
            one.cancel()
            two.cancel()
        }
        try await until { sessions.session(for: first.key)?.delivery != nil && sessions.session(for: second.key)?.delivery != nil }
        #expect(sessions.session(for: first.key)?.session?.id == onBranch && sessions.session(for: second.key)?.session?.id == onBranch)
        #expect(sessions.session(for: first.key)?.delivery != nil && sessions.session(for: second.key)?.delivery != nil)
    }

    /// A closed pull request's work goes nowhere: its details show the sessions Show Links links to it, to look at, and
    /// nothing of Copilot's is read for it, though Send Work to Copilot is on.
    @Test func readsNothingForAClosedPullRequest() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home)
        let store = copilot(home: home)
        let links = Links(defaults: MemoryDefaults(), isDemo: false)
        links.setOn(true)
        let sessions = PullRequestSessions(copilot: store, links: links)
        sessions.refreshEvery = refresh
        let (item, record) = try await pullRequest(4085)
        #expect(record.pullRequest.status == .completed)
        sessions.record = { $0 == item.key ? record : nil }
        let ref = try #require(ItemRef.session(onBranch))
        links.publish(.copilot, links: [try #require(ItemLink(ref, item.key.linkRef, origin: .copilot))], items: [LinkedItem(
            ref: ref, label: "Update the badges", title: "Update the badges", symbol: "waveform.path.ecg", color: .pink,
            status: "Finished", date: now
        )])
        var checked = 0
        sessions.deliveryCheckedForTests = { _ in checked += 1 }
        var read = 0
        store.mentionReadForTests = { _ in read += 1 }
        let following = followOnScreen(sessions, item, record: record)
        defer { following.cancel() }

        try await until { sessions.session(for: item.key) != nil }
        try await Task.sleep(for: .milliseconds(300))
        let session = try #require(sessions.session(for: item.key))
        #expect(!session.canChoose)
        #expect(session.basis == .recordedByCopilot)
        #expect(session.delivery == nil)
        #expect(checked == 0 && read == 0)
    }

    /// Turned off, as when Azure DevOps stops, a search of the logs for mentions under way stops before the next log; and a
    /// search whose task is cancelled, such as one for details that closed, reads none.
    @Test func stopsASearchUnderWayWhenItStops() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        // Three of the app's sessions active since !4088 was created, on other branches, whose logs don't mention it: none
        // goes with it, so their logs are searched.
        let ids = ["aaaaaaaa-aaaa-4aaa-8aaa-000000000001", "aaaaaaaa-aaaa-4aaa-8aaa-000000000002", "aaaaaaaa-aaaa-4aaa-8aaa-000000000003"]
        try database(at: home, elsewhere: ids)
        for id in ids {
            let state = home.appendingPathComponent("session-state/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: state.appendingPathComponent("events.jsonl"))
        }
        let store = copilot(home: home)
        let (item, record) = try await pullRequest()
        var read: [String] = []
        store.mentionReadForTests = { read.append($0) }

        let choices = ids.map { id in
            SessionChoice(kind: .app(AppSession(id: id, name: id, lastActive: now)), name: id, lastActive: now, reasons: [])
        }
        let subject = TaskSubject.pullRequest(PullRequestTasks.task(for: record), .fixComments)
        let searching = Task { await store.sessionsMentioning(subject, among: choices, since: .distantPast) }
        searching.cancel()
        #expect(await searching.value.isEmpty)
        #expect(read.isEmpty)
        // Nor a check of how work would reach one.
        let checking = Task { await store.cliProblem(for: choices[0], subject: subject) }
        checking.cancel()
        #expect(await checking.value == CopilotTasksStore.stoppedChecking)
        // Nor does a look for the sessions it could go to, cancelled as the details that wanted them close.
        let looking = Task { await store.sessionChoices(for: subject) }
        looking.cancel()
        #expect(await looking.value.isEmpty)
        #expect(await store.sessionChoices(for: subject).count == ids.count)

        let sessions = PullRequestSessions(copilot: store, links: Links(defaults: MemoryDefaults(), isDemo: false))
        sessions.record = { $0 == item.key ? record : nil }
        // Between reads, an hour: only stopping ends it.
        sessions.refreshEvery = .seconds(3_600)
        store.mentionReadForTests = { id in
            read.append(id)
            sessions.stopAll()
        }
        let following = followOnScreen(sessions, item, record: record)
        // Should it not stop, the test ends all the same, and says so, however slow the Mac.
        let gaveUp = Mutex(false)
        let limit = Task {
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            gaveUp.withLock { $0 = true }
            following.cancel()
        }
        await following.value
        limit.cancel()
        #expect(!gaveUp.withLock { $0 })
        #expect(read.count == 1)
        #expect(sessions.session(for: item.key) == nil)
    }

    // MARK: Without Send Work to Copilot

    /// Only what Show Links knows: the sessions it links to it, to look at, with nothing to choose; nothing of Copilot's is
    /// read for it. Without Show Links either, nothing.
    @Test func showsOnlyShowLinksSessionsWithoutSending() async throws {
        let store = copilot(home: URL(fileURLWithPath: "/nonexistent"))
        store.settings.copilotEnabled = false
        let links = Links(defaults: MemoryDefaults(), isDemo: false)
        links.setOn(true)
        let sessions = PullRequestSessions(copilot: store, links: links)
        sessions.refreshEvery = refresh
        let (item, record) = try await pullRequest()
        sessions.record = { $0 == item.key ? record : nil }
        let ref = try #require(ItemRef.session(onBranch))
        links.publish(.copilot, links: [try #require(ItemLink(ref, key.linkRef, origin: .branch))], items: [LinkedItem(
            ref: ref, label: "Delivery estimates", title: "Delivery estimates", symbol: "waveform.path.ecg", color: .pink,
            state: .needsYou, status: "Waiting for your answer", place: "shop-web · delivery-estimates", date: now
        )])

        let following = followOnScreen(sessions, item, record: record)
        defer { following.cancel() }
        try await until { sessions.session(for: key) != nil }
        let session = try #require(sessions.session(for: key))
        #expect(!session.canChoose)
        #expect(session.session?.name == "Delivery estimates")
        #expect(session.basis == .onItsBranch)
        #expect(session.others.isEmpty)
        let standing = PullRequestSessionLine.standing(of: try #require(session.session), links: links, entries: [])
        #expect(standing.text == "Waiting for your answer")
        #expect(standing.state == .needsYou)
        #expect(standing.phrase(now: now) == "waiting for your answer")
        #expect(PullRequestSessionLine.shows(session))

        // Show Links off too: nothing.
        links.setOn(false)
        try await until { sessions.session(for: key) == nil }
        #expect(sessions.session(for: key) == nil)
    }

    // MARK: The demo

    /// The demo's made-up tasks: the one fixing !4088's build, still working, so busy; the work item's task that opened
    /// !4091. Nothing's read.
    @Test func makesUpTheDemosFromItsTasks() async throws {
        let store = copilot(home: nil, mode: .demo)
        let sessions = PullRequestSessions(copilot: store, links: Links(defaults: MemoryDefaults(), isDemo: true))
        let (failing, failingRecord) = try await pullRequest(4088)
        let (opened, openedRecord) = try await pullRequest(4091)
        let records = [failing.key: failingRecord, opened.key: openedRecord]
        sessions.record = { records[$0] }
        await sessions.prepare([failing, opened])

        let fixing = try #require(sessions.session(for: failing.key))
        #expect(fixing.basis == .lastTask)
        #expect(fixing.session.map(PullRequestSession.name) == "Fix the Build")
        #expect(fixing.session?.isBusy == true)
        #expect(fixing.delivery == .busy("Copilot is still working in it."))
        let standing = PullRequestSessionLine.standing(of: try #require(fixing.session), links: sessions.links, entries: store.entries)
        #expect(standing.text == "Working" && standing.state == .running)

        let opener = try #require(sessions.session(for: opened.key))
        #expect(opener.basis == .openedIt)
        #expect(opener.session.map(PullRequestSession.name) == "Work Item 5112")
        #expect(opener.delivery == .cli)
        // What part 9 asks for a pull request that doesn't show, the same.
        let found = try #require(await sessions.find(openedRecord))
        #expect(found.session?.id == opener.session?.id && found.basis == .openedIt && found.delivery == .cli)
    }

    // MARK: Pictures

    /// For pictures, each pull request's sessions are read once, and that's all: neither a search of the logs for mentions,
    /// nor a check of how work would reach its session, which pictures don't show, nor another read.
    @Test func readsOnlyTheSessionsForPictures() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home)
        // Logs that would be searched.
        for id in [onBranch, other] {
            let state = home.appendingPathComponent("session-state/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: state.appendingPathComponent("events.jsonl"))
        }
        let store = copilot(home: home)
        var searched = 0
        store.mentionReadForTests = { _ in searched += 1 }
        // !4088's session is on its branch; none goes with !4091.
        let (onIt, onItRecord) = try await pullRequest()
        let (none, noneRecord) = try await pullRequest(4091)
        let records = [onIt.key: onItRecord, none.key: noneRecord]

        let sessions = PullRequestSessions(copilot: store, links: Links(defaults: MemoryDefaults(), isDemo: false))
        sessions.refreshEvery = refresh
        sessions.record = { records[$0] }
        var checked = 0
        sessions.deliveryCheckedForTests = { _ in checked += 1 }
        await sessions.prepare([onIt, none])
        #expect(sessions.session(for: onIt.key)?.session?.id == onBranch)
        #expect(sessions.session(for: onIt.key)?.delivery == nil)
        #expect(sessions.session(for: none.key)?.pick == .newSession(chosenByYou: false))
        sessions.updateAll()
        try await Task.sleep(for: .milliseconds(300))
        #expect(checked == 0 && searched == 0)

        // As its details show it, its sessions' logs are searched.
        let shown = PullRequestSessions(copilot: store, links: Links(defaults: MemoryDefaults(), isDemo: false))
        shown.record = { records[$0] }
        let task = followOnScreen(shown, none, record: noneRecord)
        defer { task.cancel() }
        try await until { searched > 0 }
        #expect(searched > 0)
    }

    // MARK: How the line says it

    @Test func saysWhyAndHowEachStands() throws {
        let links = Links(defaults: MemoryDefaults(), isDemo: false)
        let app = AppSession(id: onBranch, name: "Retry backoff", lastActive: now.addingTimeInterval(-26 * 3_600))
        let choice = SessionChoice(kind: .app(app), name: "Retry backoff", place: "payments-api · payments-retry", lastActive: app.lastActive, reasons: [.onItsBranch, .mentionsIt])
        let session = PullRequestSession.make([choice], chosen: nil, lastTask: nil, createdAt: nil, canChoose: true)
        #expect(PullRequestSessionLine.why(choice, in: session) == "on its branch")
        let quiet = PullRequestSessionLine.standing(of: choice, links: links, entries: [])
        #expect(quiet == PullRequestSessionLine.Standing(text: "", state: nil, date: app.lastActive))
        #expect(quiet.phrase(now: now) == "active 1d ago")
        #expect(PullRequestSessionLine.menuTitle(of: choice, in: session, links: links, entries: [], now: now)
            == "‘Retry backoff’ — on its branch · active 1d ago")

        // As Copilot's list tells it, through Show Links.
        links.setOn(true)
        let ref = try #require(ItemRef.session(onBranch))
        links.publish(.copilot, links: [], items: [LinkedItem(
            ref: ref, label: "Retry backoff", title: "Retry backoff", symbol: "checkmark.circle.fill", color: .secondary,
            status: "Finished", date: now.addingTimeInterval(-26 * 3_600)
        )])
        let finished = PullRequestSessionLine.standing(of: choice, links: links, entries: [])
        #expect(finished.text == "Finished" && finished.state == nil)
        #expect(finished.phrase(now: now) == "finished 1d ago")

        // The app has it open; its checkout's busy.
        var open = choice
        open.isOpenInApp = true
        #expect(PullRequestSessionLine.menuTitle(of: open, in: session, links: links, entries: [], now: now)
            == "‘Retry backoff’ — on its branch · finished 1d ago · open in Copilot")
        var busy = choice
        busy.isFolderBusy = true
        #expect(PullRequestSessionLine.standing(of: busy, links: links, entries: []).phrase(now: now) == "busy")
        // What needs you, or works, says so without since when, which the line shows apart.
        let waiting = PullRequestSessionLine.Standing(text: "Waiting for your answer", state: .needsYou, date: now.addingTimeInterval(-240))
        #expect(waiting.phrase(now: now) == "waiting for your answer")

        // A task of BriefBar's that's done, which you went on with in the Copilot app: as Copilot's list tells its session
        // while it waits for you there, though the task's own row, Azure DevOps', says it finished; once it's done there
        // too, as the task.
        let worktree = URL(fileURLWithPath: "/tmp/pr-4088")
        let run = CopilotRun(
            id: onBranch, workItem: nil,
            onPullRequest: PullRequestReference(organization: "contoso", project: "Storefront", repository: "shop-web", id: 4088, sourceBranch: "delivery-estimates"),
            action: .fixComments, options: CopilotModel.standard, repository: worktree.deletingLastPathComponent(), worktree: worktree,
            startedAt: now.addingTimeInterval(-7_200), process: DetachedProgram.Handle(pid: 0, startedAt: nil), ended: .finished, pullRequest: nil
        )
        let entry = CopilotTaskEntry(
            id: onBranch, workItem: nil, onPullRequest: run.onPullRequest, action: .fixComments, options: CopilotModel.standard,
            startedAt: run.startedAt, status: RunStatus(phase: .finished, since: now.addingTimeInterval(-3_600)), pullRequest: nil, run: run
        )
        let task = SessionChoice(kind: .task(run), name: "Fix Comments", place: nil, lastActive: run.startedAt, reasons: [.earlierTask])
        links.publish(.azureDevOps, links: [], items: [LinkedItem(
            ref: ref, label: "Fix Comments", title: "Copilot: Fix Comments", symbol: "paperplane.fill", color: .secondary,
            status: "Finished", date: now.addingTimeInterval(-3_600)
        )])
        links.publish(.copilot, links: [], items: [LinkedItem(
            ref: ref, label: "Retry backoff", title: "Retry backoff", symbol: "waveform.path.ecg", color: .orange, state: .needsYou,
            status: "Waiting for your answer", date: now.addingTimeInterval(-240)
        )])
        #expect(PullRequestSessionLine.standing(of: task, links: links, entries: [entry]) == waiting)
        links.publish(.copilot, links: [], items: [LinkedItem(
            ref: ref, label: "Retry backoff", title: "Retry backoff", symbol: "checkmark.circle.fill", color: .secondary,
            status: "Finished", date: now.addingTimeInterval(-120)
        )])
        let done = PullRequestSessionLine.standing(of: task, links: links, entries: [entry])
        #expect(done.text == RunPhase.finished.title && done.date == now.addingTimeInterval(-3_600))

        // Nothing's shown without a session, unless you can choose one.
        let none = PullRequestSession.make([], chosen: nil, lastTask: nil, createdAt: nil, canChoose: false)
        #expect(!PullRequestSessionLine.shows(none))
        #expect(PullRequestSessionLine.shows(PullRequestSession.make([], chosen: nil, lastTask: nil, createdAt: nil, canChoose: true)))
    }
}
