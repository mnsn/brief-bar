import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Darwin
import Foundation
import SQLite3
import Synchronization
import Testing
@testable import AzureDevOpsUI

/// BriefBar's extension in one of the Copilot app's sessions, as far as these tests need it: it says it listens, claims its
/// session's requests, and answers each as it's told. `CopilotOutboxTests` holds it to the contract.
private final class ExtensionStandIn: Sendable {
    /// How often it looks for requests, and BriefBar at the outbox, in these tests, as do the tests' own waits. Each look
    /// reads the outbox's folders, in many tests at once: looking every 25 ms rather than every 5, these tests use about a
    /// quarter less CPU, and take about as long.
    static let lookEvery: Duration = .milliseconds(25)

    let outbox: URL
    let sessionId: String
    /// What it was asked; the looking under way, and the token of the one `start` began last, which alone claims requests,
    /// until `stop()`.
    private let state = Mutex<(received: [String], task: Task<Void, Never>?, looking: UUID?)>(([], nil, nil))

    init(outbox: URL, sessionId: String) {
        self.outbox = outbox
        self.sessionId = sessionId
    }

    /// What it was asked, in order: `fork`, `stop`, or a send's prompt.
    var received: [String] { state.withLock { $0.received } }

    func listen(kinds: [String] = ["send", "fork"]) throws {
        let started = DetachedProgram.startTime(of: getpid()) ?? Date()
        try Self.write([
            "version": 1, "sessionId": sessionId, "pid": Int(getpid()), "kinds": kinds,
            "startedAt": started.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
        ], to: outbox.appendingPathComponent("listening"), named: "\(sessionId).json")
    }

    /// Takes its session's requests until `stop()`: what `answer` returns goes into each one's result, or none when nil.
    /// Started again, it answers as it's told then, and stops looking as it was told before. It looks on `TestThreads`,
    /// beside the tests, as an extension in another process would: so once `stop()` or `start` returns, a look begun before
    /// may still be under way, but claims nothing.
    func start(after delay: Duration = .zero, answer: @escaping @Sendable (_ kind: String) -> [String: Any]? = { _ in ["ok": true] }) {
        let looking = UUID()
        state.withLock {
            $0.task?.cancel()
            $0.looking = looking
            $0.task = Task(executorPreference: TestThreads.shared) { [self] in
                while !Task.isCancelled {
                    let requests = outbox.appendingPathComponent("requests")
                    for name in (try? FileManager.default.contentsOfDirectory(atPath: requests.path)) ?? []
                    where name.hasPrefix("\(sessionId).") && name.hasSuffix(".json") {
                        let claimed = requests.appendingPathComponent(".\(name.dropLast(".json".count)).claimed-\(getpid())")
                        // Claimed under the lock `start` and `stop()` take, only while this looking is still the one
                        // `start` began last: once either returns, an earlier look claims nothing.
                        guard state.withLock({ $0.looking == looking && rename(requests.appendingPathComponent(name).path, claimed.path) == 0 }),
                              let data = FileManager.default.contents(atPath: claimed.path),
                              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                              let kind = request["kind"] as? String, let requestId = request["requestId"] as? String
                        else { continue }
                        state.withLock { $0.received.append(kind == "send" ? request["prompt"] as? String ?? "" : kind) }
                        try? await Task.sleep(for: delay)
                        if let fields = answer(kind) {
                            let result = ["version": 1, "requestId": requestId, "sessionId": sessionId, "kind": kind].merging(fields) { $1 }
                            try? Self.write(result, to: outbox.appendingPathComponent("results"), named: "\(requestId).json")
                        }
                        try? FileManager.default.removeItem(at: claimed)
                    }
                    try? await Task.sleep(for: Self.lookEvery)
                }
            }
        }
    }

    func stop() {
        state.withLock {
            $0.task?.cancel()
            $0.looking = nil
        }
    }

