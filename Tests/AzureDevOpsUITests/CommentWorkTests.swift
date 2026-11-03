import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import Testing
@testable import AzureDevOpsUI

/// What each comment thread says Copilot does about it: the latest work that took it on, a task of BriefBar's, which keeps
/// the threads it took on with its run, or a prompt sent to one of the Copilot app's sessions, which BriefBar keeps by
/// references only and follows from the session's log.
@MainActor
@Suite struct CommentWorkTests {
    /// Now, as the store follows prompts by the clock.
    private let now = Date()
    private let key = PRKey("contoso", 4102)
    private let session = "2f8a4c6e-1b3d-4e5f-8a7b-9c0d1e2f3a14"
    private let task = "11111111-1111-4111-8111-111111111111"
    private let fork = "33333333-3333-4333-8333-333333333333"

    private var pullRequest: TaskPullRequest {
        TaskPullRequest(
            organization: "contoso", project: "Storefront", repository: "payments-api", id: 4102, title: "Add retry with backoff",
            url: URL(string: "https://dev.azure.com/contoso/Storefront/_git/payments-api/pullrequest/4102")!,
            sourceBranch: "payments-retry", targetBranch: "main"
        )
    }

    private func run(
        _ id: String, _ action: PullRequestAction = .fixComments, startedAt: Date, ended: RunPhase? = nil, threads: [TakenThread]?,
        forkedFrom: String? = nil
    ) -> CopilotRun {
        Self.makeRun(id, action, startedAt: startedAt, ended: ended, threads: threads, forkedFrom: forkedFrom)
    }

    private static func makeRun(
        _ id: String, _ action: PullRequestAction, startedAt: Date, ended: RunPhase? = nil, threads: [TakenThread]? = nil,
        forkedFrom: String? = nil
    ) -> CopilotRun {
        let pullRequest = PullRequestReference(organization: "contoso", project: "Storefront", repository: "payments-api", id: 4102,
                                               sourceBranch: "payments-retry")
        return CopilotRun(
            id: id, workItem: nil, onPullRequest: pullRequest, action: action, options: CopilotModel.standard,
            repository: URL(fileURLWithPath: "/tmp/payments-api"), worktree: URL(fileURLWithPath: "/tmp/copilot-worktrees/payments-api/pr-4102"),
            startedAt: startedAt, process: DetachedProgram.Handle(pid: 0, startedAt: nil), ended: ended, forkedFrom: forkedFrom,
            threads: threads
        )
    }

    private func store(_ settings: AppSettings = AppSettings(defaults: MemoryDefaults()), notifier: Notifier? = nil) -> CopilotTasksStore {
        settings.copilotEnabled = true
        let store = CopilotTasksStore(settings: settings, mode: .live, notifier: notifier)
        store.useEnvironment(["COPILOT_HOME": "/nonexistent"])
        // Never the Copilot app's own folder.
        store.appHomeForTests = URL(fileURLWithPath: "/nonexistent/copilot-app", isDirectory: true)
        return store
    }

    private func about(_ purpose: SentPrompt.Purpose = .fix, threads: [Int] = [11]) -> SentPrompt.About {
        SentPrompt.About(pullRequest: key, purpose: purpose, threads: threads)
    }

    // MARK: Sentences

