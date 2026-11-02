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
    let outbox: URL
    let sessionId: String
    private let state = Mutex<(received: [String], task: Task<Void, Never>?)>(([], nil))

    init(outbox: URL, sessionId: String) {
        self.outbox = outbox
        self.sessionId = sessionId
    }

    /// What it was asked, in order: `fork`, or a send's prompt.
    var received: [String] { state.withLock { $0.received } }

    func listen() throws {
        let started = DetachedProgram.startTime(of: getpid()) ?? Date()
        try Self.write([
            "version": 1, "sessionId": sessionId, "pid": Int(getpid()), "kinds": ["send", "fork"],
            "startedAt": started.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
        ], to: outbox.appendingPathComponent("listening"), named: "\(sessionId).json")
    }

    /// Takes its session's requests until `stop()`: what `answer` returns goes into each one's result, or none when nil.
    func start(after delay: Duration = .zero, answer: @escaping @Sendable (_ kind: String) -> [String: Any]? = { _ in ["ok": true] }) {
        let task = Task { [self] in
            while !Task.isCancelled {
                let requests = outbox.appendingPathComponent("requests")
                for name in (try? FileManager.default.contentsOfDirectory(atPath: requests.path)) ?? []
                where name.hasPrefix("\(sessionId).") && name.hasSuffix(".json") {
                    let claimed = requests.appendingPathComponent(".\(name.dropLast(".json".count)).claimed-\(getpid())")
                    guard rename(requests.appendingPathComponent(name).path, claimed.path) == 0,
                          let data = FileManager.default.contents(atPath: claimed.path),
                          let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let kind = request["kind"] as? String, let requestId = request["requestId"] as? String
                    else { continue }
                    state.withLock { $0.received.append(kind == "fork" ? "fork" : request["prompt"] as? String ?? "") }
                    try? await Task.sleep(for: delay)
                    if let fields = answer(kind) {
                        let result = ["version": 1, "requestId": requestId, "sessionId": sessionId, "kind": kind].merging(fields) { $1 }
                        try? Self.write(result, to: outbox.appendingPathComponent("results"), named: "\(requestId).json")
                    }
                    try? FileManager.default.removeItem(at: claimed)
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        state.withLock { $0.task = task }
    }

    func stop() {
        state.withLock { $0.task?.cancel() }
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
        CommentHandOff(key: PRKey("contoso", 4071), waiting: [], account: nil, me: "me", dismissedCutoff: .distantPast)
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
        // Long enough for each step even while other tests keep the process busy for many seconds: a test that waits for
        // a step to time out shortens that step's.
        var timing = SessionSender.Timing()
        timing.poll = .milliseconds(5)
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

    /// The app's database, with the session and its fork, which it records as forked from `forkedFrom`.
    private func database(at home: URL, forkedFrom: String) throws {
        try database(at: home, forks: [(fork, forkedFrom, "2026-10-27T10:01:00.000Z")])
    }

    /// The app's database, with the session and the forks it records: each one's ID, the session it was forked from, and
    /// when it was made.
    private func database(at home: URL, forks: [(id: String, original: String, created: String)]) throws {
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
        // Made as the request was, after the session itself, and after an older fork of it.
        let made = Date().addingTimeInterval(2).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
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
        #expect(result == .fellBack(SessionFallback(reason: SendFailure.unconfirmedFork.description, pastesFork: true, session: session)))
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
        #expect(handed == 1)
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
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.delivering == [session])
        #expect(await store.deliver("Fix them again", to: choice(session)) == .notSent("BriefBar is sending it a prompt already."))
        #expect(await first == .sent)
        #expect(ext.received == ["Fix the comments"])
        #expect(store.delivering.isEmpty)
    }

    /// Turning Azure DevOps off deletes what Copilot printed, and BriefBar's requests and results, which hold its prompts,
    /// but not what the extensions in open sessions say, theirs while they run; and only the link, when the folder is one.
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

        // A folder that's a link is only unlinked.
        let elsewhere = home.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data().write(to: elsewhere.appendingPathComponent("keep.log"))
        let linked = home.appendingPathComponent("Linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: elsewhere)
        CopilotTasksStore.deleteOutput(in: linked, outbox: CopilotOutbox(root: home, path: ["Linked", "Outbox"]))
        #expect(!FileManager.default.fileExists(atPath: linked.path))
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
            try await Task.sleep(for: .milliseconds(5))
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
            try await Task.sleep(for: .milliseconds(5))
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
            try await Task.sleep(for: .milliseconds(5))
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
            try await Task.sleep(for: .milliseconds(5))
        }
        store.stop()
        #expect(await sending.value == .notSent(CopilotTasksStore.cantSendNow))
        #expect(requests(home).isEmpty)
        #expect(await store.show(session) == false)
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