    static func write(_ fields: [String: Any], to folder: URL, named name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = folder.appendingPathComponent(".\(name).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let data = try JSONSerialization.data(withJSONObject: fields)
        _ = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
        guard rename(temporary.path, folder.appendingPathComponent(name).path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// When the extension stand-in took a request.
private final class TakenAt: Sendable {
    private let taken = Mutex<Date?>(nil)

    var date: Date? { taken.withLock { $0 } }

    func stamp() {
        taken.withLock { $0 = $0 ?? Date() }
    }
}

/// Sending a prompt to one of the Copilot app's sessions, or to a fork of it, through BriefBar's extension in it
/// (`CopilotTasksStore.deliver`): only while Send Prompts to Copilot Sessions is on; and, when the extension can't,
/// copying the prompt for you to paste, as Open in Copilot did.
@MainActor
@Suite struct SessionDeliveryTests {
    private let session = "a4444444-4444-4444-8444-44444444444f"
    private let fork = "b5555555-5555-4555-8555-55555555555e"

    private var pullRequest: TaskPullRequest {
        TaskPullRequest(
            organization: "Contoso", project: "Storefront", repository: "shop-web", id: 4071, title: "Fix totals",
            url: URL(string: "https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/4071")!,
            sourceBranch: "fix-totals", targetBranch: "main"
        )
    }

    private var handOff: CommentHandOff {
        CommentHandOff(
            key: PRKey("contoso", 4071), waiting: [], account: nil, me: "me", dismissedCutoff: .distantPast, read: [:], unanswered: [:]
        )
    }

    private func choice(_ id: String, isChat: Bool = false) -> SessionChoice {
        SessionChoice(kind: .app(AppSession(id: id, name: "Fix the totals", isChat: isChat)), name: "Fix the totals", reasons: [.onItsBranch])
    }

    /// A store whose Copilot folder and outbox are in a temporary folder, with Send Prompts to Copilot Sessions on, that
    /// records what it shows, and what it copies and shows.
    private func store() throws -> (store: CopilotTasksStore, home: URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("BriefBarDelivery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        CopilotSessionPrompts.set(true, in: settings.defaults)
        let store = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        store.appHomeForTests = home
        store.outboxForTests = CopilotOutbox(root: home, path: ["Outbox"])
        store.useEnvironment(["COPILOT_HOME": home.path, "PATH": "/usr/bin:/bin"])
        // Whatever runs the tests, with or without the Copilot app: the app opens its links, and this test's own process
        // stands in for the app's runtime (`hold`). A test of a session that a CLI has open, or of a Mac without the app,
        // says so itself.
        store.appHoldsForTests = { $0 == getpid() }
        store.opensLinksForTests = true
        // Long enough for each step even while other tests keep the process busy for many seconds: a test that waits for
        // a step to time out shortens that step's.
        var timing = SessionSender.Timing()
        timing.poll = ExtensionStandIn.lookEvery
        timing.claim = 60
        timing.load = 60
        timing.listen = 60
        timing.sent = 60
        timing.forked = 60
        timing.confirm = 60
        store.deliveryTimingForTests = timing
        return (store, home)
    }

    private func requests(_ home: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Outbox/requests").path)) ?? []
    }

    /// The Copilot app has the session open, as its lock in the session's folder says: this test's own process stands in
    /// for the app's runtime.
    private func hold(_ id: String, home: URL) throws {
        let folder = home.appendingPathComponent("session-state/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("inuse.\(getpid()).lock"))
    }

    /// The session works in the folder, as its `workspace.yaml` says.
    private func work(_ id: String, in folder: URL, home: URL) throws {
        let state = home.appendingPathComponent("session-state/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("cwd: \(folder.path)\n".utf8).write(to: state.appendingPathComponent("workspace.yaml"))
    }

    /// The app's database, with the session and its fork, which it records as forked from `forkedFrom`.
    private func database(at home: URL, forkedFrom: String) throws {
        try database(at: home, forks: [(fork, forkedFrom, afterTheRequest())])
    }

    /// When the app made a fork after the request, however long this Mac takes to write it.
    private func afterTheRequest() -> String {
        Date().addingTimeInterval(600).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// The app's database, with the session and the forks it records: each one's ID, the session it was forked from, and
    /// when it was made; and other sessions, which are no forks.
    private func database(at home: URL, forks: [(id: String, original: String, created: String)], others: [String] = []) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("data.db").path, &handle) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(handle) }
        let statements = """
            CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL);
            CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL, title TEXT, session_type TEXT NOT NULL, mode TEXT,
                is_running INTEGER NOT NULL DEFAULT 0, was_interrupted INTEGER NOT NULL DEFAULT 0, interruption_reason TEXT,
                created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT, forked_from_session_id TEXT);
            CREATE TABLE workspaces (id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL, session_id TEXT, branch TEXT NOT NULL,
                name TEXT NOT NULL, creator_session_id TEXT, archived_at TEXT, updated_at TEXT NOT NULL);
            INSERT INTO projects (id, name) VALUES ('shop', 'shop-web');
            INSERT INTO sessions (id, title, session_type, created_at, updated_at)
                VALUES ('\(session)', 'Fix the totals', 'project', '2026-10-01T09:00:00.000Z', '2026-10-27T10:00:00.000Z');
            INSERT INTO workspaces (id, project_id, session_id, branch, name, updated_at)
                VALUES ('w1', 'shop', '\(session)', 'fix-totals', 'Fix the totals', '2026-10-27T10:00:00.000Z');
            """ + forks.enumerated().map { index, fork in """
                INSERT INTO sessions (id, title, session_type, created_at, updated_at, forked_from_session_id)
                    VALUES ('\(fork.id)', 'Fix the totals', 'project', '\(fork.created)', '\(fork.created)', '\(fork.original)');
                INSERT INTO workspaces (id, project_id, session_id, branch, name, updated_at)
                    VALUES ('w-fork-\(index)', 'shop', '\(fork.id)', 'fix-totals-fork', 'Fix the totals', '\(fork.created)');
                """ }.joined() + others.map { id in """
                INSERT INTO sessions (id, title, session_type, created_at, updated_at)
                    VALUES ('\(id)', 'Something else', 'project', '2026-10-01T09:00:00.000Z', '2026-10-27T10:00:00.000Z');
                """ }.joined()
        guard sqlite3_exec(handle, statements, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    @Test func sendsThePromptThroughTheSessionsExtension() async throws {
        let (store, home) = try store()
        var shown: [String] = []
        var copied: [String] = []
        defer { try? FileManager.default.removeItem(at: home) }
        store.showForTests = { id in shown.append(id); return true }
        store.openForTests = { _, text in copied.append(text); return true }
        var handed: [String] = []
        store.handedOff = { _, prompt in handed.append(prompt) }
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen()
        ext.start()
        defer { ext.stop() }
        try hold(session, home: home)

        #expect(await store.reach(of: choice(session)) == .listening(canFork: true))
        #expect(await store.deliver("Fix the comments", to: choice(session), handOff: handOff) == .sent)
        #expect(ext.received == ["Fix the comments"])
        // Shown once it's sent, and handed off: nothing was copied.
        #expect(shown == [session])
        #expect(copied.isEmpty)
        #expect(handed == ["Fix the comments"])
        #expect(store.delivering.isEmpty)
        // Nothing starts here.
        #expect(store.pending.isEmpty)
        #expect(store.settings.copilotRuns.isEmpty)
    }

    /// A clone of the pull request's repository, as Azure DevOps names it, that fetches from one on disk: release/x and the
    /// pull request's branch started from main's first commit, and main went a commit further. The clone is detached at the
    /// branch, with main merged in, as resolving its conflicts against main left it.
    private func resolvedAgainstMain(in home: URL) async throws -> URL {
        struct GitFailed: Error { let message: String }
        let environment = ["PATH": "/usr/bin:/bin", "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1"]
        func git(_ arguments: [String]) async throws {
            let result = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments, environment: environment, timeout: 60)
            guard result.status == 0 else { throw GitFailed(message: String(decoding: result.stderr, as: UTF8.self)) }
        }
        let identity = ["-c", "user.name=Robin Diaz", "-c", "user.email=robin@example.com"]
        let seed = home.appendingPathComponent("seed")
        let origin = home.appendingPathComponent("origin.git")
        let checkout = home.appendingPathComponent("checkout")
        func commit(_ text: String, to file: String) async throws {
            try "\(text)\n".write(to: seed.appendingPathComponent(file), atomically: true, encoding: .utf8)
            try await git(["-C", seed.path, "add", file])
            try await git(["-C", seed.path] + identity + ["commit", "--quiet", "-m", text])
        }
        try await git(["init", "--quiet", "--initial-branch=main", seed.path])
        try await commit("Storefront", to: "README.md")
        try await git(["-C", seed.path, "branch", "release/x"])
        try await git(["-C", seed.path, "checkout", "--quiet", "-b", pullRequest.sourceBranch])
        try await commit("Totals", to: "totals.txt")
        try await git(["-C", seed.path, "checkout", "--quiet", "main"])
        try await commit("Main's work", to: "main.txt")
        try await git(["clone", "--quiet", "--bare", seed.path, origin.path])
        try await git(["clone", "--quiet", origin.path, checkout.path])
        let remote = "https://dev.azure.com/contoso/Storefront/_git/shop-web"
        try await git(["-C", checkout.path, "remote", "set-url", "origin", remote])
        try await git(["-C", checkout.path, "config", "url.\(origin.path).insteadOf", remote])
        try await git(["-C", checkout.path, "checkout", "--quiet", "--detach", "origin/\(pullRequest.sourceBranch)"])
        try await git(["-C", checkout.path] + identity + ["merge", "--quiet", "--no-edit", "origin/main"])
        return checkout
    }

    /// Push & Reply goes once what the folder the session works in would push is checked, against the branch the pull
    /// request merges into now. While it holds a merge of what that branch doesn't have, as when the pull request was
    /// retargeted after its conflicts were resolved there, nothing's sent, copied or shown; nor while BriefBar can't
    /// check, as in a folder that isn't a clone of its repository. Against the branch it merged, it goes.
    @Test(.timeLimit(.minutes(1)))
    func sendsNoPushOfAMergeTheTargetDoesntHave() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        store.useEnvironment(["COPILOT_HOME": home.path, "PATH": "/usr/bin:/bin", "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1"])
        var shown: [String] = []
        var copied: [String] = []
        store.showForTests = { id in shown.append(id); return true }
        store.openForTests = { _, text in copied.append(text); return true }
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen()
        ext.start()
        defer { ext.stop() }
        try hold(session, home: home)
        try work(session, in: try await resolvedAgainstMain(in: home), home: home)
        // The window opened as the pull request merged into main; the list has read since that it merges into release/x.
        var target: String? = "release/x"
        let key = PRKey(pullRequest.organization, pullRequest.id)
        store.currentTarget = { $0 == key ? target : nil }

        let refused = await store.deliver("Push and reply", to: choice(session), checkingPush: pullRequest)
        #expect(refused == .notSent("‘Fix the totals’ holds a merge that release/x doesn't have, so nothing went. Fix the pull request in a new session."))
        #expect(ext.received.isEmpty)
        #expect(requests(home).isEmpty)
        #expect(shown.isEmpty && copied.isEmpty)
        #expect(store.deliveringFolders.isEmpty && store.delivering.isEmpty)

        let elsewhere = home.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try work(session, in: elsewhere, home: home)
        guard case .notSent(let why) = await store.deliver("Push and reply", to: choice(session), checkingPush: pullRequest) else {
            Issue.record("BriefBar sent a push it couldn't check")
            return
        }
        #expect(why.hasPrefix("BriefBar couldn't check what ‘Fix the totals’ would push, so nothing went: "))
        #expect(ext.received.isEmpty && copied.isEmpty)

        target = nil
        try work(session, in: home.appendingPathComponent("checkout", isDirectory: true), home: home)
        #expect(await store.deliver("Push and reply", to: choice(session), checkingPush: pullRequest) == .sent)
        #expect(ext.received == ["Push and reply"])
        #expect(copied.isEmpty)
    }

    /// Checked against main, a Push & Reply doesn't go once the list reads that the pull request merges into release/x,
    /// before the prompt is sent or copied: while git checks, after BriefBar wrote the prompt for the session's extension
    /// but before the extension took it, which BriefBar takes back, and right before BriefBar copies it for you to paste.
    @Test(.timeLimit(.minutes(1)))
    func sendsNoPushOnceThePullRequestMergesIntoAnotherBranch() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        store.useEnvironment(["COPILOT_HOME": home.path, "PATH": "/usr/bin:/bin", "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1"])
        var copied: [String] = []
        store.showForTests = { _ in true }
        store.openForTests = { _, text in copied.append(text); return true }
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen()
        defer { ext.stop() }
        try hold(session, home: home)
        try work(session, in: try await resolvedAgainstMain(in: home), home: home)
        // Main until the list reads release/x: from the given look on, or from when the test says.
        var looks = 0
        var retargetedAt = Int.max
        var retargeted = false
        let key = PRKey(pullRequest.organization, pullRequest.id)
        store.currentTarget = { asked in
            guard asked == key else { return nil }
            looks += 1
            return retargeted || looks >= retargetedAt ? "release/x" : "main"
        }
        let refused = SessionDelivery.notSent(
            "The pull request now merges into release/x, so nothing went. Send it again, for BriefBar to check ‘Fix the totals’ against release/x."
        )

        // Read while git checks against main.
        retargetedAt = 2
        #expect(await store.deliver("Push and reply", to: choice(session), checkingPush: pullRequest) == refused)
        #expect(requests(home).isEmpty)

        // Read once the prompt is written for the extension, which hasn't taken it.
        looks = 0
        retargetedAt = Int.max
        let sending = Task { await store.deliver("Push and reply", to: choice(session), checkingPush: pullRequest) }
        for _ in 0..<2000 where requests(home).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!requests(home).isEmpty)
        retargeted = true
        #expect(await sending.value == refused)
        #expect(requests(home).isEmpty)

        // Read right before BriefBar copies it, with Send Prompts to Copilot Sessions off.
        CopilotSessionPrompts.set(false, in: store.settings.defaults)
        looks = 0
        retargetedAt = 3
        retargeted = false
        #expect(await store.deliver("Push and reply", to: choice(session), checkingPush: pullRequest) == refused)
        #expect(copied.isEmpty)
        #expect(ext.received.isEmpty)
        #expect(store.deliveringFolders.isEmpty && store.delivering.isEmpty)

        // While it merges into main still, it goes.
        CopilotSessionPrompts.set(true, in: store.settings.defaults)
        retargetedAt = Int.max
        ext.start()
        #expect(await store.deliver("Push and reply", to: choice(session), checkingPush: pullRequest) == .sent)
        #expect(ext.received == ["Push and reply"])
    }

    /// A prompt about comments is kept as sent from when delivering it started, before the session's extension took it:
    /// whatever the session does from then on is its turn, even one that's over before BriefBar hears it went.
    @Test func keepsAPromptAboutCommentsAsSentFromWhenDeliveringItStarted() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        store.showForTests = { _ in true }
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen()
        let taken = TakenAt()
        ext.start { _ in
            taken.stamp()
            return ["ok": true]
        }
        defer { ext.stop() }
        try hold(session, home: home)

        let before = Date()
        let about = SentPrompt.About(pullRequest: PRKey("contoso", 4071), purpose: .fix, parts: [.thread(11)])
        #expect(await store.deliver("Fix this comment", to: choice(session), about: about) == .sent)
        let kept = try #require(store.settings.copilotSentPrompts.first)
        #expect(kept.session == session)
        #expect(kept.parts == [.thread(11)])
        #expect(!kept.copied)
        let tookIt = try #require(taken.date)
        #expect(kept.sentAt >= before)
        #expect(kept.sentAt <= tookIt)
    }

    /// While a prompt is being sent to a session, the turns of the prompts sent it before aren't followed: it may reach the
    /// session, and its turn end, before BriefBar hears it went. Once it went, their outcome isn't known; once nothing went,
    /// they're followed again.
    @Test func followsNoEarlierPromptWhileSendingAnother() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        var pausedAsItShowed: [Int?] = []
        store.showForTests = { [session] _ in
            pausedAsItShowed.append(store.followingPaused[session])
            return true
        }
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen()
        ext.start()
        defer { ext.stop() }
        try hold(session, home: home)
        let key = PRKey("contoso", 4071)
        let earlier = try #require(SentPrompt(
            SentPrompt.About(pullRequest: key, purpose: .fix, parts: [.thread(11)]), session: session, sentAt: Date().addingTimeInterval(-60), copied: false
        ))
        store.settings.copilotSentPrompts = [earlier]
        let about = SentPrompt.About(pullRequest: key, purpose: .fix, parts: [.thread(12)])