    @Test func saysWhatCopilotDoesInASentence() {
        func said(_ purpose: CommentWork.Purpose, _ state: CommentWork.State, fork: String? = nil) -> String {
            CommentWork(purpose: purpose, state: state, session: session, forkedFrom: fork == nil ? nil : task, isTask: false, since: now)
                .sentence(name: fork == nil ? "Retry backoff" : "Retry backoff (fork)", forkOf: fork)
        }
        #expect(said(.explain, .working(nil)) == "Copilot is explaining this in ‘Retry backoff’")
        #expect(said(.fix, .working("Run the tests")) == "Copilot is fixing this in ‘Retry backoff’")
        #expect(said(.fix, .working(nil), fork: "Retry backoff") == "Fixing this in a fork of ‘Retry backoff’")
        #expect(said(.fix, .done("Capped it")) == "Fixed in ‘Retry backoff’, not pushed")
        #expect(said(.fix, .done(nil), fork: "Retry backoff") == "Fixed in a fork of ‘Retry backoff’, not pushed")
        #expect(said(.fix, .failed("Error: the build failed\nmore")) == "Couldn't fix it: Error: the build failed")
        #expect(said(.fix, .failed(nil)) == "Couldn't fix it in ‘Retry backoff’")
        #expect(said(.fix, .stopped) == "Stopped in ‘Retry backoff’ before it fixed it")
        #expect(said(.fix, .waiting(copied: true)) == "Copied for ‘Retry backoff’: paste it there")
        #expect(said(.fix, .waiting(copied: false)) == "Sent to ‘Retry backoff’")
        #expect(said(.fix, .needsYou, fork: "Retry backoff") == "A fork of ‘Retry backoff’ is waiting for your answer")
        #expect(said(.pushAndReply, .working(nil)) == "Pushing and replying from ‘Retry backoff’")
        #expect(said(.pushAndReply, .done(nil)) == "Pushed and replied from ‘Retry backoff’")
        #expect(said(.explain, .failed("No session")) == "Couldn't explain it: No session")
        // Without names it knows.
        let unnamed = CommentWork(purpose: .fix, state: .done(nil), session: session, forkedFrom: task, isTask: true, since: now)
        #expect(unnamed.sentence(name: nil, forkOf: nil) == "Fixed in a fork of its session, not pushed")
        #expect(CommentWork(purpose: .fix, state: .working(nil), session: session, forkedFrom: nil, isTask: true, since: now)
            .sentence(name: nil, forkOf: nil) == "Copilot is fixing this in its session")
    }

    // MARK: Tasks of BriefBar's

    /// A task's thread says how the task stands; once a later task goes on with its session, how it ended then; and while
    /// Push & Reply ships it, how that stands.
    @Test func aTasksThreadsSayHowItStands() {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let first = now.addingTimeInterval(-600), second = now.addingTimeInterval(-60)
        settings.copilotRuns = [run(task, startedAt: first, threads: [TakenThread(id: 11, since: first)])]
        #expect(store.commentWork(on: 11, of: key)?.state == .working(nil))
        #expect(store.commentWork(on: 11, of: key)?.isTask == true)
        #expect(store.commentWork(on: 12, of: key) == nil)
        #expect(store.commentWork(on: 11, of: PRKey("contoso", 4099)) == nil)
        // Gone on with, for another thread: 11 was fixed then, 12 is being fixed now.
        settings.copilotRuns = [run(task, startedAt: second, threads: [
            TakenThread(id: 11, since: first, ended: .finished), TakenThread(id: 12, since: second),
        ])]
        #expect(store.commentWork(on: 11, of: key)?.state == .done(nil))
        #expect(store.commentWork(on: 11, of: key)?.isReadyFix == true)
        #expect(store.commentWork(on: 12, of: key)?.state == .working(nil))
        settings.copilotRuns = [run(task, startedAt: second, ended: .finished, threads: [
            TakenThread(id: 11, since: first, ended: .finished), TakenThread(id: 12, since: second),
        ])]
        #expect(store.readyFixes(of: key, among: [11, 12, 13]) == [ReadyFixes(session: task, forkedFrom: nil, isTask: true, threads: [11, 12], latest: second)])
        // Only the threads still open.
        #expect(store.readyFixes(of: key, among: [12]).map(\.threads) == [[12]])
        // Push & Reply ships them.
        settings.copilotRuns = [run(task, .pushAndReply, startedAt: now, threads: [
            TakenThread(id: 11, since: first, ended: .finished), TakenThread(id: 12, since: second, ended: .finished),
        ])]
        #expect(store.commentWork(on: 11, of: key).map { [$0.purpose == .pushAndReply, $0.state == .working(nil)] } == [true, true])
        #expect(store.readyFixes(of: key, among: [11, 12]).isEmpty)
        // Nothing while Send Work to Copilot is off.
        settings.copilotEnabled = false
        #expect(store.commentWork(on: 11, of: key) == nil)
    }

    /// A task keeps the threads it takes on with its run; going on with its session keeps those it took on before.
    @Test func sendingKeepsTheThreadsWithTheRun() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        store.launchForTests = { request, id, now in
            guard case .pullRequest(_, let action) = request.subject else { throw CancellationError() }
            return Self.makeRun(id, action, startedAt: now)
        }
        store.send(.pullRequest(pullRequest, .fixComments), prompt: "Fix 11", options: CopilotModel.standard,
                   repository: URL(fileURLWithPath: "/tmp/payments-api"), threads: [11])
        // While it gets ready, its thread says Copilot is on it.
        #expect(store.commentWork(on: 11, of: key)?.state == .working(nil))
        try await settle { !settings.copilotRuns.isEmpty }
        let started = try #require(settings.copilotRuns.first)
        #expect(started.threads?.map(\.id) == [11])
        // It ended; going on with it for 12 keeps 11, as it ended.
        settings.copilotRuns[0].ended = .finished
        store.send(.pullRequest(pullRequest, .fixComments), prompt: "Fix 12", options: CopilotModel.standard,
                   repository: URL(fileURLWithPath: "/tmp/payments-api"), continuing: settings.copilotRuns[0], threads: [12])
        try await settle { settings.copilotRuns.first?.threads?.count == 2 }
        #expect(settings.copilotRuns.first?.threads?.map { [$0.id: $0.ended] } == [[11: .finished], [12: nil]])
    }

    /// A fork's ID is the CLI's: its send goes by BriefBar's until the fork is made, then by the fork's, which its run keeps,
    /// with the session it forked. It says it's working once the fork is made, by the fork's ID, for the notification that
    /// says how it ended to replace.
    @Test func aForkGoesByItsOwnIDOnceItsMade() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let recent = RecentNotifications(defaults: MemoryDefaults(), isDemo: false)
        let store = store(settings, notifier: Notifier(recent: recent, posts: false))
        let (go, letItGo) = AsyncStream<Void>.makeStream()
        let fork = fork
        store.launchForTests = { request, _, now in
            for await _ in go { break }
            guard let forking = request.forking else { throw CancellationError() }
            return Self.makeRun(fork, .fixComments, startedAt: now, forkedFrom: forking.id)
        }
        let original = run(task, startedAt: now.addingTimeInterval(-3_600), ended: .finished, threads: nil)
        settings.copilotRuns = [original]
        store.send(.pullRequest(pullRequest, .fixComments), prompt: "Fix 11", options: CopilotModel.standard,
                   repository: original.repository, forking: original, threads: [11])
        let waiting = try #require(store.commentWork(on: 11, of: key))
        #expect(waiting.forkedFrom == task)
        #expect(waiting.session != task)
        #expect(recent.history.entries.isEmpty)
        letItGo.yield()
        try await settle { settings.copilotRuns.count == 2 }
        #expect(recent.history.entries.map(\.id) == [CopilotTasksStore.notificationID(fork)])
        let forked = try #require(settings.copilotRuns.first { $0.id == fork })
        #expect(forked.forkedFrom == task)
        #expect(forked.threads?.map(\.id) == [11])
        #expect(store.pending.isEmpty)
        // The session it forked stays as it was.
        #expect(settings.copilotRuns.first { $0.id == task } == original)
        #expect(store.commentWork(on: 11, of: key)?.session == fork)
    }

    // MARK: Prompts to the Copilot app's sessions

    /// Kept by references only: which session took it, which threads, what for and when; once it's sent, or copied for
    /// you to paste, never when nothing went.
    @Test func keepsWhereAPromptWentByReferencesOnly() throws {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        let store = store(settings)
        store.keep(about(), sentTo: .sent, from: session, forking: false, at: now)
        store.keep(about(threads: [12]), sentTo: .forkedAndSent(fork: fork), from: session, forking: true, at: now.addingTimeInterval(1))
        store.keep(about(threads: [13]), sentTo: .fellBack(SessionFallback(reason: "Off", pastesFork: true, session: session)),
                   from: session, forking: true, at: now.addingTimeInterval(2))
        store.keep(about(threads: [14]), sentTo: .notSent("Busy"), from: session, forking: false, at: now.addingTimeInterval(3))
        let kept = settings.copilotSentPrompts
        #expect(kept.map(\.threads) == [[11], [12], [13]])
        #expect(kept.map(\.session) == [session, fork, session])
        #expect(kept.map(\.forkedFrom) == [nil, session, nil])
        #expect(kept.map(\.awaitsFork) == [false, false, true])
        #expect(kept.map(\.copied) == [false, false, true])
        // As it was kept, after BriefBar restarts.
        #expect(AppSettings(defaults: defaults, now: now).copilotSentPrompts == kept)
        let text = String(decoding: try #require(defaults.data(forKey: SettingsKey.copilotSentPrompts)), as: UTF8.self)
        #expect(text.contains(session) && text.contains("4102"))
        // Turning Azure DevOps off forgets them.
        settings.forgetCopilotRuns()
        #expect(AppSettings(defaults: defaults, now: now).copilotSentPrompts.isEmpty)
    }

    /// Any program running as you can write the preferences: what isn't a session's, or a pull request's, is left out, and
    /// so is what's too old, or waited too long for its turn to end.
    @Test func keepsOnlyWhatCanBeUsed() throws {
        let defaults = MemoryDefaults()
        let good = try #require(SentPrompt(about(), session: session, sentAt: now.addingTimeInterval(-60), copied: false))
        let ended = try #require(SentPrompt(about(), session: session, sentAt: now.addingTimeInterval(-86_400), copied: false, ended: .finished))
        let stale = try #require(SentPrompt(about(), session: session, sentAt: now.addingTimeInterval(-86_400), copied: false))
        let old = try #require(SentPrompt(about(), session: session, sentAt: now.addingTimeInterval(-SentPrompt.lifetime - 60), copied: false, ended: .finished))
        var written = try JSONSerialization.jsonObject(with: try JSONEncoder().encode([good, ended, stale, old])) as! [[String: Any]]
        written.append(["pullRequest": ["kind": "pullRequest", "scope": "contoso", "id": "4102"], "session": "../../Library",
                        "purpose": "fix", "threads": [11], "sentAt": now.timeIntervalSinceReferenceDate])
        defaults.set(try JSONSerialization.data(withJSONObject: written), forKey: SettingsKey.copilotSentPrompts)
        #expect(SentPrompt(about(), session: "not-a-session", sentAt: now, copied: false) == nil)
        let settings = AppSettings(defaults: defaults, now: now)
        #expect(settings.copilotSentPrompts == [ended, good])
        // What was left out leaves the preferences too.
        #expect(AppSettings(defaults: defaults, now: now).copilotSentPrompts == [ended, good])
    }

    /// A prompt's turn, as its session's log says, and, once it's over twice in a row, a few seconds apart, how it ended,
    /// which it keeps.
    @Test func followsAPromptsTurnFromItsSessionsLog() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent("session-state/\(session)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("events.jsonl")
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        store.appHomeForTests = home
        let sent = Date()
        settings.copilotSentPrompts = [try #require(SentPrompt(about(), session: session, sentAt: sent, copied: false))]
        func event(_ type: String, _ data: [String: Any] = [:], after seconds: TimeInterval) -> String {
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: data), as: UTF8.self)
            let timestamp = sent.addingTimeInterval(seconds).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            return #"{"type":"\#(type)","data":\#(json),"id":"\#(UUID().uuidString)","timestamp":"\#(timestamp)","parentId":null}"#
        }
        func follow(at date: Date) async throws {
            store.followSentPrompts(now: date)
            try await settle { !store.isFollowingPrompts }
        }
        // Nothing yet: it waits.
        try await follow(at: sent.addingTimeInterval(1))
        #expect(store.commentWork(on: 11, of: key)?.state == .waiting(copied: false))
        #expect(settings.copilotSentPrompts.first?.ended == nil)
        // Taken up and done: over once isn't over, as the end of a turn that ran as it was sent would be.
        let lines = [event("user.message", ["content": "Fix it"], after: 1), event("session.task_complete", ["summary": "Capped it at 30 s", "success": true], after: 2)]
        try (lines.joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
        try await follow(at: sent.addingTimeInterval(3))
        #expect(store.commentWork(on: 11, of: key)?.state == .done("Capped it at 30 s"))
        #expect(settings.copilotSentPrompts.first?.ended == nil)
        try await follow(at: sent.addingTimeInterval(4))
        #expect(settings.copilotSentPrompts.first?.ended == nil)
        try await follow(at: sent.addingTimeInterval(6))
        #expect(settings.copilotSentPrompts.first?.ended == .finished)
        #expect(store.commentWork(on: 11, of: key)?.isReadyFix == true)
        #expect(store.readyFixes(of: key, among: [11]).map(\.session) == [session])
    }

    /// One copied for you to paste that you didn't paste goes after half an hour.
    @Test func forgetsAPromptYouDidntPaste() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let sent = Date()
        settings.copilotSentPrompts = [try #require(SentPrompt(about(), session: session, sentAt: sent, copied: true))]
        #expect(store.commentWork(on: 11, of: key)?.state == .waiting(copied: true))
        store.followSentPrompts(now: sent.addingTimeInterval(SentPrompt.pasteWait + 1))
        try await settle { !store.isFollowingPrompts }
        #expect(settings.copilotSentPrompts.isEmpty)
        #expect(store.commentWork(on: 11, of: key) == nil)
    }

    /// The latest work on a thread is what it says: a fix sent to the app's session after the task that took it on.
    @Test func theLatestWorkOnAThreadIsWhatItSays() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let earlier = now.addingTimeInterval(-3_600)
        settings.copilotRuns = [run(task, startedAt: earlier, ended: .failed, threads: [TakenThread(id: 11, since: earlier)])]
        #expect(store.commentWork(on: 11, of: key)?.state == .failed(nil))
        store.keep(about(), sentTo: .sent, from: session, forking: false, at: now)
        #expect(store.commentWork(on: 11, of: key)?.session == session)
        #expect(store.commentWork(on: 11, of: key)?.isTask == false)
    }

    /// Waits for the store's work, which runs on the main actor between this test's awaits.
    private func settle(until done: () -> Bool) async throws {
        for _ in 0..<500 where !done() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
