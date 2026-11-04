import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import Testing
@testable import AzureDevOpsUI

/// What each comment thread, build or conflicts say Copilot does about them: the latest work that took them on, a task of
/// BriefBar's, which keeps what it took on with its run, or a prompt sent to one of the Copilot app's sessions, which
/// BriefBar keeps by references only and follows from the session's log.
@MainActor
@Suite struct CopilotWorkTests {
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
        _ id: String, _ action: PullRequestAction = .fixComments, startedAt: Date, ended: RunPhase? = nil, taken: [TakenPart]?,
        forkedFrom: String? = nil
    ) -> CopilotRun {
        Self.makeRun(id, action, startedAt: startedAt, ended: ended, taken: taken, forkedFrom: forkedFrom)
    }

    private static func makeRun(
        _ id: String, _ action: PullRequestAction, startedAt: Date, ended: RunPhase? = nil, taken: [TakenPart]? = nil,
        forkedFrom: String? = nil
    ) -> CopilotRun {
        let pullRequest = PullRequestReference(organization: "contoso", project: "Storefront", repository: "payments-api", id: 4102,
                                               sourceBranch: "payments-retry")
        return CopilotRun(
            id: id, workItem: nil, onPullRequest: pullRequest, action: action, options: CopilotModel.standard,
            repository: URL(fileURLWithPath: "/tmp/payments-api"), worktree: URL(fileURLWithPath: "/tmp/copilot-worktrees/payments-api/pr-4102"),
            startedAt: startedAt, process: DetachedProgram.Handle(pid: 0, startedAt: nil), ended: ended, forkedFrom: forkedFrom,
            taken: taken
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
        SentPrompt.About(pullRequest: key, purpose: purpose, parts: threads.map(PullRequestPart.thread))
    }

    // MARK: Sentences

    @Test func saysWhatCopilotDoesInASentence() {
        func said(_ purpose: CopilotWork.Purpose, _ state: CopilotWork.State, fork: String? = nil) -> String {
            CopilotWork(part: .thread(11), purpose: purpose, state: state, session: session, forkedFrom: fork == nil ? nil : task, isTask: false, since: now)
                .sentence(name: fork == nil ? "Retry backoff" : "Retry backoff (fork)", forkOf: fork)
        }
        #expect(said(.explain, .working(nil)) == "Copilot is explaining this in ‘Retry backoff’")
        #expect(said(.fix, .working("Run the tests")) == "Copilot is fixing this in ‘Retry backoff’")
        #expect(said(.fix, .working(nil), fork: "Retry backoff") == "Fixing this in a fork of ‘Retry backoff’")
        #expect(said(.fix, .done("Capped it")) == "Fixed in ‘Retry backoff’, not pushed")
        #expect(said(.fix, .done(nil), fork: "Retry backoff") == "Fixed in a fork of ‘Retry backoff’, not pushed")
        // Why it couldn't goes under the line, whole (`said`).
        #expect(said(.fix, .failed("Error: the build failed\nmore")) == "Couldn't fix it in ‘Retry backoff’")
        #expect(said(.fix, .failed(nil)) == "Couldn't fix it in ‘Retry backoff’")
        #expect(said(.fix, .stopped) == "Stopped in ‘Retry backoff’ before it fixed it")
        #expect(said(.fix, .waiting(copied: true)) == "Copied for ‘Retry backoff’: paste it there")
        #expect(said(.fix, .waiting(copied: false)) == "Sent to ‘Retry backoff’")
        #expect(said(.fix, .needsYou, fork: "Retry backoff") == "A fork of ‘Retry backoff’ is waiting for your answer")
        #expect(said(.pushAndReply, .working(nil)) == "Pushing and replying from ‘Retry backoff’")
        #expect(said(.pushAndReply, .done(nil)) == "Pushed and replied from ‘Retry backoff’")
        #expect(said(.explain, .failed("No session")) == "Couldn't explain it in ‘Retry backoff’")
        #expect(CopilotWork(part: .thread(11), purpose: .fix, state: .failed("Error: the build failed\nmore"), session: session, isTask: false, since: now)
            .said == "Error: the build failed\nmore")
        // A task of BriefBar's, named for what it does, as a task, so that it doesn't read as a command.
        let tasks = CopilotWork(part: .thread(11), purpose: .fix, state: .working(nil), session: task, forkedFrom: nil, isTask: true, since: now)
        #expect(tasks.sentence(name: "Fix Comments", forkOf: nil) == "Copilot is fixing this in the ‘Fix Comments’ task")
        var forked = tasks
        forked.session = fork
        forked.forkedFrom = task
        forked.state = .done(nil)
        #expect(forked.sentence(name: "Fix Comments", forkOf: "Fix Comments") == "Fixed in a fork of the ‘Fix Comments’ task, not pushed")
        #expect(CopilotWork.place("Retry backoff", isFork: false, forkOf: nil) == "‘Retry backoff’")
        #expect(CopilotWork.place("Fix the Build", isFork: false, forkOf: nil, isTask: true) == "the ‘Fix the Build’ task")
        // Without names it knows.
        let unnamed = CopilotWork(part: .thread(11), purpose: .fix, state: .done(nil), session: session, forkedFrom: task, isTask: true, since: now)
        #expect(unnamed.sentence(name: nil, forkOf: nil) == "Fixed in a fork of its session, not pushed")
        #expect(CopilotWork(part: .thread(11), purpose: .fix, state: .working(nil), session: session, forkedFrom: nil, isTask: true, since: now)
            .sentence(name: nil, forkOf: nil) == "Copilot is fixing this in its session")
    }

    // MARK: Tasks of BriefBar's

    /// What it says on a build and on conflicts, in their own words.
    @Test func saysWhatCopilotDoesAboutABuildAndConflicts() {
        func said(_ part: PullRequestPart, _ purpose: CopilotWork.Purpose, _ state: CopilotWork.State, fork: Bool = false) -> String {
            CopilotWork(part: part, purpose: purpose, state: state, session: session, forkedFrom: fork ? task : nil, isTask: false, since: now)
                .sentence(name: "Retry backoff", forkOf: fork ? "Retry backoff" : nil)
        }
        #expect(said(.build(31), .fix, .working(nil)) == "Copilot is fixing this build in ‘Retry backoff’")
        #expect(said(.build(31), .fix, .working(nil), fork: true) == "Fixing this build in a fork of ‘Retry backoff’")
        #expect(said(.build(31), .fix, .done(nil)) == "Fixed in ‘Retry backoff’, not pushed")
        #expect(said(.build(31), .fix, .failed("Error: it still fails\nmore")) == "Couldn't fix it in ‘Retry backoff’")
        #expect(said(.build(31), .explain, .working(nil)) == "Copilot is explaining the failure in ‘Retry backoff’")
        #expect(said(.build(31), .explain, .done(nil)) == "Answered in ‘Retry backoff’")
        #expect(said(.build(31), .pushAndReply, .working(nil)) == "Pushing from ‘Retry backoff’")
        #expect(said(.build(31), .pushAndReply, .done(nil)) == "Pushed from ‘Retry backoff’")
        #expect(said(.build(31), .fix, .stopped) == "Stopped in ‘Retry backoff’ before it fixed it")
        #expect(said(.conflicts, .fix, .working(nil)) == "Copilot is resolving the conflicts in ‘Retry backoff’")
        #expect(said(.conflicts, .fix, .working(nil), fork: true) == "Resolving the conflicts in a fork of ‘Retry backoff’")
        #expect(said(.conflicts, .fix, .done(nil)) == "Resolved in ‘Retry backoff’, not pushed")
        #expect(said(.conflicts, .fix, .failed(nil)) == "Couldn't resolve them in ‘Retry backoff’")
        #expect(said(.conflicts, .fix, .stopped) == "Stopped in ‘Retry backoff’ before it resolved them")
        #expect(said(.conflicts, .pushAndReply, .done(nil)) == "Pushed from ‘Retry backoff’")
    }

    /// A build's fix is ready while the build doesn't pass: a rerun, or a push, that passes ends it; one that fails, or
    /// runs, doesn't. Conflicts' while the pull request has them.
    @Test func aBuildsFixIsReadyUntilTheBuildPasses() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        var record = try #require(DemoData.records(now: now).first { $0.id == key })
        let build = try #require(record.details?.checks.firstIndex { $0.kind == .build })
        record.details?.checks[build].state = .failed
        let pipeline = try #require(record.details?.checks[build].part)
        #expect(record.partsToFix.contains(pipeline))
        #expect(record.partsToFix.contains(.thread(11)))
        #expect(!record.partsToFix.contains(.conflicts))
        settings.copilotRuns = [run(task, .fixBuild, startedAt: now, ended: .finished, taken: [TakenPart(pipeline, since: now)])]
        #expect(store.work(on: pipeline, of: key)?.isReadyFix == true)
        #expect(store.readyFixes(of: key, among: record.partsToFix).map(\.parts) == [[pipeline]])
        #expect(store.readyFixes(of: key, among: record.partsToFix).first?.threads == [])
        // Failed, then expired, as its target branch moved: still to fix, and its fix still ready.
        record.details?.checks[build].state = .expired
        record.details?.checks[build].expiredFrom = .failed
        #expect(record.partsToFix.contains(pipeline))
        #expect(store.readyFixes(of: key, among: record.partsToFix).map(\.parts) == [[pipeline]])
        // Passed, then expired: to queue again, not to fix.
        record.details?.checks[build].expiredFrom = nil
        #expect(!record.partsToFix.contains(pipeline))
        // A rerun, or a push, that passes ends it.
        record.details?.checks[build].state = .passed
        #expect(!record.partsToFix.contains(pipeline))
        #expect(store.readyFixes(of: key, among: record.partsToFix).isEmpty)
        // One that runs again, as after someone else's push, is still to fix.
        record.details?.checks[build].state = .running
        #expect(store.readyFixes(of: key, among: record.partsToFix).map(\.parts) == [[pipeline]])
        // Conflicts while it has them.
        record.pullRequest.mergeStatus = "conflicts"
        #expect(record.partsToFix.last == .conflicts)
        // And each says where it is in the details: a build by its row, conflicts at theirs.
        let snapshot = try #require(PRClassifier.snapshot(for: record, seenCutoff: now, dismissedCutoff: now, now: now))
        let panel = PullRequestPanel(snapshot, record: record)
        #expect(PullRequestDetailsStore.Place.of(pipeline, in: panel) == .of(try #require(panel.checks.first { $0.check?.part == pipeline })))
        #expect(PullRequestDetailsStore.Place.of(.thread(11), in: panel) == .thread(11))
        #expect(PullRequestDetailsStore.Place.of(.build(999), in: panel) == .section(.checks))
        #expect(PullRequestDetailsStore.Place.of(.conflicts, in: panel) == .section(.conflicts))
    }

    /// A run that passes after Copilot took a build on ends what it took on, a task's or a prompt's, for good: a later run
    /// that fails, maybe for another reason, doesn't bring its fix back as ready to push. What it took on after the pass
    /// stays, and so does what it's still at.
    @Test func aPassEndsAFixForGood() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        var record = try #require(DemoData.records(now: now).first { $0.id == key })
        let build = try #require(record.details?.checks.firstIndex { $0.kind == .build })
        let pipeline = try #require(record.details?.checks[build].part)
        let first = now.addingTimeInterval(-3_600)
        settings.copilotRuns = [run(task, .fixBuild, startedAt: first, ended: .finished, taken: [TakenPart(pipeline, since: first)])]
        let prompt = try #require(SentPrompt(
            SentPrompt.About(pullRequest: key, purpose: .fix, parts: [pipeline, .thread(11)]), session: session, sentAt: first,
            copied: false, ended: .finished
        ))
        settings.copilotSentPrompts = [prompt]
        // Failing still: its fix is ready.
        record.details?.checks[build].state = .failed
        record.details?.checks[build].completedAt = first.addingTimeInterval(-60)
        store.endWorkThatsOver(in: [record])
        #expect(store.work(on: pipeline, of: key)?.isReadyFix == true)
        // A run passed since: it's over.
        record.details?.checks[build].state = .passed
        record.details?.checks[build].completedAt = now.addingTimeInterval(-600)
        store.endWorkThatsOver(in: [record])
        #expect(store.work(on: pipeline, of: key) == nil)
        #expect(settings.copilotRuns.first?.taken == nil)
        #expect(settings.copilotSentPrompts.first?.parts == [.thread(11)])
        // And stays so as a later run fails.
        record.details?.checks[build].state = .failed
        record.details?.checks[build].completedAt = now.addingTimeInterval(-60)
        store.endWorkThatsOver(in: [record])
        #expect(store.work(on: pipeline, of: key) == nil)
        #expect(record.partsToFix.contains(pipeline))
        #expect(store.readyFixes(of: key, among: record.partsToFix).map(\.parts) == [[.thread(11)]])
        // What Copilot took on after the pass stays.
        let later = now.addingTimeInterval(-300)
        settings.copilotRuns = [run(task, .fixBuild, startedAt: later, ended: .finished, taken: [TakenPart(pipeline, since: later)])]
        record.details?.checks[build].state = .passed
        record.details?.checks[build].completedAt = now.addingTimeInterval(-600)
        store.endWorkThatsOver(in: [record])
        #expect(store.work(on: pipeline, of: key)?.isReadyFix == true)
        // And so does what it's still at, though a run passed since it started.
        settings.copilotRuns = [run(task, .fixBuild, startedAt: first, taken: [TakenPart(pipeline, since: first)])]
        store.endWorkThatsOver(in: [record])
        #expect(store.work(on: pipeline, of: key)?.isActive == true)
        // But not what a task that's at a comment now went on with: its fix of the build, done before, is over.
        settings.copilotRuns = [run(task, .fixComments, startedAt: later, taken: [
            TakenPart(pipeline, since: first, ended: .finished), TakenPart(.thread(11), since: later),
        ])]
        store.endWorkThatsOver(in: [record])
        #expect(settings.copilotRuns.first?.taken?.map(\.part) == [.thread(11)])
        #expect(store.work(on: pipeline, of: key) == nil)
        // Another policy that runs the same pipeline still fails: it's still to fix, as the bar has it.
        settings.copilotRuns = [run(task, .fixBuild, startedAt: first, ended: .finished, taken: [TakenPart(pipeline, since: first)])]
        var both = record
        var failing = try #require(both.details?.checks[build])
        failing.state = .failed
        failing.buildId = 999
        both.details?.checks.append(failing)
        store.endWorkThatsOver(in: [both])
        #expect(settings.copilotRuns.first?.taken?.map(\.part) == [pipeline])
        #expect(both.partsToFix.contains(pipeline))
        // Its policies couldn't be read: whether it passed isn't known.
        var unknown = record
        unknown.details?.checksKnown = false
        store.endWorkThatsOver(in: [unknown])
        #expect(settings.copilotRuns.first?.taken?.map(\.part) == [pipeline])
        // One that passed, then expired, as its target branch moved, passed.
        settings.copilotRuns = [run(task, .fixBuild, startedAt: first, ended: .finished, taken: [TakenPart(pipeline, since: first)])]
        record.details?.checks[build].state = .expired
        store.endWorkThatsOver(in: [record])
        #expect(settings.copilotRuns.first?.taken == nil)
        // One that failed, then expired, didn't.
        settings.copilotRuns = [run(task, .fixBuild, startedAt: first, ended: .finished, taken: [TakenPart(pipeline, since: first)])]
        record.details?.checks[build].expiredFrom = .failed
        store.endWorkThatsOver(in: [record])
        #expect(settings.copilotRuns.first?.taken?.map(\.part) == [pipeline])
    }

    /// A pass seen while a task that goes on with the session gets ready ends the fix it carries too: it launches without it,
    /// and a later run that fails doesn't bring it back.
    @Test func aPassWhileATaskGetsReadyEndsTheFixItCarries() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        var record = try #require(DemoData.records(now: now).first { $0.id == key })
        let build = try #require(record.details?.checks.firstIndex { $0.kind == .build })
        let pipeline = try #require(record.details?.checks[build].part)
        let first = now.addingTimeInterval(-3_600)
        settings.copilotRuns = [run(task, .fixBuild, startedAt: first, ended: .finished, taken: [TakenPart(pipeline, since: first)])]
        let (go, letItGo) = AsyncStream<Void>.makeStream()
        store.launchForTests = { request, id, launchedAt in
            for await _ in go { break }
            guard case .pullRequest(_, let action) = request.subject else { throw CancellationError() }
            return Self.makeRun(id, action, startedAt: launchedAt)
        }
        store.send(.pullRequest(pullRequest, .fixComments), prompt: "Fix 11", options: CopilotModel.standard,
                   repository: URL(fileURLWithPath: "/tmp/payments-api"), continuing: settings.copilotRuns[0], parts: [.thread(11)])
        #expect(store.pending.first?.taken?.map(\.part) == [pipeline, .thread(11)])
        // A run of the build passed while it got ready.
        record.details?.checks[build].state = .passed
        record.details?.checks[build].completedAt = now.addingTimeInterval(-60)
        store.endWorkThatsOver(in: [record])
        #expect(store.pending.first?.taken?.map(\.part) == [.thread(11)])
        letItGo.yield()
        try await settle { store.pending.isEmpty && settings.copilotRuns.first?.taken != nil }
        #expect(settings.copilotRuns.first?.taken?.map(\.part) == [.thread(11)])
        record.details?.checks[build].state = .failed
        record.details?.checks[build].completedAt = now
        #expect(store.work(on: pipeline, of: key) == nil)
    }

    /// A build's line shows while Copilot is at it, or the build doesn't pass: a rerun, or a push, that passes ends it; so
    /// does a run that failed after what Copilot pushed.
    @Test func aBuildsLineEndsOnceItPasses() {
        func work(_ state: CopilotWork.State, _ purpose: CopilotWork.Purpose = .fix) -> CopilotWork {
            CopilotWork(part: .build(31), purpose: purpose, state: state, session: task, forkedFrom: nil, isTask: true, since: now)
        }
        func check(_ state: Check.State, completedAt: Date? = nil, expiredFrom: Check.State? = nil) -> Check {
            Check(
                name: "shop-web CI", kind: .build, state: state, completedAt: completedAt, buildId: 204_417, definitionId: 31,
                expiredFrom: expiredFrom
            )
        }
        #expect(work(.done(nil)).shows(onBuild: check(.failed)))
        #expect(work(.done(nil)).shows(onBuild: check(.running)))
        #expect(work(.done(nil)).shows(onBuild: nil))
        #expect(!work(.done(nil)).shows(onBuild: check(.passed)))
        // Expired after it passed, as its target branch moved: it's to queue again, not to fix. After it failed, it's still
        // to fix, and its fix stays; a run of what was pushed that failed, then expired, ends it as one that failed does.
        #expect(!work(.failed(nil)).shows(onBuild: check(.expired)))
        #expect(work(.done(nil)).shows(onBuild: check(.expired, completedAt: now.addingTimeInterval(-900), expiredFrom: .failed)))
        #expect(work(.done(nil)).shows(onBuild: check(.expired, completedAt: now.addingTimeInterval(600), expiredFrom: .failed)))
        #expect(!work(.done(nil), .pushAndReply).shows(onBuild: check(.expired, completedAt: now.addingTimeInterval(600), expiredFrom: .failed)))
        #expect(!work(.stopped).shows(onBuild: check(.notApplicable)))
        // Copilot is still at it: it shows, though the build passed meanwhile.
        #expect(work(.working(nil)).shows(onBuild: check(.passed)))
        #expect(work(.waiting(copied: true)).shows(onBuild: check(.passed)))
        // Pushed: while what it pushed runs, and until it passes; a run that failed after it ends it, to fix again. A fix
        // that isn't pushed stays, whatever the build does meanwhile.
        #expect(work(.done(nil), .pushAndReply).shows(onBuild: check(.running)))
        #expect(work(.done(nil), .pushAndReply).shows(onBuild: check(.failed, completedAt: now.addingTimeInterval(-60))))
        #expect(!work(.done(nil), .pushAndReply).shows(onBuild: check(.failed, completedAt: now.addingTimeInterval(600))))
        #expect(work(.done(nil)).shows(onBuild: check(.failed, completedAt: now.addingTimeInterval(600))))
        #expect(work(.failed(nil), .pushAndReply).shows(onBuild: check(.failed, completedAt: now.addingTimeInterval(600))))
        // By when it started to push, not when it ended: a run of what it pushed that failed while it replied on threads
        // ends it too, and so it stays as a later task in the session keeps it.
        var replied = work(.done(nil), .pushAndReply)
        replied.takenAt = now.addingTimeInterval(-600)
        #expect(!replied.shows(onBuild: check(.failed, completedAt: now.addingTimeInterval(-60))))
        #expect(replied.shows(onBuild: check(.failed, completedAt: now.addingTimeInterval(-900))))
    }

    /// What's Left says Copilot's on what's left by what works on its threads, builds and conflicts now, BriefBar's tasks and
    /// prompts sent to the Copilot app's sessions alike: asking you something first, then at work, then sent. What's over,
    /// a prompt copied for you to paste, and a question asked about it aren't Copilot taking care of it.
    @Test func whatsLeftSaysCopilotsOnItFromItsWork() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        var record = try #require(DemoData.records(now: now).first { $0.id == key })
        let build = try #require(record.details?.checks.firstIndex { $0.kind == .build })
        record.details?.checks[build].state = .failed
        let pipeline = try #require(record.details?.checks[build].part)
        #expect(store.onIt(record).isEmpty)
        // A task of BriefBar's fixing the build.
        let first = now.addingTimeInterval(-600)
        settings.copilotRuns = [run(task, .fixBuild, startedAt: first, taken: [TakenPart(pipeline, since: first)])]
        #expect(store.onIt(record).mapValues(\.state) == [.builds: .working(nil)])
        #expect(store.onIt(record)[.builds]?.look.symbol == "arrow.triangle.2.circlepath")
        // Done, it's over: what's left is yours again, to push.
        settings.copilotRuns[0].ended = .finished
        #expect(store.onIt(record).isEmpty)
        // A prompt to one of the app's sessions fixing a comment, at work, then asking you something.
        let fixing = try #require(SentPrompt(about(threads: [11]), session: session, sentAt: now.addingTimeInterval(-60), copied: false))
        settings.copilotSentPrompts = [fixing]
        #expect(store.onIt(record).mapValues(\.state) == [.comments: .waiting(copied: false)])
        store.promptTurns[fixing.id] = SessionTurn(phase: .working(step: "Run the tests"), since: now)
        #expect(store.onIt(record)[.comments]?.state == .working("Run the tests"))
        store.promptTurns[fixing.id] = SessionTurn(phase: .needsYou, since: now)
        #expect(store.onIt(record)[.comments]?.state == .needsYou)
        // Asking you comes first, among the threads.
        let other = try #require(SentPrompt(about(threads: [12]), session: session, sentAt: now.addingTimeInterval(-30), copied: false))
        settings.copilotSentPrompts = [fixing, other]
        store.promptTurns[other.id] = SessionTurn(phase: .working(step: nil), since: now)
        #expect(store.onIt(record)[.comments]?.state == .needsYou)
        // Copied for you to paste, it waits on you; asked about, it's only explained.
        let copied = try #require(SentPrompt(about(threads: [11]), session: session, sentAt: now, copied: true))
        let asked = try #require(SentPrompt(about(.explain, threads: [12]), session: session, sentAt: now, copied: false))
        settings.copilotSentPrompts = [copied, asked]
        #expect(store.onIt(record).isEmpty)
        // Nothing while Send Work to Copilot is off.
        settings.copilotSentPrompts = [fixing]
        settings.copilotEnabled = false
        #expect(store.onIt(record).isEmpty)
    }

    /// Two of a pull request's policies can run the same pipeline: each build's row has its own composer, words and send,
    /// though what Copilot does is the pipeline's.
    @Test func eachBuildsRowHasItsOwnComposer() {
        let first = CopilotComposing(part: .build(31), ask: .fix, row: "build-1")
        let second = CopilotComposing(part: .build(31), ask: .fix, row: "build-2")
        #expect(first != second)
        let drafts = CopilotDrafts()
        drafts.texts[first] = "Skip weekends"
        #expect(drafts.texts[second] == nil)
        let asking = CopilotAsking(
            ask: .fix, part: .build(31), action: .fixBuild, row: "build-2",
            fix: { _, _ in CopilotSending.Fix(prompts: ("", ""), action: .fixBuild, parts: [], handOff: nil) }, question: { _, _ in "" }
        )
        #expect(asking.draftKey == second)
        // And so does Ask in the Session's prompt on its way: one row's doesn't call off the other's.
        let one = Task<Void, Never> {}, other = Task<Void, Never> {}
        drafts.asks[.build(31), row: "build-1"] = one
        drafts.asks[.build(31), row: "build-2"] = other
        #expect(drafts.asks[.build(31), row: "build-1"] != nil)
        drafts.asks[.build(31), row: "build-2"] = nil
        #expect(drafts.asks[.build(31), row: "build-1"] != nil)
        #expect(drafts.asks[.build(31)] == nil)
        drafts.asks[.thread(11)] = other
        #expect(drafts.asks[.thread(11)] != nil)
        drafts.callOffAll()
        #expect(one.isCancelled && other.isCancelled)
        #expect(drafts.asks[.build(31), row: "build-1"] == nil)
        // A thread's has one row.
        #expect(CopilotComposing(part: .thread(11), ask: .fix) == CopilotComposing(part: .thread(11), ask: .fix, row: nil))
    }

    /// The bar at the details' foot says what's ready by what it fixed: comments' fixes, builds', and the conflicts'
    /// resolution.
    @Test func theBarSaysWhatsReadyByWhatItFixed() {
        let place = "‘Retry backoff’"
        #expect(ReadyFixesBar.sentence([.thread(11)], in: place) == "1 fix ready in ‘Retry backoff’")
        #expect(ReadyFixesBar.sentence([.thread(11), .thread(12)], in: place) == "2 fixes ready in ‘Retry backoff’")
        #expect(ReadyFixesBar.sentence([.build(31)], in: "the ‘Fix the Build’ task") == "A build's fix ready in the ‘Fix the Build’ task")
        #expect(ReadyFixesBar.sentence([.conflicts], in: place) == "The conflicts' resolution ready in ‘Retry backoff’")
        #expect(ReadyFixesBar.sentence([.thread(11), .conflicts], in: place) == "1 fix and the conflicts' resolution ready in ‘Retry backoff’")
        #expect(ReadyFixesBar.sentence([.thread(11), .build(31), .build(32), .conflicts], in: place)
            == "1 fix, 2 builds' fixes and the conflicts' resolution ready in ‘Retry backoff’")
    }

    /// Fix the Build quotes what the details read of a build, once one was opened there: its failed tests and the end of its
    /// log; else the errors its check had. Another run's, as before a push, isn't this one's.
    @Test func fixTheBuildQuotesWhatTheDetailsRead() async throws {
        let record = try #require(DemoData.records(now: now).first { $0.id.number == 4088 })
        let investigation = try #require(DemoData.buildInvestigation(buildId: 204_417, of: record.pullRequest, now: now))
        let read = await PullRequestTasks.reports(for: record, client: nil, investigations: [204_417: investigation])
        #expect(read.map(\.name) == ["shop-web CI"])
        #expect(read.first?.tests.count == 2)
        #expect(read.first?.log.isEmpty == false)
        let plain = await PullRequestTasks.reports(for: record, client: nil)
        #expect(plain.first?.tests.isEmpty == true)
        #expect(plain.first?.errors == ["2 tests failed in DeliveryEstimateTests."])
        var another = investigation
        another.run.id = 204_500
        #expect(await PullRequestTasks.reports(for: record, client: nil, investigations: [204_417: another]).first?.tests.isEmpty == true)
    }

    /// Push & Reply from the pull request's menu lists the threads that wait on you; it takes along the builds and
    /// conflicts whose fixes are done in the session it goes on with, which its push ships, so each says it's pushed.
    @Test func pushAndReplyTakesAlongTheSessionsOtherFixes() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let first = now.addingTimeInterval(-600)
        settings.copilotRuns = [run(task, .fixBuild, startedAt: first, ended: .finished, taken: [TakenPart(.build(31), since: first)])]
        #expect(store.unpushedParts(of: key, in: task) == [.build(31)])
        #expect(store.unpushedParts(of: key, in: session).isEmpty)
        #expect(store.unpushedParts(of: PRKey("contoso", 4099), in: task).isEmpty)
        // And those that prompts to one of the app's sessions fixed there.
        let resolved = try #require(SentPrompt(
            SentPrompt.About(pullRequest: key, purpose: .fix, parts: [.conflicts, .thread(11)]), session: session, sentAt: first, copied: false,
            ended: .finished
        ))
        settings.copilotSentPrompts = [resolved]
        #expect(store.unpushedParts(of: key, in: session) == [.conflicts])
        // Shipped, it's pushed: there's nothing left to take along.
        let shipping = CopilotRun.taken(
            goingOnWith: settings.copilotRuns[0], on: pullRequest.reference, taking: store.unpushedParts(of: key, in: task), for: .pushAndReply,
            at: now
        )
        settings.copilotRuns = [run(task, .pushAndReply, startedAt: now, ended: .finished, taken: shipping)]
        #expect(store.work(on: .build(31), of: key)?.sentence(name: "Fix the Build", forkOf: nil) == "Pushed from the ‘Fix the Build’ task")
        #expect(store.unpushedParts(of: key, in: task).isEmpty)
        #expect(store.readyFixes(of: key, among: [.build(31)]).isEmpty)
    }

    /// What each action takes on, as its prompt does: Fix the Build its builds that failed, Resolve Conflicts the
    /// conflicts, Push & Reply what it ships, with its threads alone.
    @Test func eachActionTakesOnWhatItsPromptDoes() throws {
        var record = try #require(DemoData.records(now: now).first { $0.id.number == 4088 })
        #expect(PullRequestTasks.parts(.fixBuild, for: record) == [.build(31)])
        #expect(PullRequestTasks.parts(.resolveConflicts, for: record) == [.conflicts])
        #expect(PullRequestTasks.parts(.review, for: record) == [])
        // Push & Reply of a build's fix alone replies on none of its threads, and neither does one of no fix it knows; without
        // a scope, as agents send it, it lists the threads Fix Comments does.
        #expect(PullRequestTasks.parts(.pushAndReply, for: record, shipping: [.build(31)]) == [.build(31)])
        #expect(PullRequestTasks.shippedThreads([.build(31)]) == [])
        #expect(PullRequestTasks.shippedThreads([]) == [])
        #expect(PullRequestTasks.parts(.pushAndReply, for: record, shipping: []) == [])
        #expect(PullRequestTasks.shippedThreads(nil) == nil)
        #expect(PullRequestTasks.parts(.pushAndReply, for: record) == PullRequestTasks.parts(.fixComments, for: record))
        // A build whose policy doesn't say its pipeline isn't one it can take on.
        let checks = record.details?.checks.map { check in
            var check = check
            check.definitionId = nil
            return check
        }
        record.details?.checks = checks ?? []
        #expect(PullRequestTasks.parts(.fixBuild, for: record) == [])
    }

    /// A task's thread says how the task stands; once a later task goes on with its session, how it ended then; and while
    /// Push & Reply ships it, how that stands.
    @Test func aTasksThreadsSayHowItStands() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let first = now.addingTimeInterval(-600), second = now.addingTimeInterval(-60)
        settings.copilotRuns = [run(task, startedAt: first, taken: [TakenPart(.thread(11), since: first)])]
        #expect(store.work(on: .thread(11), of: key)?.state == .working(nil))
        #expect(store.work(on: .thread(11), of: key)?.isTask == true)
        #expect(store.work(on: .thread(12), of: key) == nil)
        #expect(store.work(on: .thread(11), of: PRKey("contoso", 4099)) == nil)
        // Gone on with, for another thread: 11 was fixed then, 12 is being fixed now.
        settings.copilotRuns = [run(task, startedAt: second, taken: [
            TakenPart(.thread(11), since: first, ended: .finished), TakenPart(.thread(12), since: second),
        ])]
        #expect(store.work(on: .thread(11), of: key)?.state == .done(nil))
        #expect(store.work(on: .thread(11), of: key)?.isReadyFix == true)
        #expect(store.work(on: .thread(12), of: key)?.state == .working(nil))
        settings.copilotRuns = [run(task, startedAt: second, ended: .finished, taken: [
            TakenPart(.thread(11), since: first, ended: .finished), TakenPart(.thread(12), since: second),
        ])]
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12), .thread(13)]) == [ReadyFixes(session: task, forkedFrom: nil, isTask: true, parts: [.thread(11), .thread(12)], latest: second)])
        // Only the threads still open.
        #expect(store.readyFixes(of: key, among: [.thread(12)]).map(\.threads) == [[12]])
        // Push & Reply ships those its prompt lists.
        settings.copilotRuns = [run(task, .pushAndReply, startedAt: now, taken: [
            TakenPart(.thread(11), since: now, ships: true), TakenPart(.thread(12), since: now, ships: true),
        ])]
        let shipping = try #require(store.work(on: .thread(11), of: key))
        #expect(shipping.purpose == .pushAndReply)
        #expect(shipping.state == .working(nil))
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).isEmpty)
        // One that failed, or stopped, didn't push them: they're still ready, for Push & Reply again.
        settings.copilotRuns = [run(task, .pushAndReply, startedAt: now, ended: .failed, taken: [
            TakenPart(.thread(11), since: now, ships: true), TakenPart(.thread(12), since: now, ships: true),
        ])]
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).map(\.threads) == [[11, 12]])
        // And those it took on that prompts to the session fixed, rather than its runs: once it's done, they're pushed.
        settings.copilotRuns = [run(task, .pushAndReply, startedAt: now, ended: .finished, taken: [TakenPart(.thread(13), since: now, ships: true)])]
        let shipped = try #require(store.work(on: .thread(13), of: key))
        #expect(shipped.purpose == .pushAndReply)
        #expect(!shipped.isReadyFix)
        #expect(store.readyFixes(of: key, among: [.thread(13)]).isEmpty)
        // Nothing while Send Work to Copilot is off.
        settings.copilotEnabled = false
        #expect(store.work(on: .thread(11), of: key) == nil)
    }

    /// A Push & Reply whose prompt lists some of the threads its session fixed replies on those alone, but commits and pushes
    /// all its session changed: the others say they're pushed, without a reply, while it pushes and once it has, rather than
    /// fixed and not pushed; and one that another session fixed since stays that one's.
    @Test func pushAndReplyRepliesOnlyOnTheThreadsItListed() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let first = now.addingTimeInterval(-600), second = now.addingTimeInterval(-300)
        // The task fixed 11 and 12; it ships 12 alone, and pushes 11's fix with it.
        settings.copilotRuns = [run(task, .pushAndReply, startedAt: now, taken: [
            TakenPart(.thread(11), since: first, ended: .finished), TakenPart(.thread(12), since: now, ships: true),
        ])]
        #expect(store.work(on: .thread(12), of: key)?.sentence(name: "Fix Comments", forkOf: nil) == "Pushing and replying from the ‘Fix Comments’ task")
        #expect(store.work(on: .thread(11), of: key)?.sentence(name: "Fix Comments", forkOf: nil) == "Pushing from the ‘Fix Comments’ task")
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).isEmpty)
        settings.copilotRuns[0].ended = .finished
        #expect(store.work(on: .thread(12), of: key)?.sentence(name: "Fix Comments", forkOf: nil) == "Pushed and replied from the ‘Fix Comments’ task")
        let eleven = try #require(store.work(on: .thread(11), of: key))
        #expect(eleven.sentence(name: "Fix Comments", forkOf: nil) == "Pushed from the ‘Fix Comments’ task, without a reply")
        #expect(!eleven.replies)
        #expect(!eleven.waitsToBePushed)
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).isEmpty)
        // One that failed pushed nothing: 11's fix is ready, as 12's is, to Push & Reply again.
        settings.copilotRuns[0].ended = .failed
        #expect(store.work(on: .thread(11), of: key)?.sentence(name: "Fix Comments", forkOf: nil) == "Fixed in the ‘Fix Comments’ task, not pushed")
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).map(\.threads) == [[11, 12]])
        // A fork fixed 11 again since: its fix is 11's latest, and it's ready there.
        settings.copilotRuns[0].ended = .finished
        settings.copilotRuns.append(run(fork, startedAt: second, ended: .finished, taken: [TakenPart(.thread(11), since: second)], forkedFrom: task))
        #expect(store.work(on: .thread(11), of: key)?.session == fork)
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).map(\.session) == [fork])
    }

    /// A Push & Reply sent to one of the Copilot app's sessions pushes the fixes prompts sent there before, those its prompt
    /// doesn't list too; one copied for you to paste, which you haven't, pushes nothing yet.
    @Test func aPushSentToASessionCarriesItsOtherFixes() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let fixed = try #require(SentPrompt(about(threads: [11]), session: session, sentAt: now.addingTimeInterval(-600), copied: false, ended: .finished))
        let build = try #require(SentPrompt(
            SentPrompt.About(pullRequest: key, purpose: .fix, parts: [.build(31)]), session: session, sentAt: now.addingTimeInterval(-500),
            copied: false, ended: .finished
        ))
        let copied = try #require(SentPrompt(about(.pushAndReply, threads: [12]), session: session, sentAt: now.addingTimeInterval(-60), copied: true))
        settings.copilotSentPrompts = [fixed, build, copied]
        #expect(store.work(on: .thread(11), of: key)?.isReadyFix == true)
        #expect(Set(store.readyFixes(of: key, among: [.thread(11), .build(31)]).flatMap(\.parts)) == [.thread(11), .build(31)])
        let pushed = try #require(SentPrompt(about(.pushAndReply, threads: [12]), session: session, sentAt: now.addingTimeInterval(-30), copied: false, ended: .finished))
        settings.copilotSentPrompts = [fixed, build, pushed]
        #expect(store.work(on: .thread(11), of: key)?.sentence(name: "Retry backoff", forkOf: nil) == "Pushed from ‘Retry backoff’, without a reply")
        #expect(store.work(on: .build(31), of: key)?.sentence(name: "Retry backoff", forkOf: nil) == "Pushed from ‘Retry backoff’")
        #expect(store.readyFixes(of: key, among: [.thread(11), .build(31)]).isEmpty)
        // Another session's Push & Reply pushes nothing of this one's.
        let other = "2f8a4c6e-1b3d-4e5f-8a7b-9c0d1e2f3a15"
        settings.copilotSentPrompts = [fixed, try #require(SentPrompt(about(.pushAndReply, threads: [12]), session: other, sentAt: now, copied: false, ended: .finished))]
        #expect(store.work(on: .thread(11), of: key)?.isReadyFix == true)
    }

    /// A thread whose Push & Reply failed, or stopped, is still to push: a later one in its session pushes it with the rest,
    /// though it doesn't list it, and doesn't reply on it.
    @Test func aLaterPushCarriesWhatAFailedOneDidnt() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let first = now.addingTimeInterval(-600)
        // The session's push of 11 failed; its push now lists 12 alone.
        settings.copilotRuns = [run(task, .pushAndReply, startedAt: now, taken: [
            TakenPart(.thread(11), since: first, ended: .failed, ships: true), TakenPart(.thread(12), since: now, ships: true),
        ])]
        #expect(store.work(on: .thread(11), of: key)?.sentence(name: "Fix Comments", forkOf: nil) == "Pushing from the ‘Fix Comments’ task")
        settings.copilotRuns[0].ended = .finished
        #expect(store.work(on: .thread(11), of: key)?.sentence(name: "Fix Comments", forkOf: nil) == "Pushed from the ‘Fix Comments’ task, without a reply")
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).isEmpty)
        // The same with prompts sent to one of the Copilot app's sessions.
        settings.copilotRuns = []
        let failed = try #require(SentPrompt(about(.pushAndReply, threads: [11]), session: session, sentAt: first, copied: false, ended: .failed))
        settings.copilotSentPrompts = [failed]
        #expect(store.readyFixes(of: key, among: [.thread(11)]).map(\.threads) == [[11]])
        let pushed = try #require(SentPrompt(about(.pushAndReply, threads: [12]), session: session, sentAt: now, copied: false, ended: .finished))
        settings.copilotSentPrompts = [failed, pushed]
        #expect(store.work(on: .thread(11), of: key)?.sentence(name: "Retry backoff", forkOf: nil) == "Pushed from ‘Retry backoff’, without a reply")
        #expect(store.readyFixes(of: key, among: [.thread(11)]).isEmpty)
    }

    /// A fix that a Push & Reply pushed along, without listing it, stays pushed as its session goes on, even once what that
    /// push listed is taken on again (`CopilotRun.pushes`); a fix done after it isn't pushed.
    @Test func aFixPushedAlongStaysPushedAsItsSessionGoesOn() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let first = now.addingTimeInterval(-900), pushedAt = now.addingTimeInterval(-600), again = now.addingTimeInterval(-300)
        // 11 and 12 fixed; a push listed 12 alone, and finished; then 12 was fixed again, in its place.
        var going = run(task, startedAt: again, ended: .finished, taken: [
            TakenPart(.thread(11), since: first, ended: .finished), TakenPart(.thread(12), since: again),
        ])
        going.pushes = [SessionPush(since: pushedAt, ended: .finished)]
        settings.copilotRuns = [going]
        let eleven = try #require(store.work(on: .thread(11), of: key))
        #expect(eleven.sentence(name: "Fix Comments", forkOf: nil) == "Pushed from the ‘Fix Comments’ task, without a reply")
        #expect(eleven.since == pushedAt)
        #expect(store.work(on: .thread(12), of: key)?.isReadyFix == true)
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).map(\.threads) == [[12]])
    }

    /// A push that failed, stopped, or waits for you to paste it, after one that pushed a fix along, doesn't make that fix
    /// ready to push again: only fixing it again does.
    @Test func aLaterPushThatFailedDoesntUndoAnEarlierOne() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let first = now.addingTimeInterval(-900), pushedAt = now.addingTimeInterval(-600)
        var failing = run(task, .pushAndReply, startedAt: now, ended: .failed, taken: [
            TakenPart(.thread(11), since: first, ended: .finished), TakenPart(.thread(12), since: pushedAt, ended: .finished, ships: true),
            TakenPart(.thread(13), since: now, ships: true),
        ])
        failing.pushes = [SessionPush(since: pushedAt, ended: .finished)]
        settings.copilotRuns = [failing]
        #expect(store.work(on: .thread(11), of: key)?.sentence(name: "Fix Comments", forkOf: nil) == "Pushed from the ‘Fix Comments’ task, without a reply")
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12), .thread(13)]).map(\.threads) == [[13]])
        // The same with prompts: a later one copied for you to paste, then one that failed.
        settings.copilotRuns = []
        let fixed = try #require(SentPrompt(about(threads: [11]), session: session, sentAt: first, copied: false, ended: .finished))
        let pushed = try #require(SentPrompt(about(.pushAndReply, threads: [12]), session: session, sentAt: pushedAt, copied: false, ended: .finished))
        let copied = try #require(SentPrompt(about(.pushAndReply, threads: [13]), session: session, sentAt: now, copied: true))
        settings.copilotSentPrompts = [fixed, pushed, copied]
        #expect(store.work(on: .thread(11), of: key)?.sentence(name: "Retry backoff", forkOf: nil) == "Pushed from ‘Retry backoff’, without a reply")
        let failed = try #require(SentPrompt(about(.pushAndReply, threads: [13]), session: session, sentAt: now, copied: false, ended: .failed))
        settings.copilotSentPrompts = [fixed, pushed, failed]
        #expect(store.work(on: .thread(11), of: key)?.sentence(name: "Retry backoff", forkOf: nil) == "Pushed from ‘Retry backoff’, without a reply")
        let refixed = try #require(SentPrompt(about(threads: [11]), session: session, sentAt: now.addingTimeInterval(-60), copied: false, ended: .finished))
        settings.copilotSentPrompts = [fixed, pushed, refixed, failed]
        #expect(store.work(on: .thread(11), of: key)?.isReadyFix == true)
    }

    /// Going on with a session keeps the Push & Reply tasks that ran there, each with how it ended, on the same pull
    /// request, with the task's run; not the run of one of the Copilot app's sessions only about to start.
    @Test func aSessionKeepsItsPushes() async throws {
        let first = now.addingTimeInterval(-600), before = now.addingTimeInterval(-900)
        var push = run(task, .pushAndReply, startedAt: first, ended: .finished, taken: [TakenPart(.thread(12), since: first, ships: true)])
        let reference = try #require(push.onPullRequest)
        #expect(CopilotRun.pushes(goingOnWith: push, on: reference) == [SessionPush(since: first, ended: .finished)])
        push.pushes = [SessionPush(since: before, ended: .failed)]
        #expect(CopilotRun.pushes(goingOnWith: push, on: reference) == [SessionPush(since: before, ended: .failed), SessionPush(since: first, ended: .finished)])
        // One not seen to end stopped.
        push.ended = nil
        #expect(CopilotRun.pushes(goingOnWith: push, on: reference)?.last == SessionPush(since: first, ended: .stopped))
        #expect(CopilotRun.pushes(goingOnWith: run(task, startedAt: first, ended: .finished, taken: nil), on: reference) == nil)
        var other = reference
        other.id = 4099
        #expect(CopilotRun.pushes(goingOnWith: push, on: other) == nil)
        #expect(CopilotRun.pushes(goingOnWith: nil, on: reference) == nil)
        // Sent: its run keeps them.
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        store.launchForTests = { request, id, now in
            guard case .pullRequest(_, let action) = request.subject else { throw CancellationError() }
            return Self.makeRun(id, action, startedAt: now)
        }
        push.ended = .finished
        push.pushes = nil
        settings.copilotRuns = [push]
        store.send(.pullRequest(pullRequest, .fixComments), prompt: "Fix 12 again", options: CopilotModel.standard,
                   repository: URL(fileURLWithPath: "/tmp/payments-api"), continuing: push, parts: [.thread(12)])
        try await settle { settings.copilotRuns.first?.action == .fixComments }
        #expect(settings.copilotRuns.first?.pushes == [SessionPush(since: first, ended: .finished)])
    }

    /// Once a Push & Reply that shipped a thread finished, and its session went on, the thread still says it's pushed: an
    /// older fix of it, by a prompt sent to the session or in another session, isn't its latest again.
    @Test func aThreadShippedStaysPushedAsItsSessionGoesOn() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let first = now.addingTimeInterval(-900), shipped = now.addingTimeInterval(-300)
        settings.copilotSentPrompts = [try #require(SentPrompt(about(), session: task, sentAt: first, copied: false, ended: .finished))]
        settings.copilotRuns = [
            run(fork, startedAt: first, ended: .finished, taken: [TakenPart(.thread(11), since: first)]),
            run(task, startedAt: now, taken: [
                TakenPart(.thread(11), since: shipped, ended: .finished, ships: true), TakenPart(.thread(12), since: now),
            ]),
        ]
        let eleven = try #require(store.work(on: .thread(11), of: key))
        #expect(eleven.sentence(name: "Fix Comments", forkOf: nil) == "Pushed and replied from the ‘Fix Comments’ task")
        #expect(eleven.since == shipped)
        #expect(store.readyFixes(of: key, among: [.thread(11)]).isEmpty)
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
                   repository: URL(fileURLWithPath: "/tmp/payments-api"), parts: [.thread(11)])
        // While it gets ready, its thread says Copilot is on it.
        #expect(store.work(on: .thread(11), of: key)?.state == .working(nil))
        try await settle { !settings.copilotRuns.isEmpty }
        let started = try #require(settings.copilotRuns.first)
        #expect(started.taken?.map(\.part) == [.thread(11)])
        // It ended; going on with it for 12 keeps 11, as it ended.
        settings.copilotRuns[0].ended = .finished
        store.send(.pullRequest(pullRequest, .fixComments), prompt: "Fix 12", options: CopilotModel.standard,
                   repository: URL(fileURLWithPath: "/tmp/payments-api"), continuing: settings.copilotRuns[0], parts: [.thread(12)])
        try await settle { settings.copilotRuns.first?.taken?.count == 2 }
        let kept: [[PullRequestPart: RunPhase?]]? = settings.copilotRuns.first?.taken?.map { [$0.part: $0.ended] }
        #expect(kept == [[.thread(11): .finished], [.thread(12): nil]])
    }

    /// Going on with a session with the Copilot CLI is its next turn: a prompt sent it before, whose turn wasn't seen to
    /// end, isn't followed after, once the run started.
    @Test func goingOnWithASessionOverlapsThePromptsSentItBefore() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        store.launchForTests = { request, id, now in
            guard case .pullRequest(_, let action) = request.subject else { throw CancellationError() }
            return Self.makeRun(id, action, startedAt: now)
        }
        store.send(.pullRequest(pullRequest, .fixComments), prompt: "Fix 11", options: CopilotModel.standard,
                   repository: URL(fileURLWithPath: "/tmp/payments-api"), parts: [.thread(11)])
        try await settle { !settings.copilotRuns.isEmpty }
        settings.copilotRuns[0].ended = .finished
        store.keep(about(threads: [12]), sentTo: .sent, from: settings.copilotRuns[0].id, forking: false, at: Date().addingTimeInterval(-5))
        #expect(settings.copilotSentPrompts.first?.isFollowed == true)
        store.send(.pullRequest(pullRequest, .fixComments), prompt: "Fix 13", options: CopilotModel.standard,
                   repository: URL(fileURLWithPath: "/tmp/payments-api"), continuing: settings.copilotRuns[0], parts: [.thread(13)])
        try await settle { settings.copilotSentPrompts.first?.overlapped == true }
    }

    /// Nothing starts once Azure DevOps stopped, as it may while an inline Fix looks for where to send it.
    @Test func sendsNothingOnceStopped() {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        store.stop()
        store.send(.pullRequest(pullRequest, .fixComments), prompt: "Fix 11", options: CopilotModel.standard,
                   repository: URL(fileURLWithPath: "/tmp/payments-api"), parts: [.thread(11)])
        #expect(store.pending.isEmpty)
        #expect(settings.copilotRuns.isEmpty)
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
        let original = run(task, startedAt: now.addingTimeInterval(-3_600), ended: .finished, taken: nil)
        settings.copilotRuns = [original]
        store.send(.pullRequest(pullRequest, .fixComments), prompt: "Fix 11", options: CopilotModel.standard,
                   repository: original.repository, forking: original, parts: [.thread(11)])
        let waiting = try #require(store.work(on: .thread(11), of: key))
        #expect(waiting.forkedFrom == task)
        #expect(waiting.session != task)
        #expect(recent.history.entries.isEmpty)
        letItGo.yield()
        try await settle { settings.copilotRuns.count == 2 }
        #expect(recent.history.entries.map(\.id) == [CopilotTasksStore.notificationID(fork)])
        let forked = try #require(settings.copilotRuns.first { $0.id == fork })
        #expect(forked.forkedFrom == task)
        #expect(forked.taken?.map(\.part) == [.thread(11)])
        #expect(store.pending.isEmpty)
        // The session it forked stays as it was.
        #expect(settings.copilotRuns.first { $0.id == task } == original)
        #expect(store.work(on: .thread(11), of: key)?.session == fork)
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
        #expect(kept.map(\.parts) == [[.thread(11)], [.thread(12)], [.thread(13)]])
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
        // And a delivery that ends after it stopped keeps nothing.
        store.stop()
        store.keep(about(), sentTo: .sent, from: session, forking: false, at: now)
        #expect(settings.copilotSentPrompts.isEmpty)
    }

    /// A prompt copied as `/fork` follows the fork the Copilot app made of its session since, when it made one: with more,
    /// any could be another's, so it follows none.
    @Test func followsAForkOnlyWhenThereIsJustOne() {
        #expect(SentPrompt.onlyFork([fork]) == fork)
        #expect(SentPrompt.onlyFork([fork, task]) == nil)
        #expect(SentPrompt.onlyFork([]) == nil)
        #expect(SentPrompt.onlyFork(nil) == nil)
    }

    /// Any program running as you can write the preferences: what isn't a session's, or a pull request's, is left out, and
    /// so is what's too old. One that waited long for its turn to end stays, for its session's log to say what became of it.
    @Test func keepsOnlyWhatCanBeUsed() throws {
        let defaults = MemoryDefaults()
        let good = try #require(SentPrompt(about(), session: session, sentAt: now.addingTimeInterval(-60), copied: false))
        let ended = try #require(SentPrompt(about(), session: session, sentAt: now.addingTimeInterval(-86_400), copied: false, ended: .finished))
        let stale = try #require(SentPrompt(about(), session: session, sentAt: now.addingTimeInterval(-80_000), copied: false))
        let old = try #require(SentPrompt(about(), session: session, sentAt: now.addingTimeInterval(-SentPrompt.lifetime - 60), copied: false, ended: .finished))
        var written = try JSONSerialization.jsonObject(with: try JSONEncoder().encode([good, ended, stale, old])) as! [[String: Any]]
        written.append(["pullRequest": ["kind": "pullRequest", "scope": "contoso", "id": "4102"], "session": "../../Library",
                        "purpose": "fix", "parts": [["kind": "thread", "id": 11]], "sentAt": now.timeIntervalSinceReferenceDate])
        defaults.set(try JSONSerialization.data(withJSONObject: written), forKey: SettingsKey.copilotSentPrompts)
        #expect(SentPrompt(about(), session: "not-a-session", sentAt: now, copied: false) == nil)
        let settings = AppSettings(defaults: defaults, now: now)
        #expect(settings.copilotSentPrompts == [ended, stale, good])
        // What was left out leaves the preferences too.
        #expect(AppSettings(defaults: defaults, now: now).copilotSentPrompts == [ended, stale, good])
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
        #expect(store.work(on: .thread(11), of: key)?.state == .waiting(copied: false))
        #expect(settings.copilotSentPrompts.first?.ended == nil)
        // Taken up and done: over once isn't over, as the end of a turn that ran as it was sent would be.
        let lines = [event("user.message", ["content": "Fix it"], after: 1), event("session.task_complete", ["summary": "Capped it at 30 s", "success": true], after: 2)]
        try (lines.joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
        try await follow(at: sent.addingTimeInterval(3))
        #expect(store.work(on: .thread(11), of: key)?.state == .done("Capped it at 30 s"))
        #expect(settings.copilotSentPrompts.first?.ended == nil)
        try await follow(at: sent.addingTimeInterval(4))
        #expect(settings.copilotSentPrompts.first?.ended == nil)
        try await follow(at: sent.addingTimeInterval(6))
        #expect(settings.copilotSentPrompts.first?.ended == .finished)
        #expect(store.work(on: .thread(11), of: key)?.isReadyFix == true)
        #expect(store.readyFixes(of: key, among: [.thread(11)]).map(\.session) == [session])
    }

    /// While another prompt is being sent to its session, a prompt's turn isn't followed: what the log says may be that
    /// one's turn. Once nothing went, it's followed again.
    @Test func followsNoPromptWhileAnotherIsSentToItsSession() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent("session-state/\(session)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        store.appHomeForTests = home
        let sent = Date()
        settings.copilotSentPrompts = [try #require(SentPrompt(about(), session: session, sentAt: sent, copied: false))]
        let stamp = { (seconds: TimeInterval) in sent.addingTimeInterval(seconds).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) }
        let lines = [
            #"{"type":"user.message","data":{"content":"Fix it"},"id":"a","timestamp":"\#(stamp(1))","parentId":null}"#,
            #"{"type":"session.task_complete","data":{"summary":"Capped it","success":true},"id":"b","timestamp":"\#(stamp(2))","parentId":null}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        func follow(at date: Date) async throws {
            store.followSentPrompts(now: date)
            try await settle { !store.isFollowingPrompts }
        }
        // Two sends at once: until both are done, nothing's followed.
        store.pauseFollowing(session)
        store.pauseFollowing(session)
        try await follow(at: sent.addingTimeInterval(3))
        store.resumeFollowing(session)
        try await follow(at: sent.addingTimeInterval(6))
        #expect(settings.copilotSentPrompts.first?.ended == nil)
        #expect(store.work(on: .thread(11), of: key)?.state == .waiting(copied: false))
        store.resumeFollowing(session)
        #expect(store.followingPaused.isEmpty)
        try await follow(at: sent.addingTimeInterval(7))
        try await follow(at: sent.addingTimeInterval(10))
        #expect(settings.copilotSentPrompts.first?.ended == .finished)
    }

    /// One pasted in a terminal where the Copilot CLI has the session, in the CLI's own folder rather than the app's, is
    /// followed there.
    @Test func followsAPromptInTheCLIsFolder() async throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cli = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: app)
            try? FileManager.default.removeItem(at: cli)
        }
        let folder = cli.appendingPathComponent("session-state/\(session)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        store.appHomeForTests = app
        store.useEnvironment(["COPILOT_HOME": cli.path])
        let sent = Date()
        settings.copilotSentPrompts = [try #require(SentPrompt(about(), session: session, sentAt: sent, copied: true))]
        let stamp = { (seconds: TimeInterval) in sent.addingTimeInterval(seconds).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) }
        let lines = [
            #"{"type":"user.message","data":{"content":"Fix it"},"id":"a","timestamp":"\#(stamp(1))","parentId":null}"#,
            #"{"type":"session.task_complete","data":{"summary":"Capped it","success":true},"id":"b","timestamp":"\#(stamp(2))","parentId":null}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        store.followSentPrompts(now: sent.addingTimeInterval(3))
        try await settle { !store.isFollowingPrompts }
        #expect(store.work(on: .thread(11), of: key)?.state == .done("Capped it"))
    }

    /// A question asked about a thread since its fix, as its line says, doesn't push the fix: it's still ready.
    @Test func aQuestionSinceDoesntPushAFix() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let fixed = try #require(SentPrompt(about(), session: session, sentAt: now.addingTimeInterval(-120), copied: false, ended: .finished))
        let asked = try #require(SentPrompt(about(.explain), session: session, sentAt: now.addingTimeInterval(-60), copied: false))
        settings.copilotSentPrompts = [fixed, asked]
        #expect(store.work(on: .thread(11), of: key)?.purpose == .explain)
        #expect(store.readyFixes(of: key, among: [.thread(11)]).map(\.threads) == [[11]])
    }

    /// A delivery that took a while, as one that waits for a session to load can, keeps the prompts sent meanwhile, faster.
    @Test func aSlowDeliveryKeepsThePromptsSentMeanwhile() {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let other = "2f8a4c6e-1b3d-4e5f-8a7b-9c0d1e2f3a15"
        store.keep(about(threads: [12]), sentTo: .sent, from: other, forking: false, at: Date())
        store.keep(about(), sentTo: .sent, from: session, forking: false, at: Date().addingTimeInterval(-100))
        #expect(Set(settings.copilotSentPrompts.map(\.parts)) == [[.thread(11)], [.thread(12)]])
    }

    /// A prompt sent to one of the Copilot app's sessions about pull requests' threads, when another went to that session
    /// before its turn was seen to end: which turn's end is its, the session's log can't tell, so it says so, stops being
    /// followed, and leaves the ready-fixes bar alone. Kept so after BriefBar restarts, and past `followLimit`.
    @Test func aPromptOverlappedByAnotherSaysItsOutcomeIsntKnown() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        store.keep(about(), sentTo: .sent, from: session, forking: false, at: now.addingTimeInterval(-60))
        let first = try #require(settings.copilotSentPrompts.first)
        // Seen over once only: that may be the end of the turn that ran as it was sent.
        store.promptTurns[first.id] = SessionTurn(phase: .finished(summary: "Done"), since: now.addingTimeInterval(-10))
        store.keep(about(threads: [12]), sentTo: .sent, from: session, forking: false, at: now)
        #expect(settings.copilotSentPrompts.first { $0.parts == [.thread(11)] }?.overlapped == true)
        #expect(settings.copilotSentPrompts.first { $0.parts == [.thread(12)] }?.isFollowed == true)
        #expect(store.promptTurns[first.id] == nil)
        let work = try #require(store.work(on: .thread(11), of: key))
        #expect(work.state == .unknown(copied: false))
        #expect(!work.isActive)
        #expect(work.sentence(name: "Retry backoff", forkOf: nil) == "Sent to ‘Retry backoff’ · see the session")
        #expect(store.readyFixes(of: key, among: [.thread(11)]).isEmpty)
        let restarted = SentPrompt.load(from: settings.defaults, now: now.addingTimeInterval(SentPrompt.followLimit + 60))
        #expect(restarted.first { $0.parts == [.thread(11)] }?.overlapped == true)
        // One still followed, as BriefBar didn't run meanwhile, stays, for its session's log to say what became of it.
        #expect(restarted.first { $0.parts == [.thread(12)] }?.isFollowed == true)
    }

    /// What another prompt does to the ones sent before: any prompt BriefBar sends the session, about threads or not, or
    /// one it copied for you to paste there; not one that ended, one sent elsewhere, or one copied as `/fork <prompt>`,
    /// which goes to a fork. One copied says it was.
    @Test func whatOverlapsAPrompt() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let other = "2f8a4c6e-1b3d-4e5f-8a7b-9c0d1e2f3a15"
        store.keep(about(), sentTo: .fellBack(SessionFallback(reason: "Off", session: session)), from: session, forking: false,
                   at: now.addingTimeInterval(-90))
        store.keep(about(threads: [12]), sentTo: .sent, from: other, forking: false, at: now.addingTimeInterval(-80))
        let ended = try #require(settings.copilotSentPrompts.firstIndex { $0.parts == [.thread(12)] })
        settings.copilotSentPrompts[ended].ended = .finished
        store.keep(about(threads: [13]), sentTo: .sent, from: other, forking: false, at: now.addingTimeInterval(-70))
        // A `/fork` copy, and an ended one, overlap nothing, and aren't.
        store.keep(about(threads: [14]), sentTo: .fellBack(SessionFallback(reason: "Off", pastesFork: true, session: session)),
                   from: session, forking: true, at: now.addingTimeInterval(-60))
        store.keep(nil, sentTo: .sent, from: other, forking: false, at: now.addingTimeInterval(-50))
        let overlapped = Dictionary(uniqueKeysWithValues: settings.copilotSentPrompts.map { ($0.parts, $0.overlapped) })
        let expected: [[PullRequestPart]: Bool] = [[.thread(11)]: false, [.thread(12)]: false, [.thread(13)]: true, [.thread(14)]: false]
        #expect(overlapped == expected)
        #expect(settings.copilotSentPrompts.first { $0.parts == [.thread(12)] }?.ended == .finished)
        store.keep(nil, sentTo: .sent, from: session, forking: false, at: now)
        #expect(settings.copilotSentPrompts.first { $0.parts == [.thread(11)] }?.overlapped == true)
        #expect(settings.copilotSentPrompts.first { $0.parts == [.thread(14)] }?.overlapped == false)
        #expect(settings.copilotSentPrompts.count == 4)
        let copied = try #require(store.work(on: .thread(11), of: key))
        #expect(copied.sentence(name: "Retry backoff", forkOf: nil) == "Copied for ‘Retry backoff’ · see the session")
    }

    /// One copied for you to paste that you didn't paste goes after half an hour.
    @Test func forgetsAPromptYouDidntPaste() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let sent = Date()
        settings.copilotSentPrompts = [try #require(SentPrompt(about(), session: session, sentAt: sent, copied: true))]
        #expect(store.work(on: .thread(11), of: key)?.state == .waiting(copied: true))
        store.followSentPrompts(now: sent.addingTimeInterval(SentPrompt.pasteWait + 1))
        try await settle { !store.isFollowingPrompts }
        #expect(settings.copilotSentPrompts.isEmpty)
        #expect(store.work(on: .thread(11), of: key) == nil)
    }

    /// The latest work on a thread is what it says: a fix sent to the app's session after the task that took it on.
    @Test func theLatestWorkOnAThreadIsWhatItSays() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let earlier = now.addingTimeInterval(-3_600)
        settings.copilotRuns = [run(task, startedAt: earlier, ended: .failed, taken: [TakenPart(.thread(11), since: earlier)])]
        #expect(store.work(on: .thread(11), of: key)?.state == .failed(nil))
        store.keep(about(), sentTo: .sent, from: session, forking: false, at: now)
        #expect(store.work(on: .thread(11), of: key)?.session == session)
        #expect(store.work(on: .thread(11), of: key)?.isTask == false)
    }

    // MARK: Conflicts

    /// Conflicts' work ends as builds' does: once the list reads the pull request merging cleanly, or targeting another
    /// branch than the one the conflicts were with, what tasks and prompts took on of them before then is let go, so a
    /// resolution held in a session doesn't come back as ready to push, nor as where to resolve them, once the pull request
    /// conflicts again; not while Copilot is at it, nor what it took on since.
    @Test func conflictsWorkEndsOnceTheyreGoneOrRetargeted() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        var record = try #require(DemoData.records(now: now).first { $0.id == key })
        record.pullRequest.mergeStatus = "conflicts"
        record.pullRequest.targetBranch = "main"
        let first = now.addingTimeInterval(-3_600)
        let resolved = run(task, .resolveConflicts, startedAt: first, ended: .finished, taken: [TakenPart(.conflicts, since: first, target: "main")])
        let prompt = try #require(SentPrompt(
            SentPrompt.About(pullRequest: key, purpose: .fix, parts: [.conflicts, .thread(11)], target: "main"), session: session,
            sentAt: first, copied: false, ended: .finished
        ))
        #expect(prompt.target == "main")
        #expect(SentPrompt(about(threads: [11]), session: session, sentAt: first, copied: false)?.target == nil)
        settings.copilotRuns = [resolved]
        settings.copilotSentPrompts = [prompt]
        // While it conflicts, the resolution is ready, in the session that holds the merge.
        store.endWorkThatsOver(in: [record], now: now)
        #expect(store.work(on: .conflicts, of: key)?.isReadyFix == true)
        #expect(store.readyFixes(of: key, among: record.partsToFix).contains { $0.parts.contains(.conflicts) })
        // (a) Gone another way: a merge Azure DevOps still works out isn't clean; one that is ends what was taken on before,
        // for good, as they come back.
        record.pullRequest.mergeStatus = "queued"
        store.endWorkThatsOver(in: [record], now: now)
        #expect(settings.copilotRuns.first?.taken?.map(\.part) == [.conflicts])
        record.pullRequest.mergeStatus = "succeeded"
        store.endWorkThatsOver(in: [record], now: now)
        #expect(settings.copilotRuns.first?.taken == nil)
        #expect(settings.copilotSentPrompts.first?.parts == [.thread(11)])
        record.pullRequest.mergeStatus = "conflicts"
        store.endWorkThatsOver(in: [record], now: now.addingTimeInterval(60))
        #expect(store.work(on: .conflicts, of: key) == nil)
        #expect(!store.readyFixes(of: key, among: record.partsToFix).contains { $0.parts.contains(.conflicts) })
        // (b) Retargeted: the resolution merged the branch it had, whether the pull request conflicts now or not.
        settings.copilotRuns = [resolved]
        settings.copilotSentPrompts = [prompt]
        record.pullRequest.targetBranch = "release/x"
        store.endWorkThatsOver(in: [record], now: now)
        #expect(settings.copilotRuns.first?.taken == nil)
        #expect(settings.copilotSentPrompts.first?.parts == [.thread(11)])
        #expect(store.work(on: .conflicts, of: key) == nil)
        // Taken on with the branch it targets now, a resolution stays.
        let again = run(task, .resolveConflicts, startedAt: now, ended: .finished, taken: [TakenPart(.conflicts, since: now, target: "release/x")])
        settings.copilotRuns = [again]
        store.endWorkThatsOver(in: [record], now: now)
        #expect(store.work(on: .conflicts, of: key)?.isReadyFix == true)
        // Not while Copilot is at it, nor what it took on since.
        settings.copilotRuns = [run(task, .resolveConflicts, startedAt: first, taken: [TakenPart(.conflicts, since: first, target: "main")])]
        record.pullRequest.mergeStatus = "succeeded"
        store.endWorkThatsOver(in: [record], now: now)
        #expect(store.work(on: .conflicts, of: key)?.isActive == true)
        settings.copilotRuns = [again]
        store.endWorkThatsOver(in: [record], now: now.addingTimeInterval(-60))
        #expect(settings.copilotRuns.first?.taken?.map(\.part) == [.conflicts])
        // One kept before BriefBar knew the branch it was with ends only once they're gone.
        record.pullRequest.mergeStatus = "conflicts"
        settings.copilotRuns = [run(task, .resolveConflicts, startedAt: first, ended: .finished, taken: [TakenPart(.conflicts, since: first)])]
        store.endWorkThatsOver(in: [record], now: now)
        #expect(settings.copilotRuns.first?.taken?.map(\.part) == [.conflicts])
    }

    /// A task that resolves conflicts keeps the branch they're with, and nothing of the kind for the rest it takes on.
    @Test func aTaskKeepsTheBranchItsConflictsAreWith() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        store.launchForTests = { request, id, now in
            guard case .pullRequest(_, let action) = request.subject else { throw CancellationError() }
            return Self.makeRun(id, action, startedAt: now)
        }
        store.send(.pullRequest(pullRequest, .resolveConflicts), prompt: "Resolve them", options: CopilotModel.standard,
                   repository: URL(fileURLWithPath: "/tmp/payments-api"), parts: [.conflicts, .thread(11)])
        try await settle { !settings.copilotRuns.isEmpty }
        let taken = try #require(settings.copilotRuns.first?.taken)
        #expect(taken.first { $0.part == .conflicts }?.target == "main")
        #expect(taken.first { $0.part == .thread(11) }?.target == nil)
    }

    // MARK: Prompts BriefBar follows

    /// A prompt whose turn isn't seen to end within `followLimit`, as when its session waits overnight for your answer,
    /// isn't followed any more: it says BriefBar doesn't know how it went, rather than going.
    @Test func aPromptFollowedTooLongSaysItsOutcomeIsntKnown() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let sent = Date()
        settings.copilotSentPrompts = [try #require(SentPrompt(about(), session: session, sentAt: sent, copied: false))]
        store.followSentPrompts(now: sent.addingTimeInterval(SentPrompt.followLimit - 60))
        try await settle { !store.isFollowingPrompts }
        #expect(settings.copilotSentPrompts.first?.isFollowed == true)
        store.followSentPrompts(now: sent.addingTimeInterval(SentPrompt.followLimit + 1))
        try await settle { !store.isFollowingPrompts }
        let kept = try #require(settings.copilotSentPrompts.first)
        #expect(kept.lostTrack)
        #expect(!kept.isFollowed)
        let work = try #require(store.work(on: .thread(11), of: key))
        #expect(work.state == .unknown(copied: false))
        #expect(work.sentence(name: "Retry backoff", forkOf: nil) == "Sent to ‘Retry backoff’ · see the session")
        #expect(SentPrompt.load(from: settings.defaults, now: sent.addingTimeInterval(SentPrompt.followLimit + 60)).first?.lostTrack == true)
    }

    // MARK: What's Left

    /// While a task works, What's Left says Copilot's on what it took on alone: not the builds and conflicts a Push & Reply
    /// of comments' fixes doesn't ship. A task that doesn't record what it takes on takes care of what its action does.
    @Test func whatsLeftSaysCopilotsOnWhatItsTaskTookOn() {
        let reference = PullRequestReference(organization: "contoso", project: "Storefront", repository: "payments-api", id: 4102,
                                             sourceBranch: "payments-retry")
        var entry = CopilotTaskEntry(
            id: task, workItem: nil, onPullRequest: reference, action: .pushAndReply, options: CopilotModel.standard, startedAt: now,
            status: RunStatus(phase: .working),
            taken: [TakenPart(.build(31), since: now.addingTimeInterval(-600), ended: .finished), TakenPart(.thread(11), since: now, ships: true)]
        )
        #expect(entry.kindsAtWork == [.comments])
        entry.taken?.append(TakenPart(.build(31), since: now, ships: true))
        #expect(entry.kindsAtWork == [.comments, .builds])
        entry.taken = nil
        #expect(entry.kindsAtWork == [.comments, .builds, .conflicts])
        entry.action = .fixBuild
        #expect(entry.kindsAtWork == [.builds])
        entry.status = RunStatus(phase: .finished)
        #expect(entry.kindsAtWork.isEmpty)
    }

    // MARK: Pushing

    /// A pull request's menus push what the bar at the foot of its details does, one session's fixes at a time, never the
    /// threads another session fixed; with none ready, what its last task changed, replying on no thread.
    @Test func theMenusPushEachSessionsFixes() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        var record = try #require(DemoData.records(now: now).first { $0.id == key })
        let comments = record.details?.threads.first?.comments ?? []
        record.details?.threads.append(ReviewThread(id: 12, comments: comments))
        let first = now.addingTimeInterval(-600)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var fixed = run(task, startedAt: first, ended: .finished, taken: [TakenPart(.thread(11), since: first)])
        fixed.worktree = folder
        settings.copilotRuns = [fixed]
        settings.copilotSentPrompts = [try #require(SentPrompt(about(threads: [12]), session: session, sentAt: first.addingTimeInterval(60), copied: false, ended: .finished))]
        let pushes = store.pushes(of: record)
        #expect(pushes.map(\.session) == [session, task])
        #expect(pushes.map(\.parts) == [[.thread(12)], [.thread(11)]])
        // Each lists, replies on and takes on its own threads alone.
        #expect(PullRequestTasks.parts(.pushAndReply, for: record, shipping: pushes[1].parts) == [.thread(11)])
        #expect(PullRequestTasks.shippedThreads(pushes[1].parts) == [11])
        // With none ready, what the last task changed, which a push ships without a reply.
        settings.copilotSentPrompts = []
        var build = run(task, .fixBuild, startedAt: first, ended: .finished, taken: nil)
        build.worktree = folder
        settings.copilotRuns = [build]
        let last = try #require(store.pushes(of: record).first)
        #expect(last.session == task)
        #expect(last.parts.isEmpty)
        #expect(ReadyFixesBar.pushTitle([last]) == "Push")
        #expect(PullRequestTasks.parts(.pushAndReply, for: record, shipping: last.parts).isEmpty)
        // Not after one that changed nothing; not on a pull request you review.
        var review = run(task, .review, startedAt: first, ended: .finished, taken: nil)
        review.worktree = folder
        settings.copilotRuns = [review]
        #expect(store.pushes(of: record).isEmpty)
        settings.copilotRuns = [fixed]
        record.role = .reviewer
        #expect(store.pushes(of: record).isEmpty)
    }

    /// A push of no thread's fix, as of a build's alone, is called for what it does, wherever it's named.
    @Test func aPushOfNoThreadIsCalledPush() {
        #expect(PullRequestAction.pushAndReply.title(taking: [.build(31)]) == "Push")
        #expect(PullRequestAction.pushAndReply.title(taking: [.conflicts]) == "Push")
        #expect(PullRequestAction.pushAndReply.title(taking: []) == "Push")
        #expect(PullRequestAction.pushAndReply.title(taking: [.thread(11), .build(31)]) == "Push & Reply")
        #expect(PullRequestAction.fixBuild.title(taking: [.build(31)]) == "Fix the Build")
        // One that doesn't record what it takes on replied on the threads Fix Comments lists.
        #expect(PullRequestAction.pushAndReply.title(taken: nil) == "Push & Reply")
        // What it went on with, an earlier task's, isn't what it replies on.
        #expect(PullRequestAction.pushAndReply.title(taken: [
            TakenPart(.thread(11), since: now, ended: .finished), TakenPart(.build(31), since: now, ships: true),
        ]) == "Push")
        let build = ReadyFixes(session: session, forkedFrom: nil, isTask: false, parts: [.build(31)], latest: now)
        let both = ReadyFixes(session: task, forkedFrom: nil, isTask: true, parts: [.thread(11), .build(31)], latest: now)
        #expect(ReadyFixesBar.pushTitle([build]) == "Push")
        #expect(ReadyFixesBar.pushTitle([build, both]) == "Push & Reply")
        let reference = PullRequestReference(organization: "contoso", project: "Storefront", repository: "payments-api", id: 4102,
                                             sourceBranch: "payments-retry")
        // One that takes on nothing, in a session that kept nothing, still says it replies on no thread; what it keeps
        // stays so as what it took on is let go.
        #expect(CopilotRun.taken(goingOnWith: nil, on: reference, taking: [], for: .pushAndReply, at: now) == [])
        #expect(PullRequestAction.pushAndReply.title(taken: []) == "Push")
        #expect(CopilotRun.keeping([], for: .pushAndReply) == [])
        #expect(CopilotRun.taken(goingOnWith: nil, on: reference, taking: [], for: .fixComments, at: now) == nil)
        #expect(CopilotRun.keeping([], for: .fixBuild) == nil)
        var entry = CopilotTaskEntry(
            id: task, workItem: nil, onPullRequest: reference, action: .pushAndReply, options: CopilotModel.standard, startedAt: now,
            status: RunStatus(phase: .working), taken: [TakenPart(.build(31), since: now, ships: true)]
        )
        #expect(entry.onlyPushes)
        #expect(entry.actionTitle == "Push")
        #expect(CopilotTasksStore.startedNotification(entry, subject: "!4102").title == "Copilot is pushing")
        entry.status = RunStatus(phase: .finished)
        #expect(entry.sentence(now: nil) == "Pushed")
        entry.taken?.append(TakenPart(.thread(11), since: now, ships: true))
        #expect(!entry.onlyPushes)
        #expect(entry.sentence(now: nil) == "Pushed and replied")
    }

    // MARK: Forks

    /// A fix in a fork of the pull request's session works on the side: the pull request's session stays the one it was, as
    /// does the one you chose, and the task the window goes on with, unless you choose the fork.
    @Test func aForkDoesntBecomeThePullRequestsSession() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var original = run(task, startedAt: now.addingTimeInterval(-3_600), ended: .finished, taken: nil)
        original.worktree = folder
        var forked = run(fork, startedAt: now.addingTimeInterval(-60), ended: .finished, taken: [TakenPart(.thread(11), since: now)], forkedFrom: task)
        forked.worktree = folder
        settings.copilotRuns = [original, forked]
        #expect(store.lastTask(forPullRequest: key)?.id == task)
        #expect(store.continuable(forPullRequest: key)?.id == task)
        // Its row shows the latest, the fork's.
        #expect(store.latest(forPullRequest: key)?.id == fork)
        // What you chose stays as a fork starts after it; another task takes its place.
        settings.choose(session: session, for: key, at: now.addingTimeInterval(-600))
        settings.forgetChosenSession(for: key, supersededBy: forked)
        #expect(settings.chosenSession(for: key)?.session?.id == session)
        #expect(PullRequestSession.chosen(settings.chosenSession(for: key), after: store.lastTask(forPullRequest: key)) != nil)
        var later = original
        later.startedAt = now
        settings.forgetChosenSession(for: key, supersededBy: later)
        #expect(settings.chosenSession(for: key) == nil)
    }

    // MARK: A line's menu

    /// A line's menu offers what its state allows: Stop while Copilot is at it, Try Again for a fix that failed or stopped,
    /// Clear once it's over or copied for you to paste; and Fix waits while one runs.
    @Test func aLinesMenuOffersWhatItsStateAllows() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        func work(_ state: CopilotWork.State, _ purpose: CopilotWork.Purpose = .fix) -> CopilotWork {
            CopilotWork(part: .thread(11), purpose: purpose, state: state, session: session, isTask: false, since: now)
        }
        #expect(CopilotTasksStore.canTryAgain(work(.failed(nil))))
        #expect(CopilotTasksStore.canTryAgain(work(.stopped)))
        #expect(!CopilotTasksStore.canTryAgain(work(.done(nil))))
        #expect(!CopilotTasksStore.canTryAgain(work(.failed(nil), .pushAndReply)))
        #expect(!CopilotTasksStore.canTryAgain(work(.failed(nil), .explain)))
        #expect(CopilotTasksStore.canClear(work(.done(nil))))
        #expect(CopilotTasksStore.canClear(work(.unknown(copied: false))))
        #expect(CopilotTasksStore.canClear(work(.waiting(copied: true))))
        #expect(!CopilotTasksStore.canClear(work(.working(nil))))
        #expect(!CopilotTasksStore.canClear(work(.waiting(copied: false))))
        // A prompt's turn that runs, or waits for your answer; not one its session hasn't taken up, at something else.
        #expect(store.canStop(work(.working(nil)), of: key))
        #expect(store.canStop(work(.needsYou), of: key))
        #expect(!store.canStop(work(.waiting(copied: false)), of: key))
        #expect(!store.canStop(work(.done(nil)), of: key))
        // A task of BriefBar's while it works.
        settings.copilotRuns = [run(task, startedAt: now, taken: [TakenPart(.thread(11), since: now)])]
        #expect(store.canStop(try #require(store.work(on: .thread(11), of: key)), of: key))
        // Not a line that's over, though a later task works in its session, as Fix the Build going on with the task that
        // fixed 11: Stop would stop that one.
        settings.copilotRuns = [run(task, .fixBuild, startedAt: now, taken: [
            TakenPart(.thread(11), since: now.addingTimeInterval(-600), ended: .finished), TakenPart(.build(31), since: now),
        ])]
        let fixed = try #require(store.work(on: .thread(11), of: key))
        #expect(fixed.state == .done(nil))
        #expect(!store.canStop(fixed, of: key))
        #expect(store.canStop(try #require(store.work(on: .build(31), of: key)), of: key))
        for state: CopilotWork.State in [.failed(nil), .stopped, .waiting(copied: true), .waiting(copied: false), .unknown(copied: false)] {
            #expect(!store.canStop(CopilotWork(part: .thread(11), purpose: .fix, state: state, session: task, isTask: true, since: now), of: key))
        }
        #expect(work(.working(nil)).isFixing)
        #expect(work(.waiting(copied: false), .pushAndReply).isFixing)
        #expect(!work(.waiting(copied: true)).isFixing)
        #expect(!work(.working(nil), .explain).isFixing)
        #expect(!work(.failed(nil)).isFixing)
        // The demo runs nothing to stop.
        let demo = CopilotTasksStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo, notifier: nil)
        #expect(!demo.canStop(work(.working(nil)), of: key))
    }

    /// Clear lets a line go, as Dismiss does an answer: what tasks and prompts took on of it, so nothing older takes its
    /// place; not what Copilot is at. A copied prompt that took on nothing else goes, handing nothing off.
    @Test func clearLetsALineGo() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let first = now.addingTimeInterval(-600)
        settings.copilotRuns = [run(task, startedAt: first, ended: .failed, taken: [TakenPart(.thread(11), since: first), TakenPart(.thread(12), since: first)])]
        let older = try #require(SentPrompt(about(threads: [11]), session: session, sentAt: first.addingTimeInterval(-600), copied: false, ended: .finished))
        let copied = try #require(SentPrompt(about(threads: [11, 13]), session: session, sentAt: now, copied: true))
        settings.copilotSentPrompts = [older, copied]
        store.copiedPrompts[copied.id] = ("Fix 11", CommentHandOff(key: key, waiting: [], account: nil, me: "me", dismissedCutoff: .distantPast))
        #expect(store.work(on: .thread(11), of: key)?.state == .waiting(copied: true))
        store.clear(.thread(11), of: key)
        #expect(store.work(on: .thread(11), of: key) == nil)
        #expect(settings.copilotRuns.first?.taken?.map(\.part) == [.thread(12)])
        #expect(settings.copilotSentPrompts.map(\.parts) == [[], [.thread(13)]])
        #expect(store.copiedPrompts[copied.id] != nil)
        store.clear(.thread(13), of: key)
        #expect(settings.copilotSentPrompts.map(\.parts) == [[]])
        #expect(store.copiedPrompts.isEmpty)
        settings.copilotRuns = [run(task, startedAt: now, taken: [TakenPart(.thread(14), since: now)])]
        store.clear(.thread(14), of: key)
        #expect(settings.copilotRuns.first?.taken?.map(\.part) == [.thread(14)])
        // In the demo, in memory.
        let demo = CopilotTasksStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo, notifier: nil)
        let demoKey = PRKey(DemoData.organization, 4102)
        #expect(demo.work(on: .thread(18), of: demoKey) != nil)
        demo.clear(.thread(18), of: demoKey)
        #expect(demo.work(on: .thread(18), of: demoKey) == nil)
    }

    /// Clear lets go of what a send that couldn't start keeps on its line, and of what one getting ready carries from
    /// before, as the session it goes on with did, which it would launch with; not what it takes on now.
    @Test func clearLetsGoOfWhatASendKeeps() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        store.launchForTests = { _, _, _ in throw CancellationError() }
        store.send(.pullRequest(pullRequest, .fixComments), prompt: "Fix 15", options: CopilotModel.standard,
                   repository: URL(fileURLWithPath: "/tmp/payments-api"), parts: [.thread(15)])
        try await settle {
            if case .failed? = store.work(on: .thread(15), of: key)?.state { return true }
            return false
        }
        store.clear(.thread(15), of: key)
        #expect(store.work(on: .thread(15), of: key) == nil)
        // Going on with a session that fixed 16, for 17.
        let (go, letItGo) = AsyncStream<Void>.makeStream()
        store.launchForTests = { request, id, now in
            for await _ in go { break }
            guard case .pullRequest(_, let action) = request.subject else { throw CancellationError() }
            return Self.makeRun(id, action, startedAt: now)
        }
        let first = now.addingTimeInterval(-600)
        let fixed = run(task, startedAt: first, ended: .finished, taken: [TakenPart(.thread(16), since: first)])
        settings.copilotRuns = [fixed]
        store.send(.pullRequest(pullRequest, .fixComments), prompt: "Fix 17", options: CopilotModel.standard,
                   repository: fixed.repository, continuing: fixed, parts: [.thread(17)])
        #expect(store.work(on: .thread(16), of: key)?.state == .done(nil))
        store.clear(.thread(16), of: key)
        store.clear(.thread(17), of: key)
        #expect(store.work(on: .thread(16), of: key) == nil)
        #expect(store.work(on: .thread(17), of: key)?.state == .working(nil))
        #expect(settings.copilotRuns.first?.taken == nil)
        // It launches without what was let go.
        letItGo.yield()
        try await settle { !store.pending.contains { $0.id == task } }
        #expect(settings.copilotRuns.first?.taken?.map(\.part) == [.thread(17)])
        #expect(store.work(on: .thread(16), of: key) == nil)
    }

    /// Try Again readies its composer with the words the fix went with, and where it went, to send them as it opens; without
    /// them, as once BriefBar restarted, it opens going there, with what you wrote, for you to send. Each Try Again opens it
    /// anew.
    @Test func tryAgainSendsOnlyTheWordsItKnows() {
        let drafts = CopilotDrafts()
        let composer = CopilotComposing(part: .thread(11), ask: .fix)
        drafts.texts[composer] = "Your words"
        drafts.retry(composer, words: "Use the shared helper", to: .session(session))
        #expect(drafts.texts[composer] == "Use the shared helper")
        #expect(drafts.retries[composer]?.destination == .session(session))
        #expect(drafts.retries[composer]?.sends == true)
        drafts.texts[composer] = "Your words"
        drafts.retry(composer, words: nil, to: .session(session))
        #expect(drafts.retries[composer]?.destination == .session(session))
        #expect(drafts.retries[composer]?.sends == false)
        #expect(drafts.texts[composer] == "Your words")
        #expect(CopilotComposerID(ask: .fix, tries: 0) != CopilotComposerID(ask: .fix, tries: 1))
    }

    /// Try Again sends the words a fix went with only for that fix, taken on as they were sent: not for one sent another
    /// way since, such as from the Send to Copilot window, whose words BriefBar doesn't keep.
    @Test func tryAgainSendsTheWordsOfThatFixAlone() {
        let store = store()
        let sent = now.addingTimeInterval(-600)
        store.fixWords[CopilotTasksStore.PartKey(pullRequest: key, part: .thread(11))] = CopilotTasksStore.FixWords(
            text: "Use the shared helper", sent: sent...sent.addingTimeInterval(2)
        )
        func work(takenAt: Date) -> CopilotWork {
            CopilotWork(part: .thread(11), purpose: .fix, state: .failed(nil), session: session, isTask: false, since: takenAt, takenAt: takenAt)
        }
        #expect(store.words(for: work(takenAt: sent.addingTimeInterval(1)), of: key) == "Use the shared helper")
        #expect(store.words(for: work(takenAt: now), of: key) == nil)
        #expect(store.words(for: work(takenAt: sent.addingTimeInterval(-1)), of: key) == nil)
        #expect(store.words(for: work(takenAt: sent.addingTimeInterval(1)), of: PRKey("contoso", 4099)) == nil)
    }

    /// Try Again sends a fix that couldn't start where it was to go: a fork of the session it was to fork, again, rather
    /// than a new session at the pull request's latest commit; one that was to start a new session, to a new one.
    @Test func aFixThatCouldntStartIsTriedAgainWhereItWasToGo() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        store.launchForTests = { _, _, _ in throw CancellationError() }
        let names = CopilotSessionNames(session: nil, copilot: store, links: Links(defaults: MemoryDefaults(), isDemo: false))
        func failed(_ part: PullRequestPart) async throws -> CopilotWork {
            try await settle {
                if case .failed? = store.work(on: part, of: key)?.state { return true }
                return false
            }
            return try #require(store.work(on: part, of: key))
        }
        let original = run(task, startedAt: now.addingTimeInterval(-3_600), ended: .finished, taken: nil)
        settings.copilotRuns = [original]
        store.send(.pullRequest(pullRequest, .fixComments), prompt: "Fix 11", options: CopilotModel.standard,
                   repository: original.repository, forking: original, parts: [.thread(11)])
        #expect(names.retryDestination(of: try await failed(.thread(11))) == .fork(task))
        store.send(.pullRequest(pullRequest, .fixComments), prompt: "Fix 12", options: CopilotModel.standard,
                   repository: original.repository, parts: [.thread(12)])
        #expect(names.retryDestination(of: try await failed(.thread(12))) == .newSession)
        // A fork that's there, but that the line doesn't list now: not a new fork of the session it forked, which wouldn't
        // have what it did.
        let inFork = CopilotWork(part: .thread(13), purpose: .fix, state: .failed(nil), session: fork, forkedFrom: session, isTask: false, since: now)
        #expect(names.retryDestination(of: inFork) == nil)
    }

    /// A Push & Reply that lists no thread, sent to one of the Copilot app's sessions, is kept, so the fixes there say
    /// they're pushed, and Clear leaves it; one copied for you to paste is kept with what was copied before BriefBar follows
    /// it.
    @Test func aPushOfNoThreadIsKeptToCarryTheSessionsFixes() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let fixed = try #require(SentPrompt(about(threads: [11]), session: session, sentAt: now.addingTimeInterval(-600), copied: false, ended: .finished))
        settings.copilotSentPrompts = [fixed]
        let push = try #require(store.keep(SentPrompt.About(pullRequest: key, purpose: .pushAndReply, parts: []), sentTo: .sent, from: session, forking: false))
        #expect(store.work(on: .thread(11), of: key)?.sentence(name: "Retry backoff", forkOf: nil) == "Pushing from ‘Retry backoff’")
        store.clear(.thread(11), of: key)
        #expect(settings.copilotSentPrompts.contains { $0.id == push.id })
        let fallback = SessionFallback(reason: "BriefBar's extension in the session didn't answer.", session: session)
        let copied = try #require(store.keep(about(threads: [13]), sentTo: .fellBack(fallback), from: session, forking: false, copying: "Fix 13"))
        #expect(store.copiedPrompts[copied.id]?.text == "Fix 13")
    }

    /// Waits for the store's work, which runs on the main actor between this test's awaits, for as long as a busy machine
    /// could need (`waitLimit`), failing the test if it doesn't happen.
    private func settle(until done: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while !done() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