        // Nothing went: it's followed again.
        store.delivering.insert(session)
        #expect(await store.deliver("Fix this comment", to: choice(session), about: about) == .notSent("BriefBar is sending it a prompt already."))
        store.delivering.remove(session)
        #expect(store.followingPaused.isEmpty)
        #expect(store.settings.copilotSentPrompts.map(\.isFollowed) == [true])

        #expect(await store.deliver("Fix this comment", to: choice(session), about: about) == .sent)
        #expect(pausedAsItShowed == [1])
        #expect(store.followingPaused.isEmpty)
        #expect(store.settings.copilotSentPrompts.first { $0.parts == [.thread(11)] }?.overlapped == true)
        #expect(store.settings.copilotSentPrompts.first { $0.parts == [.thread(12)] }?.isFollowed == true)
    }

    /// A session that nothing has open loads as the app opens it, with BriefBar's extension, which takes the request that
    /// was waiting for it; it isn't opened again once it's sent.
    @Test func loadsASessionThatNothingHasOpen() async throws {
        let (store, home) = try store()
        var shown: [String] = []
        defer { try? FileManager.default.removeItem(at: home) }
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        defer { ext.stop() }
        store.showForTests = { [session] id in
            shown.append(id)
            try? self.hold(session, home: home)
            try? ext.listen()
            ext.start()
            return true
        }
        #expect(await store.reach(of: choice(session)) == .loads)
        #expect(await store.deliver("Fix the comments", to: choice(session)) == .sent)
        #expect(ext.received == ["Fix the comments"])
        #expect(shown == [session])
    }

    /// The session's extension forks it with the app's own fork; once the app records the fork as the session's, the
    /// fork's extension sends it the prompt, and the fork shows. The session itself gets no message.
    @Test func forksTheSessionAndSendsTheFork() async throws {
        let (store, home) = try store()
        var shown: [String] = []
        var copied: [String] = []
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home, forkedFrom: session)
        store.showForTests = { id in shown.append(id); return true }
        store.openForTests = { _, text in copied.append(text); return true }
        let outbox = home.appendingPathComponent("Outbox")
        let original = ExtensionStandIn(outbox: outbox, sessionId: session)
        let forked = ExtensionStandIn(outbox: outbox, sessionId: fork)
        try original.listen()
        try forked.listen()
        original.start { [fork] _ in ["ok": true, "forkSessionId": fork] }
        forked.start()
        defer {
            original.stop()
            forked.stop()
        }
        try hold(session, home: home)
        try hold(fork, home: home)

        #expect(await store.deliver("Try it another way", to: choice(session), forking: true) == .forkedAndSent(fork: fork))
        #expect(original.received == ["fork"])
        #expect(forked.received == ["Try it another way"])
        // The fork opened once its request was written, and only then.
        #expect(shown == [fork])
        #expect(copied.isEmpty)

        // A chat can't be forked.
        #expect(await store.deliver("Try it", to: choice(session, isChat: true), forking: true) == .notSent("The Copilot app can't fork this session."))
    }

    /// When the extension forks the session but can't name the fork, the one fork of the session that the app records
    /// since the request gets the prompt. With two, there's no telling which: BriefBar copies `/fork` and the prompt for the
    /// session itself, and says it may have forked already.
    @Test func sendsTheOneForkTheAppRecordsWhenTheExtensionCantNameIt() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        var shown: [String] = []
        var copied: [String] = []
        store.showForTests = { id in shown.append(id); return true }
        store.openForTests = { id, text in copied.append("\(id) \(text)"); return true }
        store.deliveryTimingForTests?.confirm = 0.3
        let outbox = home.appendingPathComponent("Outbox")
        let original = ExtensionStandIn(outbox: outbox, sessionId: session)
        let forked = ExtensionStandIn(outbox: outbox, sessionId: fork)
        try original.listen()
        try forked.listen()
        original.start { _ in ["ok": false, "error": ["code": "fork_failed", "message": "The fork gave no session ID"]] }
        forked.start()
        defer {
            original.stop()
            forked.stop()
        }
        try hold(session, home: home)
        try hold(fork, home: home)
        // Made after the request, and after an older fork of the session.
        let made = afterTheRequest()
        let older = "c6666666-6666-4666-8666-66666666666d"
        try database(at: home, forks: [(fork, session, made), (older, session, "2026-10-27T10:01:00.000Z")])

        #expect(await store.deliver("Try it another way", to: choice(session), forking: true) == .forkedAndSent(fork: fork))
        #expect(forked.received == ["Try it another way"])
        #expect(shown == [fork])
        #expect(copied.isEmpty)

        // Two forks made since: neither gets it.
        try FileManager.default.removeItem(at: home.appendingPathComponent("data.db"))
        let another = "d7777777-7777-4777-8777-77777777777c"
        try database(at: home, forks: [(fork, session, made), (another, session, made)])
        guard case .fellBack(let fallback) = await store.deliver("Try it", to: choice(session), forking: true) else {
            Issue.record("BriefBar didn't copy /fork")
            return
        }
        #expect(fallback.pastesFork)
        #expect(fallback.mayHaveSent)
        #expect(copied == ["\(session) /fork Try it"])
        #expect(forked.received == ["Try it another way"])
        #expect(CopilotComposerView.fallbackNote(fallback).hasSuffix("If the session forked already, don't."))
    }

    /// The session its extension names gets the prompt only once the app records it as a fork of the session made since
    /// the request: an older fork, as a name that holds another session's ID could have it say, doesn't, and the one fork
    /// made since does; and nor does a session that's no fork at all.
    @Test func sendsOnlyToAForkMadeSinceTheRequest() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        var shown: [String] = []
        var copied: [String] = []
        store.showForTests = { id in shown.append(id); return true }
        store.openForTests = { id, text in copied.append("\(id) \(text)"); return true }
        store.deliveryTimingForTests?.confirm = 0.3
        let older = "c6666666-6666-4666-8666-66666666666d"
        let plain = "e8888888-8888-4888-8888-88888888888e"
        let reported = Mutex(older)
        let outbox = home.appendingPathComponent("Outbox")
        let original = ExtensionStandIn(outbox: outbox, sessionId: session)
        let forked = ExtensionStandIn(outbox: outbox, sessionId: fork)
        let misnamed = ExtensionStandIn(outbox: outbox, sessionId: older)
        let notAFork = ExtensionStandIn(outbox: outbox, sessionId: plain)
        for ext in [original, forked, misnamed, notAFork] { try ext.listen() }
        original.start { _ in ["ok": true, "forkSessionId": reported.withLock { $0 }] }
        for ext in [forked, misnamed, notAFork] { ext.start() }
        defer {
            for ext in [original, forked, misnamed, notAFork] { ext.stop() }
        }
        for id in [session, fork, older, plain] { try hold(id, home: home) }
        try database(at: home, forks: [(fork, session, afterTheRequest()), (older, session, "2026-10-27T10:01:00.000Z")])

        #expect(await store.deliver("Try it another way", to: choice(session), forking: true) == .forkedAndSent(fork: fork))
        #expect(forked.received == ["Try it another way"])
        #expect(misnamed.received.isEmpty)
        #expect(shown == [fork])

        // A session that's no fork, and no fork made since.
        reported.withLock { $0 = plain }
        try FileManager.default.removeItem(at: home.appendingPathComponent("data.db"))
        try database(at: home, forks: [(older, session, "2026-10-27T10:01:00.000Z")], others: [plain])
        let result = await store.deliver("Try it", to: choice(session), forking: true)
        #expect(result == .fellBack(SessionFallback(
            reason: SendFailure.unconfirmedFork.description, pastesFork: true, mayHaveSent: true, session: session
        )))
        #expect(original.received == ["fork", "fork"])
        #expect(notAFork.received.isEmpty)
        #expect(forked.received.count == 1)
        #expect(copied == ["\(session) /fork Try it"])
    }

    /// When the app doesn't record the session that the extension says it forked as a fork of it, BriefBar sends it
    /// nothing, and copies `/fork` and the prompt for the session itself instead.
    @Test func sendsNothingToAForkTheAppDoesntRecord() async throws {
        let (store, home) = try store()
        var shown: [String] = []
        var copied: [String] = []
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home, forkedFrom: "c6666666-6666-4666-8666-66666666666d")
        store.showForTests = { id in shown.append(id); return true }
        store.openForTests = { id, text in copied.append("\(id) \(text)"); return true }
        let outbox = home.appendingPathComponent("Outbox")
        let original = ExtensionStandIn(outbox: outbox, sessionId: session)
        let forked = ExtensionStandIn(outbox: outbox, sessionId: fork)
        try original.listen()
        try forked.listen()
        original.start { [fork] _ in ["ok": true, "forkSessionId": fork] }
        forked.start()
        defer {
            original.stop()
            forked.stop()
        }
        try hold(session, home: home)

        let result = await store.deliver("Try it", to: choice(session), forking: true)
        #expect(result == .fellBack(SessionFallback(
            reason: SendFailure.unconfirmedFork.description, pastesFork: true, mayHaveSent: true, session: session
        )))
        #expect(forked.received.isEmpty)
        #expect(copied == ["\(session) /fork Try it"])
    }

    /// Once the session forked, but the fork doesn't get the prompt, BriefBar copies the prompt and opens the fork.
    @Test func copiesThePromptForTheForkWhenItDidntGetIt() async throws {
        let (store, home) = try store()
        var copied: [String] = []
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home, forkedFrom: session)
        store.showForTests = { _ in true }
        store.openForTests = { id, text in copied.append("\(id) \(text)"); return true }
        let original = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try original.listen()
        original.start { [fork] _ in ["ok": true, "forkSessionId": fork] }
        defer { original.stop() }
        try hold(session, home: home)
        // The fork's runtime has it open, but no extension listens in it.
        try hold(fork, home: home)
        store.deliveryTimingForTests?.listen = 0.3

        let result = await store.deliver("Try it", to: choice(session), forking: true)
        #expect(result == .fellBack(SessionFallback(reason: SendFailure.noListener.description, session: fork, fork: fork)))
        #expect(copied == ["\(fork) Try it"])
        #expect(requests(home).isEmpty)
    }

    /// When the extension doesn't answer, BriefBar takes its request back, copies the prompt and opens the session, and
    /// the window stays to say so, since it didn't say it would. One that the extension took but didn't say how it went
    /// may have reached the session.
    @Test func copiesThePromptWhenTheExtensionDoesntAnswer() async throws {
        let (store, home) = try store()
        var copied: [String] = []
        defer { try? FileManager.default.removeItem(at: home) }
        store.openForTests = { _, text in copied.append(text); return true }
        var handed = 0
        store.handedOff = { _, _ in handed += 1 }
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen()
        try hold(session, home: home)
        store.deliveryTimingForTests?.claim = 0.3
        store.deliveryTimingForTests?.sent = 0.5

        let unanswered = await store.deliver("Fix the comments", to: choice(session), handOff: handOff)
        #expect(unanswered == .fellBack(SessionFallback(reason: SendFailure.unanswered.description, session: session)))
        #expect(copied == ["Fix the comments"])
        #expect(requests(home).isEmpty)
        // Copied, it's handed off only once it's seen pasted in the session (`copiedPromptsWaitToBePasted`).
        #expect(handed == 0)
        if case .fellBack(let fallback) = unanswered {
            #expect(CopilotComposerView.fallbackNote(fallback) == "BriefBar's extension in the session didn't answer. BriefBar copied the prompt and opened the session in the Copilot app: paste it there, and send it.")
        }

        ext.start { _ in nil }
        defer { ext.stop() }
        store.deliveryTimingForTests?.claim = 60
        guard case .fellBack(let lost) = await store.deliver("Fix the comments", to: choice(session)) else {
            Issue.record("BriefBar didn't copy the prompt")
            return
        }
        #expect(lost.mayHaveSent)
        #expect(CopilotComposerView.fallbackNote(lost).hasSuffix("If the session has it already, don't."))
    }

    /// A session that the app had open before Send Prompts to Copilot Sessions was on has no extension until it restarts:
    /// BriefBar says so before you send it, writes no request, and copies the prompt for you to paste.
    @Test func saysToRestartASessionThatHasNoExtension() async throws {
        let (store, home) = try store()
        var copied: [String] = []
        defer { try? FileManager.default.removeItem(at: home) }
        store.openForTests = { _, text in copied.append(text); return true }
        try hold(session, home: home)
        // This test's process holds it, as a CLI in a terminal would, or as the app's runtime would.
        store.appHoldsForTests = { _ in false }
        #expect(await store.reach(of: choice(session)) == .noListener(inApp: false))
        store.appHoldsForTests = { $0 == getpid() }
        let reach = try #require(await store.reach(of: choice(session)))
        #expect(reach == .noListener(inApp: true))
        #expect(reach.whyNot(forking: false)?.contains("Restart the session") == true)

        let result = await store.deliver("Fix the comments", to: choice(session))
        #expect(result == .fellBack(SessionFallback(reason: try #require(reach.whyNot(forking: false)), wasForeseen: true, session: session)))
        #expect(copied == ["Fix the comments"])
        #expect(requests(home).isEmpty)
    }

    /// A session that a Copilot CLI has open, without BriefBar's extension, shows in the terminal that CLI runs in, which
    /// comes to the front, not in the app, which would fork its history: the window says to paste it there. Where BriefBar
    /// can't bring that terminal up, as in tmux or over SSH, it says so.
    @Test func copiesThePromptForASessionACLIHasOpen() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        var copied: [String] = []
        var comesUp = true
        store.openForTests = { _, text in copied.append(text); return comesUp }
        store.appHoldsForTests = { _ in false }
        try hold(session, home: home)
        #expect(await store.reach(of: choice(session)) == .noListener(inApp: false))

        // What each way does says so: the CLI's own /fork takes a name for the fork, not a prompt.
        #expect(CopilotComposerView.forkDetail(.noListener(inApp: false)) == "Copies the prompt: /fork in the CLI's terminal, then paste it.")
        #expect(CopilotComposerView.forkDetail(.noListener(inApp: true)) == "Copies /fork and the prompt, and opens the session, to paste.")

        guard case .fellBack(let fallback) = await store.deliver("Fix the comments", to: choice(session)) else {
            Issue.record("BriefBar didn't copy the prompt")
            return
        }
        #expect(fallback.place == .terminal)
        #expect(copied == ["Fix the comments"])
        // It can't bring up the session's own tab, so the window says to find it.
        #expect(CopilotComposerView.fallbackNote(fallback).hasSuffix("BriefBar copied the prompt and brought up the terminal where a Copilot CLI has the session open. Find the session's window or tab there, paste it, and send it."))

        // The CLI's own /fork takes a name for the fork, not a prompt: BriefBar copies the prompt alone, to paste once
        // you've forked the session there.
        guard case .fellBack(let forking) = await store.deliver("Try it", to: choice(session), forking: true) else {
            Issue.record("BriefBar didn't copy the prompt for a fork")
            return
        }
        #expect(forking.forksFirst)
        #expect(!forking.pastesFork)
        #expect(copied.last == "Try it")
        #expect(CopilotComposerView.fallbackNote(forking).hasSuffix("Find the session's window or tab there, fork it with /fork, then paste the prompt in the fork, and send it."))

        comesUp = false
        #expect(await store.deliver("Fix the comments", to: choice(session)) == .notSent(CopilotTasksStore.cantBringUp))
        // For a fork, it says to fork the session there first, then to paste the prompt in the fork: pasted in the session
        // itself, it would go to the session.
        #expect(await store.deliver("Try it", to: choice(session), forking: true) == .notSent(CopilotTasksStore.cantBringUpToFork))
        #expect(copied.last == "Try it")
    }

    /// The app holds a session through its runtime, which macOS attributes to the app: by the runtime's executable, in the
    /// app, even when it's responsible for itself; or by the app it runs as. A terminal isn't the app.
    @Test func tellsTheAppsRuntimeFromACLI() {
        let app = URL(fileURLWithPath: "/Applications/GitHub Copilot.app", isDirectory: true)
        #expect(CopilotTasksStore.isApp(app, responsiblePath: "/Applications/GitHub Copilot.app/Contents/MacOS/github", responsibleBundle: nil))
        #expect(CopilotTasksStore.isApp(app, responsiblePath: nil, responsibleBundle: app))
        #expect(!CopilotTasksStore.isApp(app, responsiblePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", responsibleBundle: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")))
        #expect(!CopilotTasksStore.isApp(app, responsiblePath: "/Applications/GitHub Copilot.app.old/Contents/MacOS/github", responsibleBundle: nil))
        #expect(!CopilotTasksStore.isApp(app, responsiblePath: nil, responsibleBundle: nil))
    }

    /// Turned off, Send Prompts to Copilot Sessions sends nothing, even to a session whose extension still listens, as it
    /// does until the session restarts.
    @Test func sendsNothingWhileSendingToSessionsIsOff() async throws {
        let (store, home) = try store()
        var copied: [String] = []
        defer { try? FileManager.default.removeItem(at: home) }
        store.openForTests = { _, text in copied.append(text); return true }
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen()
        ext.start()
        defer { ext.stop() }
        CopilotSessionPrompts.set(false, in: store.settings.defaults)

        #expect(await store.reach(of: choice(session)) == .off)
        guard case .fellBack(let fallback) = await store.deliver("Fix the comments", to: choice(session)) else {
            Issue.record("BriefBar didn't copy the prompt")
            return
        }
        #expect(fallback.wasForeseen)
        #expect(fallback.reason.contains(CopilotSessionPrompts.title))
        #expect(ext.received.isEmpty)
        #expect(requests(home).isEmpty)
        #expect(copied == ["Fix the comments"])
    }

    /// Turned off while BriefBar looks how a prompt would reach the session, or how to show the session to copy the prompt
    /// for it, Send Prompts to Copilot Sessions stops it: nothing's copied, opened or handed off, as when it's turned off
    /// later. Only when it was off as you sent it does BriefBar copy the prompt, as the window said it would.
    @Test func turningSendingOffAsItLooksCopiesAndOpensNothing() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        var copied: [String] = []
        var opened = 0
        store.openForTests = { _, text in copied.append(text); return true }
        store.showForTests = { _ in opened += 1; return true }
        var handed = 0
        store.handedOff = { _, _ in handed += 1 }
        // The app has had the session open since before Send Prompts to Copilot Sessions was on: no extension listens in it.
        try hold(session, home: home)
        // BriefBar looks whether the app holds it first as it looks how a prompt would reach the session, then as it looks
        // how to show the session, to copy the prompt for it.
        var looks = 0
        var turnsOffAt = 1
        store.appHoldsForTests = { [weak store] pid in
            looks += 1
            if looks == turnsOffAt, let store { CopilotSessionPrompts.set(false, in: store.settings.defaults) }
            return pid == getpid()
        }

        #expect(await store.deliver("Fix the comments", to: choice(session), handOff: handOff) == .notSent(CopilotTasksStore.cantSendNow))
        #expect(looks == 1)

        // Turned off as it looks how to show the session, once it found that it would copy the prompt.
        CopilotSessionPrompts.set(true, in: store.settings.defaults)
        looks = 0
        turnsOffAt = 2
        #expect(await store.deliver("Fix the comments", to: choice(session), handOff: handOff) == .notSent(CopilotTasksStore.cantSendNow))
        #expect(looks == 2)
        #expect(copied.isEmpty)
        #expect(opened == 0)
        #expect(handed == 0)
        #expect(requests(home).isEmpty)

        // Off as you sent it: BriefBar copies it, as the window said, and opens the session.
        looks = 0
        turnsOffAt = 0
        guard case .fellBack(let fallback) = await store.deliver("Fix the comments", to: choice(session), handOff: handOff) else {
            Issue.record("BriefBar didn't copy the prompt")
            return
        }
        #expect(fallback.wasForeseen)
        #expect(copied == ["Fix the comments"])
        // Copied, it's handed off only once its turn is seen to start.
        #expect(handed == 0)
    }

    /// The session of a task that BriefBar started with the CLI isn't one of the app's, which the app could load: BriefBar
    /// copies the prompt for you to paste, as it says it will, unless its extension listens in the session; and it isn't
    /// forked.
    @Test func copiesThePromptForASessionThatIsntTheApps() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        var copied: [String] = []
        store.openForTests = { _, text in copied.append(text); return true }
        store.showForTests = { _ in true }
        let run = CopilotRun(
            id: session, workItem: nil, options: CopilotModel.standard, repository: home, worktree: home, startedAt: Date(),
            process: DetachedProgram.Handle(pid: 0, startedAt: nil), ended: .finished
        )
        let task = SessionChoice(kind: .task(run), name: "Fix Comments", reasons: [.earlierTask])
        #expect(!task.canFork)
        #expect(await store.reach(of: task) == .notInApp)
        guard case .fellBack(let fallback) = await store.deliver("Fix the comments", to: task) else {
            Issue.record("BriefBar didn't copy the prompt")
            return
        }
        #expect(fallback.wasForeseen)
        #expect(copied == ["Fix the comments"])
        #expect(requests(home).isEmpty)

        // Open in the app, with BriefBar's extension: it goes.
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen()
        ext.start()
        defer { ext.stop() }
        #expect(await store.deliver("Fix them again", to: task) == .sent)
        #expect(ext.received == ["Fix them again"])
    }

    /// Push & Reply ships what its last task changed only in that task's session and worktree, so Send to a Fork isn't there
    /// for it, even when that task went on with one of the app's sessions: a fork would push a copy of those changes from a
    /// worktree of its own, and leave them uncommitted where they are. It's there otherwise, for a session the app can fork.
    @Test func offersNoForkForPushAndReply() {
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("BriefBarFork-\(UUID().uuidString)", isDirectory: true)
        let run = CopilotRun(
            id: session, workItem: nil, options: CopilotModel.standard, repository: worktree, worktree: worktree, startedAt: Date(),
            process: DetachedProgram.Handle(pid: 0, startedAt: nil), ended: .finished, isAppSession: true
        )
        let task = SessionChoice(kind: .task(run), name: "Fix Comments", reasons: [.earlierTask])
        #expect(task.canFork)
        #expect(CopilotComposerView.offersFork(task, mustContinue: false))
        #expect(!CopilotComposerView.offersFork(task, mustContinue: true))
        #expect(CopilotComposerView.offersFork(choice(session), mustContinue: false))
        #expect(!CopilotComposerView.offersFork(choice(session), mustContinue: true))
        #expect(!CopilotComposerView.offersFork(choice(session, isChat: true), mustContinue: false))
        #expect(!CopilotComposerView.offersFork(nil, mustContinue: false))
    }

    /// While a prompt is on its way to a session, where it works stays as it is: git removes no task's worktree there, and
    /// no task starts there, until the prompt has gone, or been taken back.
    @Test func keepsTheCheckoutOfASessionAPromptIsOnItsWayTo() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        store.showForTests = { _ in true }
        let worktree = home.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let run = CopilotRun(
            id: session, workItem: nil, options: CopilotModel.standard, repository: home, worktree: worktree, startedAt: Date(),
            process: DetachedProgram.Handle(pid: 0, startedAt: nil), ended: .finished
        )
        let task = SessionChoice(kind: .task(run), name: "Fix Comments", reasons: [.earlierTask])
        // Its extension listens, and takes it a moment later.
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen()
        defer { ext.stop() }

        let sending = Task { await store.deliver("Fix the comments", to: task) }
        for _ in 0..<400 where requests(home).isEmpty {
            try await Task.sleep(for: ExtensionStandIn.lookEvery)
        }
        #expect(store.isWorking(inFolder: worktree))
        #expect(await store.worktreeInUse(run) == "BriefBar is sending a prompt to a session that works in it. Remove it once that's done.")
        ext.start()
        #expect(await sending.value == .sent)
        #expect(!store.isWorking(inFolder: worktree))
        #expect(await store.worktreeInUse(run) == nil)
    }

    /// A fork that another prompt is on its way to isn't sent a second one meanwhile: BriefBar copies the prompt for it
    /// instead, and gives back only what it took.
    @Test func sendsAForkOnePromptAtATime() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home, forkedFrom: session)
        var copied: [String] = []
        store.showForTests = { _ in true }
        store.openForTests = { id, text in copied.append("\(id) \(text)"); return true }
        let outbox = home.appendingPathComponent("Outbox")
        let original = ExtensionStandIn(outbox: outbox, sessionId: session)
        let forked = ExtensionStandIn(outbox: outbox, sessionId: fork)
        try original.listen()
        try forked.listen()
        original.start { [fork] _ in ["ok": true, "forkSessionId": fork] }
        forked.start()
        defer {
            original.stop()
            forked.stop()
        }
        try hold(session, home: home)
        try hold(fork, home: home)
        store.delivering.insert(fork)

        let result = await store.deliver("Try it", to: choice(session), forking: true)
        #expect(result == .fellBack(SessionFallback(reason: SendFailure.busy.description, session: fork, fork: fork)))
        #expect(forked.received.isEmpty)
        #expect(copied == ["\(fork) Try it"])
        #expect(store.delivering == [fork])
    }

    /// While a prompt is on its way to a fork, the checkout the fork works in stays as it is too, as the session's does: no
    /// prompt goes to another session that works there, and git removes no worktree there, until the fork's prompt has gone.
    /// A fork whose checkout Copilot works in already, for another task, isn't sent it: BriefBar copies it for the fork
    /// instead, and gives back only what it took. One that works where the session does is sent it: that checkout is this
    /// send's own.
    @Test func keepsTheForksCheckoutWhileItsPromptIsOnItsWay() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        // The app has the session and the fork open.
        store.appHoldsForTests = { $0 == getpid() }
        try database(at: home, forkedFrom: session)
        var copied: [String] = []
        store.showForTests = { _ in true }
        store.openForTests = { id, text in copied.append("\(id) \(text)"); return true }
        // The fork works in a worktree, and so does another of the app's sessions.
        let worktree = home.appendingPathComponent("checkouts/fork", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let other = "c6666666-6666-4666-8666-66666666666d"
        try work(fork, in: worktree, home: home)
        try work(other, in: worktree, home: home)
        let outbox = home.appendingPathComponent("Outbox")
        let original = ExtensionStandIn(outbox: outbox, sessionId: session)
        let forked = ExtensionStandIn(outbox: outbox, sessionId: fork)
        try original.listen()
        try forked.listen()
        original.start { [fork] _ in ["ok": true, "forkSessionId": fork] }
        defer {
            original.stop()
            forked.stop()
        }
        try hold(session, home: home)
        try hold(fork, home: home)

        // The fork's extension takes its prompt only a moment later, however long other tests keep the main actor.
        let sending = Task { await store.deliver("Try it", to: choice(session), forking: true) }
        for _ in 0..<2_000 where !requests(home).contains(where: { $0.hasPrefix("\(fork).") }) {
            try await Task.sleep(for: ExtensionStandIn.lookEvery)
        }
        #expect(store.isWorking(inFolder: worktree))
        let busy = try #require(store.busyReason(for: choice(other), in: worktree))
        #expect(await store.deliver("Fix the comments", to: choice(other)) == .notSent(busy))
        #expect(!requests(home).contains { $0.hasPrefix("\(other).") })
        let run = CopilotRun(
            id: other, workItem: nil, options: CopilotModel.standard, repository: home, worktree: worktree, startedAt: Date(),
            process: DetachedProgram.Handle(pid: 0, startedAt: nil), ended: .finished
        )
        #expect(await store.worktreeInUse(run) == "BriefBar is sending a prompt to a session that works in it. Remove it once that's done.")
        forked.start()
        #expect(await sending.value == .forkedAndSent(fork: fork))
        #expect(forked.received == ["Try it"])
        #expect(!store.isWorking(inFolder: worktree))
        #expect(store.deliveringFolders.isEmpty)
        #expect(store.delivering.isEmpty)

        // A prompt is on its way to the other session there: the fork isn't sent this one.
        store.deliveringFolders[other] = worktree
        let refused = await store.deliver("Try it again", to: choice(session), forking: true)
        #expect(refused == .fellBack(SessionFallback(reason: SendFailure.checkoutBusy.description, session: fork, fork: fork)))
        #expect(forked.received == ["Try it"])
        #expect(copied == ["\(fork) Try it again"])
        #expect(store.deliveringFolders == [other: worktree])
        #expect(store.delivering.isEmpty)

        // The session works there too: that checkout is this send's own, so the fork is sent it.
        store.deliveringFolders[other] = nil
        try work(session, in: worktree, home: home)
        #expect(await store.deliver("Try it a third way", to: choice(session), forking: true) == .forkedAndSent(fork: fork))
        #expect(forked.received == ["Try it", "Try it a third way"])
        #expect(store.deliveringFolders.isEmpty)
        #expect(store.delivering.isEmpty)
    }

    /// While a prompt is on its way to one of the app's sessions, the checkout it works in now stays as it is, rather than
    /// the one it worked in as the window found it, when it moved since.
    @Test func keepsTheCheckoutTheSessionWorksInNow() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        store.showForTests = { _ in true }
        let before = home.appendingPathComponent("checkouts/before", isDirectory: true)
        let now = home.appendingPathComponent("checkouts/now", isDirectory: true)
        for folder in [before, now] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let state = home.appendingPathComponent("session-state/\(session)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("cwd: \(now.path)\n".utf8).write(to: state.appendingPathComponent("workspace.yaml"))
        var found = choice(session)
        found.appFolder = before
        // Its extension listens, and takes it a moment later.
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen()
        defer { ext.stop() }

        let sending = Task { await store.deliver("Fix the comments", to: found) }
        for _ in 0..<400 where requests(home).isEmpty {
            try await Task.sleep(for: ExtensionStandIn.lookEvery)
        }
        #expect(store.isWorking(inFolder: now))
        #expect(!store.isWorking(inFolder: before))
        ext.start()
        #expect(await sending.value == .sent)
        #expect(!store.isWorking(inFolder: now))
    }

    /// While BriefBar looks how to show a session, to copy a prompt for it as the window said it would, and as it copies the
    /// prompt and shows the session, the checkout the session works in stays as it is, as it does while a prompt is on its
    /// way: no task of BriefBar's starts there, and git removes no worktree there, meanwhile.
    @Test func keepsTheCheckoutWhileItCopiesThePromptForASession() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        let worktree = home.appendingPathComponent("checkouts/session", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try work(session, in: worktree, home: home)
        // The app has had the session open since before Send Prompts to Copilot Sessions was on: BriefBar copies the prompt.
        try hold(session, home: home)
        var kept: [Bool] = []
        store.appHoldsForTests = { [weak store] pid in
            kept.append(store?.isWorking(inFolder: worktree) == true)
            return pid == getpid()
        }
        var copied: [String] = []
        store.openForTests = { [weak store] _, text in
            kept.append(store?.isWorking(inFolder: worktree) == true)
            copied.append(text)
            return true
        }

        guard case .fellBack(let fallback) = await store.deliver("Fix the comments", to: choice(session)) else {
            Issue.record("BriefBar didn't copy the prompt")
            return
        }
        #expect(fallback.wasForeseen)
        #expect(copied == ["Fix the comments"])
        // As it looked how to show the session, and as it copied the prompt and showed it.
        #expect(kept.suffix(2) == [true, true])
        #expect(!store.isWorking(inFolder: worktree))
        #expect(store.deliveringFolders.isEmpty)
    }

    /// A task that went on with one of the app's sessions works where that session works now, which may have moved since
    /// the task started: that checkout is the one that has to be free, and the one that stays as it is while the prompt is
    /// on its way, rather than the task's.
    @Test func usesTheCheckoutATasksAppSessionWorksInNow() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        store.showForTests = { _ in true }
        let before = home.appendingPathComponent("checkouts/before", isDirectory: true)
        let now = home.appendingPathComponent("checkouts/now", isDirectory: true)
        for folder in [before, now] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let state = home.appendingPathComponent("session-state/\(session)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("cwd: \(now.path)\n".utf8).write(to: state.appendingPathComponent("workspace.yaml"))
        let run = CopilotRun(
            id: session, workItem: nil, options: CopilotModel.standard, repository: before, worktree: before, startedAt: Date(),
            process: DetachedProgram.Handle(pid: 0, startedAt: nil), ended: .finished, isAppSession: true
        )
        let task = SessionChoice(kind: .task(run), name: "Fix Comments", reasons: [.earlierTask])
        let other = "c6666666-6666-4666-8666-66666666666d"

        // A prompt is on its way to another session in the checkout it works in now: this one doesn't go.
        store.deliveringFolders[other] = now
        let busy = try #require(store.busyReason(for: task, in: now))
        #expect(await store.deliver("Fix the comments", to: task) == .notSent(busy))
        #expect(requests(home).isEmpty)

        // Its task's own worktree is busy instead: it goes, and the checkout it works in now stays as it is meanwhile.
        store.deliveringFolders[other] = before
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen()
        defer { ext.stop() }
        let sending = Task { await store.deliver("Fix the comments", to: task) }
        for _ in 0..<400 where requests(home).isEmpty {
            try await Task.sleep(for: ExtensionStandIn.lookEvery)
        }
        #expect(store.deliveringFolders[session]?.standardizedFileURL.path == now.standardizedFileURL.path)
        ext.start()
        #expect(await sending.value == .sent)
        #expect(ext.received == ["Fix the comments"])
        #expect(store.deliveringFolders[session] == nil)
    }

    /// A fork that didn't open as its prompt was written shows once the prompt has reached it.
    @Test func showsAForkThatDidntOpenOnceItHasThePrompt() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(at: home, forkedFrom: session)
        let fork = self.fork
        var shown: [String] = []
        // The fork doesn't open the first time.
        store.showForTests = { id in
            shown.append(id)
            return id != fork || shown.filter { $0 == fork }.count > 1
        }
        let outbox = home.appendingPathComponent("Outbox")
        let original = ExtensionStandIn(outbox: outbox, sessionId: session)
        let forked = ExtensionStandIn(outbox: outbox, sessionId: fork)
        try original.listen()
        try forked.listen()
        original.start { _ in ["ok": true, "forkSessionId": fork] }
        forked.start()
        defer {
            original.stop()
            forked.stop()
        }
        try hold(session, home: home)
        try hold(fork, home: home)

        #expect(await store.deliver("Try it", to: choice(session), forking: true) == .forkedAndSent(fork: fork))
        #expect(forked.received == ["Try it"])
        #expect(shown == [fork, fork])
    }

    /// When a Copilot CLI has the session open where BriefBar can't bring it up, as in tmux or over SSH, after its extension
    /// took the prompt and said it failed, which it also says once it stops waiting, the window says why BriefBar didn't
    /// send it, where to paste it, and to look first: the session may have it already, or may have forked.
    @Test func saysToLookFirstWhenATerminalThatCantComeUpMayHaveIt() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        var copied: [String] = []
        store.openForTests = { _, text in copied.append(text); return false }
        store.appHoldsForTests = { _ in false }
        store.deliveryTimingForTests?.confirm = 0.3
        try hold(session, home: home)
        try database(at: home, forks: [])
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen()
        ext.start { kind in ["ok": false, "error": ["code": kind == "fork" ? "fork_failed" : "send_failed", "message": "Timed out"]] }
        defer { ext.stop() }

        guard case .notSent(let sent) = await store.deliver("Fix the comments", to: choice(session)) else {
            Issue.record("BriefBar didn't say why the session didn't come up")
            return
        }
        #expect(sent.hasPrefix(SendFailure.failed(.sendFailed, "Timed out").description))
        #expect(sent.contains(CopilotTasksStore.cantBringUp))
        #expect(sent.hasSuffix("If the session has it already, don't."))
        #expect(copied == ["Fix the comments"])

        guard case .notSent(let forked) = await store.deliver("Try it", to: choice(session), forking: true) else {
            Issue.record("BriefBar didn't say why the session didn't come up")
            return
        }
        #expect(forked.hasPrefix(SendFailure.failed(.forkFailed, "Timed out").description))
        #expect(forked.contains(CopilotTasksStore.cantBringUpToFork))
        #expect(forked.hasSuffix("If the session forked already, don't."))
        #expect(copied.last == "Try it")
        #expect(ext.received == ["Fix the comments", "fork"])
    }

    /// When the Copilot app doesn't open the session, after its extension took the prompt and said it failed, which it also
    /// says once it stops waiting, the window says why BriefBar didn't send it, and to look first, rather than only that
    /// the app doesn't open its sessions, which would have you run it with the CLI: the session may have it already, or may
    /// have forked. So it does when nothing opens the app's sessions at all, and BriefBar copies nothing.
    @Test func saysToLookFirstWhenTheAppDoesntOpenASessionThatMayHaveIt() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        var copied: [String] = []
        store.openForTests = { _, text in copied.append(text); return false }
        // The app has the session open, so it would show there rather than in a terminal.
        store.appHoldsForTests = { $0 == getpid() }
        store.opensLinksForTests = true
        store.deliveryTimingForTests?.confirm = 0.3
        try hold(session, home: home)
        try database(at: home, forks: [])
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen()
        ext.start { kind in ["ok": false, "error": ["code": kind == "fork" ? "fork_failed" : "send_failed", "message": "Timed out"]] }
        defer { ext.stop() }
        let sent = "The session didn't take the prompt: Timed out. \(CopilotTasksStore.cantOpenInApp) If the session has it already, don't."

        #expect(await store.deliver("Fix the comments", to: choice(session)) == .notSent(sent))
        #expect(copied == ["Fix the comments"])

        let forked = "The Copilot app didn't fork the session: Timed out. \(CopilotTasksStore.cantOpenInApp) If the session forked already, don't."
        #expect(await store.deliver("Try it", to: choice(session), forking: true) == .notSent(forked))
        #expect(copied.last == "/fork Try it")

        // Nothing opens the app's sessions: nothing's copied, and the window still says why, and to look first.
        store.openForTests = nil
        store.opensLinksForTests = false
        #expect(await store.deliver("Fix them again", to: choice(session)) == .notSent(sent))
        #expect(copied.count == 2)
        #expect(ext.received == ["Fix the comments", "fork", "Fix them again"])
    }

    /// One prompt at a time for each session: a second one while the first is on its way isn't sent.
    @Test func sendsOnePromptAtATimeToASession() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        store.showForTests = { _ in true }
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen()
        ext.start(after: .milliseconds(600))
        defer { ext.stop() }
        try hold(session, home: home)

        async let first = store.deliver("Fix the comments", to: choice(session))
        // Once it's on its way, however long other tests keep the main actor.
        for _ in 0..<400 where !store.delivering.contains(session) {
            try await Task.sleep(for: ExtensionStandIn.lookEvery)
        }
        #expect(store.delivering == [session])
        #expect(await store.deliver("Fix them again", to: choice(session)) == .notSent("BriefBar is sending it a prompt already."))
        #expect(await first == .sent)
        #expect(ext.received == ["Fix the comments"])
        #expect(store.delivering.isEmpty)
    }

    /// Turning Azure DevOps off deletes what Copilot printed, and BriefBar's requests and results, which hold its prompts,
    /// even from a folder that others can open by then, but not what the extensions in open sessions say, theirs while they
    /// run; and only the link, when the folder, or the outbox, is one.
    @Test func turningAzureDevOpsOffKeepsWhatExtensionsSay() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("BriefBarOutput-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent("Copilot", isDirectory: true)
        let outbox = CopilotOutbox(root: home, path: ["Copilot", "Outbox"])
        try outbox.write(.send("Fix the comments", to: session))
        try Data("Done.".utf8).write(to: folder.appendingPathComponent("\(session).log"))
        let ext = ExtensionStandIn(outbox: outbox.url, sessionId: session)
        try ext.listen()
        try ExtensionStandIn.write(["ok": true], to: outbox.url.appendingPathComponent("results"), named: "\(UUID().uuidString.lowercased()).json")

        CopilotTasksStore.deleteOutput(in: folder, outbox: outbox)
        let left = try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted()
        #expect(left == ["Outbox", "Outbox/listening", "Outbox/listening/\(session).json", "Outbox/requests", "Outbox/results"])

        // A folder of requests that others can open by then goes, with them, rather than keeping the prompts it holds.
        try outbox.write(.send("Fix them again", to: session))
        chmod(outbox.url.appendingPathComponent("requests").path, 0o755)
        CopilotTasksStore.deleteOutput(in: folder, outbox: outbox)
        let kept = try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted()
        #expect(kept == ["Outbox", "Outbox/listening", "Outbox/listening/\(session).json", "Outbox/results"])

        // A folder that's a link is only unlinked.
        let elsewhere = home.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data().write(to: elsewhere.appendingPathComponent("keep.log"))
        let linked = home.appendingPathComponent("Linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: elsewhere)
        CopilotTasksStore.deleteOutput(in: linked, outbox: CopilotOutbox(root: home, path: ["Linked", "Outbox"]))
        #expect(!FileManager.default.fileExists(atPath: linked.path))
        #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("keep.log").path))

        // So is an outbox that's a link, with what Copilot printed beside it.
        let other = home.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("Done.".utf8).write(to: other.appendingPathComponent("\(session).log"))
        try FileManager.default.createSymbolicLink(at: other.appendingPathComponent("Outbox"), withDestinationURL: elsewhere)
        CopilotTasksStore.deleteOutput(in: other, outbox: CopilotOutbox(root: home, path: ["Other", "Outbox"]))
        #expect(!FileManager.default.fileExists(atPath: other.path))
        #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("keep.log").path))
    }

    /// Stopped, as when its window closes, a send takes its request back, and copies, opens and hands off nothing.
    @Test func stoppingASendCopiesAndOpensNothing() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        var opened = 0
        store.openForTests = { _, _ in opened += 1; return true }
        store.showForTests = { _ in opened += 1; return true }
        var handed = 0
        store.handedOff = { _, _ in handed += 1 }
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen()
        try hold(session, home: home)

        let sending = Task { await store.deliver("Fix the comments", to: choice(session), handOff: handOff) }
        for _ in 0..<400 where requests(home).isEmpty {
            try await Task.sleep(for: ExtensionStandIn.lookEvery)
        }
        sending.cancel()
        #expect(await sending.value == .notSent(SendFailure.cancelled.description))
        #expect(requests(home).isEmpty)
        #expect(opened == 0)
        #expect(handed == 0)
        #expect(store.delivering.isEmpty)
    }

    /// Turned off while a prompt waits for the extension to take it, Send Prompts to Copilot Sessions takes it back, and
    /// BriefBar copies and opens nothing.
    @Test func turningSendingOffTakesBackWhatWaits() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        var opened = 0
        store.openForTests = { _, _ in opened += 1; return true }
        store.showForTests = { _ in opened += 1; return true }
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen()
        try hold(session, home: home)

        let sending = Task { await store.deliver("Fix the comments", to: choice(session)) }
        for _ in 0..<400 where requests(home).isEmpty {
            try await Task.sleep(for: ExtensionStandIn.lookEvery)
        }
        CopilotSessionPrompts.set(false, in: store.settings.defaults)
        #expect(await sending.value == .notSent(CopilotTasksStore.cantSendNow))
        #expect(requests(home).isEmpty)
        #expect(opened == 0)

        // Turned off once the extension took one: it's sent, and handed off, but nothing opens.
        CopilotSessionPrompts.set(true, in: store.settings.defaults)
        var handed = 0
        store.handedOff = { _, _ in handed += 1 }
        ext.start(after: .milliseconds(600))
        defer { ext.stop() }
        let taken = Task { await store.deliver("Fix the comments", to: choice(session), handOff: handOff) }
        for _ in 0..<400 where ext.received.isEmpty {
            try await Task.sleep(for: ExtensionStandIn.lookEvery)
        }
        CopilotSessionPrompts.set(false, in: store.settings.defaults)
        #expect(await taken.value == .sent)
        #expect(handed == 1)
        #expect(opened == 0)
    }

    /// Turning Azure DevOps off stops a prompt on its way to a session: what waits is taken back, nothing shows or is
    /// copied, and nothing more is sent.
    @Test func turningAzureDevOpsOffStopsAPromptOnItsWay() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        var opened = 0
        store.openForTests = { _, _ in opened += 1; return true }
        store.showForTests = { _ in opened += 1; return true }
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen()
        try hold(session, home: home)

        let sending = Task { await store.deliver("Fix the comments", to: choice(session)) }
        for _ in 0..<400 where requests(home).isEmpty {
            try await Task.sleep(for: ExtensionStandIn.lookEvery)
        }
        store.stop()
        #expect(await sending.value == .notSent(CopilotTasksStore.cantSendNow))
        #expect(requests(home).isEmpty)
        #expect(await store.show(session) == false)
        // Nor does an open window look any more at how a prompt would reach the session.
        #expect(await store.reach(of: choice(session)) == nil)
        #expect(await store.deliver("Fix them again", to: choice(session)) == .notSent(CopilotTasksStore.cantSendNow))
        #expect(opened == 0)
    }

    /// The extension says the session didn't take the prompt once it stops waiting for it too, so the session may get it
    /// all the same: BriefBar says so as it copies it.
    @Test func warnsThatAPromptThatFailedMayHaveGone() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        store.openForTests = { _, _ in true }
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen()
        ext.start { _ in ["ok": false, "error": ["code": "send_failed", "message": "Timed out"]] }
        defer { ext.stop() }
        try hold(session, home: home)

        guard case .fellBack(let fallback) = await store.deliver("Fix the comments", to: choice(session)) else {
            Issue.record("BriefBar didn't copy the prompt")
            return
        }
        #expect(fallback.mayHaveSent)
        #expect(CopilotComposerView.fallbackNote(fallback) == "The session didn't take the prompt: Timed out. BriefBar copied the prompt and opened the session in the Copilot app: paste it there, and send it. If the session has it already, don't.")
    }

    /// A prompt BriefBar copied for you to paste takes the comments it quotes off Needs You only once BriefBar sees it in a
    /// message sent the session, which says you pasted it: another message, sent before it or instead, is the session's
    /// own; and one you don't paste, which BriefBar forgets, leaves them there.
    @Test func copiedPromptsWaitToBePasted() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        store.openForTests = { _, _ in true }
        var handed: [String] = []
        store.handedOff = { _, prompt in handed.append(prompt) }
        // No extension listens in it: BriefBar copies the prompt.
        try hold(session, home: home)
        let about = SentPrompt.About(pullRequest: PRKey("contoso", 4071), purpose: .fix, parts: [.thread(11)])
        let text = "Fix the comments\n\nThen   run the tests."
        guard case .fellBack = await store.deliver(text, to: choice(session), handOff: handOff, about: about) else {
            Issue.record("BriefBar didn't copy the prompt")
            return
        }
        #expect(handed.isEmpty)
        let prompt = try #require(store.settings.copilotSentPrompts.first)
        #expect(store.copiedPrompts[prompt.id]?.text == text)
        func follow(at date: Date) async throws {
            store.followSentPrompts(now: date)
            for _ in 0..<400 where store.isFollowingPrompts {
                try await Task.sleep(for: ExtensionStandIn.lookEvery)
            }
        }
        let log = home.appendingPathComponent("session-state/\(session)/events.jsonl")
        func send(_ content: String, at date: Date) throws {
            let stamp = date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            let data = String(decoding: try JSONSerialization.data(withJSONObject: ["content": content]), as: UTF8.self)
            let line = #"{"type":"user.message","data":\#(data),"id":"a","timestamp":"\#(stamp)","parentId":null}"# + "\n"
            if !FileManager.default.fileExists(atPath: log.path) { try Data().write(to: log) }
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        }
        // Not pasted yet.
        try await follow(at: Date())
        #expect(handed.isEmpty)
        // Another message: the session's own turn, not the prompt's.
        try send("What does this change do?", at: Date().addingTimeInterval(1))
        try await follow(at: Date().addingTimeInterval(2))
        #expect(handed.isEmpty)
        #expect(store.promptTurns[prompt.id]?.phase == .waiting)
        #expect(store.copiedPrompts[prompt.id] != nil)
        // Pasted, with words of yours around it, its lines and spaces broken otherwise.
        try send("Please:\n\nFix the comments\nThen run the tests.\n\nThanks", at: Date().addingTimeInterval(3))
        try await follow(at: Date().addingTimeInterval(4))
        #expect(handed == [text])
        #expect(store.copiedPrompts.isEmpty)
        #expect(store.promptTurns[prompt.id]?.phase != .waiting)

        // One not pasted within half an hour goes, and hands nothing off.
        try FileManager.default.removeItem(at: log)
        store.settings.copilotSentPrompts = []
        guard case .fellBack = await store.deliver("Fix them again", to: choice(session), handOff: handOff, about: about) else {
            Issue.record("BriefBar didn't copy the prompt")
            return
        }
        try await follow(at: Date().addingTimeInterval(SentPrompt.pasteWait + 60))
        #expect(store.settings.copilotSentPrompts.isEmpty)
        #expect(store.copiedPrompts.isEmpty)
        #expect(handed == [text])
    }

    /// Stop, on a prompt's line, stops its session's turn through BriefBar's extension there, as the app's own Stop does.
    /// An extension that can't, as one that started before it could, or Send Prompts to Copilot Sessions turned off, has
    /// BriefBar show the session, to stop it there, and say so.
    @Test func stopsASessionsTurnThroughItsExtension() async throws {
        let (store, home) = try store()
        defer { try? FileManager.default.removeItem(at: home) }
        var shown: [String] = []
        store.showForTests = { shown.append($0); return true }
        let ext = ExtensionStandIn(outbox: home.appendingPathComponent("Outbox"), sessionId: session)
        try ext.listen(kinds: ["send", "fork", "stop"])
        ext.start()
        defer { ext.stop() }
        try hold(session, home: home)

        #expect(await store.stopTurn(in: session) == nil)
        #expect(ext.received == ["stop"])
        #expect(shown.isEmpty)

        // An extension from before BriefBar could ask it to stop.
        try ext.listen(kinds: ["send", "fork"])
        #expect(await store.stopTurn(in: session) == "BriefBar's extension in the session can't stop it. Stop it in the session, which BriefBar showed.")
        #expect(ext.received == ["stop"])
        #expect(shown == [session])

        CopilotSessionPrompts.set(false, in: store.settings.defaults)
        #expect(await store.stopTurn(in: session)?.hasPrefix("BriefBar can't stop it while \(CopilotSessionPrompts.title) is off.") == true)
        #expect(requests(home).isEmpty)

        // Nothing once Azure DevOps stopped.
        store.stop()
        #expect(await store.stopTurn(in: session) == CopilotTasksStore.cantSendNow)
    }

    /// The demo sends nothing, and reads nothing of yours.
    @Test func theDemoSendsNothing() async {
        let store = CopilotTasksStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo, notifier: nil)
        CopilotSessionPrompts.set(true, in: store.settings.defaults)
        var opened = 0
        store.openForTests = { _, _ in opened += 1; return true }
        store.showForTests = { _ in opened += 1; return true }
        #expect(await store.reach(of: choice(session)) == nil)
        #expect(await store.deliver("Fix the comments", to: choice(session)) == .notSent(CopilotTasksStore.cantSendNow))
        #expect(opened == 0)
    }
}
