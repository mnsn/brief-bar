import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsUI

/// What each comment thread, build or conflicts say Copilot does about them: the latest work that took them on, a task of
/// BriefBar's, which keeps what it took on with its run, or a prompt sent to one of the Copilot app's sessions, which
/// BriefBar keeps by references only and follows from the session's log.
@MainActor
@Suite(.opensNothing) struct CopilotWorkTests {
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

    /// !4102 as Azure DevOps answers for it alone: merging into `target`, as `status` says.
    private func answer(target: String, status: PullRequest.Status = .active) throws -> PullRequest {
        var pullRequest = try #require(DemoData.snapshot(now: now).records.first { $0.id == key }).pullRequest
        pullRequest.targetBranch = target
        pullRequest.status = status
        return pullRequest
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
        #expect(settings.copilotRuns.first?.taken == [])
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
        #expect(settings.copilotRuns.first?.taken == [])
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
        let kept = DetailsDrafts()
        let key = PRKey(DemoData.organization, 4088)
        kept.keep("Skip weekends", in: first, of: key)
        #expect(kept.words(in: second, of: key).isEmpty)
        let drafts = CopilotDrafts()
        let asking = CopilotAsking(
            ask: .fix, part: .build(31), action: .fixBuild, row: "build-2",
            fix: { _, _, _ in CopilotSending.Fix(prompts: ("", ""), action: .fixBuild, parts: [], handOff: nil) }, question: { _, _ in "" }
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
        #expect(ReadyFixesBar.sentence([], in: place) == "Nothing ready in ‘Retry backoff’")
        #expect(ReadyFixesBar.listed([.build(31), .conflicts]) == "a build's fix and the conflicts' resolution")
    }

    /// A comment's fix sent with Push and Reply on commits all its session changed, so you're told what else goes, as you
    /// check the box and send it: its help says other fixes there go too, and that on a comment it changes nothing for, it
    /// replies why; its composer's note names the fixes ready where it goes, which you haven't pushed, but not what it takes
    /// on itself, and, in a fork the Copilot CLI makes of one of BriefBar's tasks, only the conflicts' resolution, which the
    /// task committed.
    @Test func aFixThatShipsSaysWhatElseItPushesAndWhenItOnlyReplies() {
        for fixAll in [false, true] {
            let help = CommentComposer.shipsHelp(fixAll: fixAll)
            #expect(help.contains("Copilot commits all the session changed, other fixes there you haven't pushed included, pushes the branch"))
            #expect(help.contains("replies why"))
            #expect(help.hasSuffix("BriefBar keeps your choice for the next fix."))
        }
        #expect(CommentComposer.shipsHelp(fixAll: false).contains("When it changes nothing for it, it doesn't push, but replies why, and leaves the thread active."))
        #expect(CommentComposer.shipsHelp(fixAll: true).contains("replies on the threads it fixed, and resolves them, as you"))
        let place = "‘Retry backoff’"
        let ready: [PullRequestPart] = [.thread(11), .thread(12), .build(31), .conflicts]
        #expect(CopilotAsking.alsoPushes(ready, in: place, forkedWithTheCLI: false, taking: [.thread(12)])
            == "It also pushes 1 fix, a build's fix and the conflicts' resolution ready in ‘Retry backoff’, which you haven't pushed, without replying on that comment.")
        #expect(CopilotAsking.alsoPushes(ready, in: place, forkedWithTheCLI: false, taking: [.thread(13)])
            == "It also pushes 2 fixes, a build's fix and the conflicts' resolution ready in ‘Retry backoff’, which you haven't pushed, without replying on those comments.")
        #expect(CopilotAsking.alsoPushes([.build(31)], in: place, forkedWithTheCLI: false, taking: [.thread(12)])
            == "It also pushes a build's fix ready in ‘Retry backoff’, which you haven't pushed.")
        #expect(CopilotAsking.alsoPushes(ready, in: "the ‘Resolve Conflicts’ task", forkedWithTheCLI: true, taking: [.thread(12)])
            == "It also pushes the conflicts' resolution ready in the ‘Resolve Conflicts’ task, which you haven't pushed.")
        #expect(CopilotAsking.alsoPushes([.thread(12)], in: place, forkedWithTheCLI: false, taking: [.thread(12)]) == nil)
        #expect(CopilotAsking.alsoPushes([.thread(11)], in: place, forkedWithTheCLI: true, taking: [.thread(12)]) == nil)
        #expect(CopilotAsking.alsoPushes([], in: place, forkedWithTheCLI: false, taking: []) == nil)
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

    /// A comment's Fix, or Fix All, sent with Push and Reply on is a Push & Reply that fixes what it takes on first
    /// (`TakenPart.fixes`, `SentPrompt.fixes`): its lines say it fixes them, to push and reply, then that it did all three,
    /// once it pushed a commit of its own, as BriefBar kept as it finished (`CopilotWork.pushSeen`). One that failed or
    /// stopped may not have fixed them: Try Again sends it again, rather than Push & Reply. A fix the session made before,
    /// which it pushes along without replying on it, says just that.
    @Test func aFixThatShipsSaysItFixesThenPushesAndReplies() throws {
        func said(_ state: CopilotWork.State, fork: Bool = false, pushSeen: Bool = false) -> String {
            CopilotWork(
                part: .thread(11), purpose: .pushAndReply, state: state, session: session, forkedFrom: fork ? task : nil, isTask: false,
                since: now, fixes: true, pushSeen: pushSeen
            ).sentence(name: "Retry backoff", forkOf: fork ? "Retry backoff" : nil)
        }
        #expect(said(.waiting(copied: false)) == "Sent to ‘Retry backoff’")
        #expect(said(.waiting(copied: true)) == "Copied for ‘Retry backoff’: paste it there")
        #expect(said(.working(nil)) == "Copilot is fixing this in ‘Retry backoff’, to push and reply")
        #expect(said(.working(nil), fork: true) == "Fixing this in a fork of ‘Retry backoff’, to push and reply")
        #expect(said(.done(nil), pushSeen: true) == "Fixed, pushed and replied in ‘Retry backoff’")
        #expect(said(.done(nil), fork: true, pushSeen: true) == "Fixed, pushed and replied in a fork of ‘Retry backoff’")
        #expect(said(.done(nil)) == "Fixed in ‘Retry backoff’, but not pushed")
        #expect(said(.failed(nil)) == "Couldn't fix and push it in ‘Retry backoff’")
        #expect(said(.stopped) == "Stopped in ‘Retry backoff’ before it pushed it")
        let fixing = CopilotWork(part: .thread(11), purpose: .pushAndReply, state: .working(nil), session: session, isTask: false, since: now, fixes: true)
        #expect(fixing.look.symbol == "arrow.triangle.2.circlepath")
        #expect(fixing.isFixing)

        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let first = now.addingTimeInterval(-600)
        let name = PullRequestAction.fixPushAndReplyTitle
        // The task fixed 11, then went on to fix 12 and ship it: 11's fix goes along, without a reply.
        settings.copilotRuns = [run(task, .pushAndReply, startedAt: now, taken: [
            TakenPart(.thread(11), since: first, ended: .finished), TakenPart(.thread(12), since: now, ships: true, fixes: true),
        ])]
        #expect(store.work(on: .thread(12), of: key)?.sentence(name: name, forkOf: nil) == "Copilot is fixing this in the ‘Fix, Push & Reply’ task, to push and reply")
        #expect(store.isFixing(.thread(12), of: key))
        #expect(store.work(on: .thread(11), of: key)?.sentence(name: name, forkOf: nil) == "Pushing from the ‘Fix, Push & Reply’ task")
        // Finished, as one that stopped before it pushed, as its prompt has it when the tests don't pass, also does: unless
        // it pushed a commit of its own, as git in its checkout said as it finished, neither is pushed, and 11's fix is still
        // ready. So too while that isn't known, as for a run kept before BriefBar kept it.
        settings.copilotRuns[0].ended = .finished
        for pushed in [nil, false] as [Bool?] {
            settings.copilotRuns[0].pushed = pushed
            #expect(store.work(on: .thread(12), of: key)?.sentence(name: name, forkOf: nil) == "Fixed in the ‘Fix, Push & Reply’ task, but not pushed")
            #expect(store.work(on: .thread(11), of: key)?.sentence(name: name, forkOf: nil) == "Fixed in the ‘Fix, Push & Reply’ task, not pushed")
            #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).map(\.threads) == [[11]])
            #expect(!CopilotTasksStore.canTryAgain(try #require(store.work(on: .thread(12), of: key))))
        }
        settings.copilotRuns[0].pushed = true
        #expect(store.work(on: .thread(12), of: key)?.sentence(name: name, forkOf: nil) == "Fixed, pushed and replied in the ‘Fix, Push & Reply’ task")
        #expect(store.work(on: .thread(11), of: key)?.sentence(name: name, forkOf: nil) == "Pushed from the ‘Fix, Push & Reply’ task, without a reply")
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).isEmpty)
        settings.copilotRuns[0].pushed = nil
        // One that failed: 12 is to try again, not to push; 11's fix wasn't pushed, so it still is.
        settings.copilotRuns[0].ended = .failed
        let failed = try #require(store.work(on: .thread(12), of: key))
        #expect(failed.sentence(name: name, forkOf: nil) == "Couldn't fix and push it in the ‘Fix, Push & Reply’ task")
        #expect(!failed.waitsToBePushed)
        #expect(CopilotTasksStore.canTryAgain(failed))
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).map(\.threads) == [[11]])
        settings.copilotRuns[0].ended = .stopped
        #expect(CopilotTasksStore.canTryAgain(try #require(store.work(on: .thread(12), of: key))))
        #expect(store.readyFixes(of: key, among: [.thread(12)]).isEmpty)
        // The same sent to one of the Copilot app's sessions, which keeps that it fixes them first, and the branch, and where
        // it was in the session's checkout as it went.
        settings.copilotRuns = []
        var shipping = about(.pushAndReply, threads: [12])
        shipping.fixes = true
        shipping.source = "payments-retry"
        shipping.head = "c1"
        let sent = try #require(SentPrompt(shipping, session: session, sentAt: now, copied: false))
        #expect(sent.fixes == true)
        #expect(sent.source == "payments-retry" && sent.head == "c1")
        #expect(sent.pushed == nil)
        var plainPush = about(.pushAndReply, threads: [12])
        plainPush.source = "payments-retry"
        plainPush.head = "c1"
        #expect(try #require(SentPrompt(plainPush, session: session, sentAt: now, copied: false)).fixes == nil)
        #expect(try #require(SentPrompt(plainPush, session: session, sentAt: now, copied: false)).head == nil)
        #expect(try #require(SentPrompt(plainPush, session: session, sentAt: now, copied: false)).source == nil)
        var asFix = about(threads: [12])
        asFix.fixes = true
        #expect(try #require(SentPrompt(asFix, session: session, sentAt: now, copied: false)).fixes == nil)
        let fixed = try #require(SentPrompt(about(threads: [11]), session: session, sentAt: first, copied: false, ended: .finished))
        settings.copilotSentPrompts = [fixed, sent]
        #expect(store.work(on: .thread(12), of: key)?.sentence(name: "Retry backoff", forkOf: nil) == "Sent to ‘Retry backoff’")
        #expect(store.work(on: .thread(11), of: key)?.sentence(name: "Retry backoff", forkOf: nil) == "Pushing from ‘Retry backoff’")
        var finished = sent
        finished.ended = .finished
        for pushed in [nil, false] as [Bool?] {
            finished.pushed = pushed
            settings.copilotSentPrompts = [fixed, finished]
            #expect(store.work(on: .thread(12), of: key)?.sentence(name: "Retry backoff", forkOf: nil) == "Fixed in ‘Retry backoff’, but not pushed")
            #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).map(\.threads) == [[11]])
        }
        finished.pushed = true
        settings.copilotSentPrompts = [fixed, finished]
        #expect(store.work(on: .thread(12), of: key)?.sentence(name: "Retry backoff", forkOf: nil) == "Fixed, pushed and replied in ‘Retry backoff’")
        #expect(store.work(on: .thread(11), of: key)?.sentence(name: "Retry backoff", forkOf: nil) == "Pushed from ‘Retry backoff’, without a reply")
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).isEmpty)
        var failing = sent
        failing.ended = .failed
        settings.copilotSentPrompts = [fixed, failing]
        #expect(CopilotTasksStore.canTryAgain(try #require(store.work(on: .thread(12), of: key))))
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).map(\.threads) == [[11]])
        // Kept as it was sent, and as it ended, after BriefBar restarts; one kept before it had this didn't fix them, nor knew
        // where the branch was, or whether it pushed.
        let defaults = MemoryDefaults()
        AppSettings(defaults: defaults).copilotSentPrompts = [finished]
        #expect(AppSettings(defaults: defaults, now: now).copilotSentPrompts == [finished])
        var written = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(finished)) as! [String: Any]
        #expect(written["source"] as? String == "payments-retry" && written["head"] as? String == "c1")
        #expect(written["pushed"] as? Bool == true)
        for field in ["fixes", "source", "head", "pushed"] { written[field] = nil }
        let older = try JSONDecoder().decode(SentPrompt.self, from: try JSONSerialization.data(withJSONObject: written))
        #expect(older.fixes == nil)
        #expect(older.source == nil && older.head == nil && older.pushed == nil)
        #expect(CopilotWork.from(older, about: .thread(12), turn: nil).fixes == false)
        #expect(CopilotWork.from(finished, about: .thread(12), turn: nil).fixes)
        #expect(CopilotWork.from(finished, about: .thread(12), turn: nil).pushSeen)
        #expect(!CopilotWork.from(sent, about: .thread(12), turn: nil).pushSeen)
    }

    /// A fix sent with Push and Reply on keeps that it fixes first, with where the pull request's branch was in its checkout
    /// as it started, which the launcher reads for every Push & Reply (`CopilotRun.head`); a plain fix, or a Push & Reply that
    /// fixes nothing first, keeps neither. Once it finished, its task's row says it pushed only once it pushed a commit of its
    /// own (`CopilotRun.pushed`). A prompt keeps what its delivery read (`SentPrompt.head`), not what the list has.
    @Test func aFixThatShipsKeepsWhereTheBranchWasAsItStarted() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        store.launchForTests = { request, id, now in
            guard case .pullRequest(_, let action) = request.subject else { throw CancellationError() }
            var run = Self.makeRun(id, action, startedAt: now)
            if action == .pushAndReply { run.head = "c1" }
            return run
        }
        let repository = URL(fileURLWithPath: "/tmp/payments-api")
        store.send(.pullRequest(pullRequest, .pushAndReply), prompt: "Fix 12, push and reply", options: CopilotModel.standard,
                   repository: repository, parts: [.thread(12)], fixing: true)
        try await settle { settings.copilotRuns.count == 1 }
        let fixing = try #require(settings.copilotRuns.first)
        #expect(fixing.taken?.map(\.fixes) == [true])
        #expect(fixing.fixes == true && fixing.head == "c1" && fixing.pushed == nil)
        store.send(.pullRequest(pullRequest, .pushAndReply), prompt: "Push and reply", options: CopilotModel.standard,
                   repository: repository, parts: [.thread(13)])
        store.send(.pullRequest(pullRequest, .fixComments), prompt: "Fix 14", options: CopilotModel.standard,
                   repository: repository, parts: [.thread(14)])
        try await settle { settings.copilotRuns.count == 3 }
        #expect(settings.copilotRuns.filter { $0.id != fixing.id }.allSatisfy { $0.fixes == nil && $0.head == nil && $0.pushed == nil })
        // Its row, once it finished: pushed once it pushed a commit of its own. As BriefBar keeps the run, where no read of its
        // log is under way, which says a task just started is still working, whatever it kept.
        var finished = try #require(settings.copilotRuns.first { $0.id == fixing.id })
        finished.ended = .finished
        let ended = AppSettings(defaults: MemoryDefaults())
        let rows = self.store(ended)
        func row() -> CopilotTaskEntry? { rows.entries.first { $0.id == fixing.id } }
        for pushed in [nil, false] as [Bool?] {
            finished.pushed = pushed
            ended.copilotRuns = [finished]
            #expect(row()?.pushSeen == false)
            #expect(row()?.sentence(now: nil) == "Fixed, but not pushed")
        }
        finished.pushed = true
        ended.copilotRuns = [finished]
        #expect(row()?.pushSeen == true)
        #expect(row()?.sentence(now: nil) == "Fixed, pushed and replied")

        // A prompt sent to one of the Copilot app's sessions keeps it as its delivery read it.
        var shipping = about(.pushAndReply, threads: [12])
        shipping.fixes = true
        shipping.source = "payments-retry"
        shipping.head = "c3"
        store.keep(shipping, sentTo: .sent, from: session, forking: false, at: now)
        store.keep(about(.pushAndReply, threads: [13]), sentTo: .forkedAndSent(fork: fork), from: session, forking: true, at: now.addingTimeInterval(1))
        store.keep(about(threads: [14]), sentTo: .sent, from: task, forking: false, at: now.addingTimeInterval(2))
        #expect(settings.copilotSentPrompts.map(\.head) == ["c3", nil, nil])
        #expect(settings.copilotSentPrompts.map(\.source) == ["payments-retry", nil, nil])
    }

    /// What a test says in git's place about whether a session's checkout pushed a commit of its own
    /// (`CopilotTasksStore.pushedForTests`), with what it was asked.
    private actor PushAnswers {
        private let answers: [String: Bool]
        private(set) var asked: [String] = []
        /// When each was asked about as of: as its turn ended.
        private(set) var ends: [Date?] = []

        /// - Parameter answers: by the checkout's folder's path; nil, git can't tell, for the rest.
        init(_ answers: [String: Bool]) {
            self.answers = answers
        }

        func answer(_ folder: URL, _ branch: String, _ start: String, _ end: Date?) -> Bool? {
            asked.append("\(folder.path) \(branch) \(start)")
            ends.append(end)
            return answers[folder.path]
        }
    }

    /// Holds what waits on it until it's opened, as git answering late.
    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }

        /// Whether something waits on it now.
        var isWaitedOn: Bool { !waiters.isEmpty }
    }

    /// Waits until git is asked, as a test says in its place, which then waits on `gate`.
    private func waitUntilAsked(_ gate: Gate, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while await !gate.isWaitedOn {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for git to be asked", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A session's log, in a folder of its own: the task taken up, then done, after `sent`, as a turn of it that finished
    /// writes it; and, given `folder`, the folder it works in (`AppSessions.folder(of:home:)`).
    private func finishedLog(of id: String, in home: URL, after sent: Date, working folder: URL? = nil) throws {
        let state = home.appendingPathComponent("session-state/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let stamp = { (seconds: TimeInterval) in sent.addingTimeInterval(seconds).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) }
        let lines = [
            #"{"type":"user.message","data":{"content":"Fix it"},"id":"a","timestamp":"\#(stamp(1))","parentId":null}"#,
            #"{"type":"session.task_complete","data":{"summary":"Done","success":true},"id":"b","timestamp":"\#(stamp(2))","parentId":null}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: state.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        if let folder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("cwd: \(folder.path)\n".utf8).write(to: state.appendingPathComponent("workspace.yaml"))
        }
    }

    /// A task that fixed what it took on first, then was to push and reply, keeps whether it pushed a commit of its own as
    /// it finishes, as git in its checkout says from where the branch was there as it started (`CopilotRun.pushed`): once,
    /// whatever moves the branch since, as after BriefBar restarts, which asks git nothing more. Nothing asks git for a plain
    /// Push & Reply, for one that didn't finish, or for one that doesn't know where the branch was.
    @Test func aTaskThatShipsKeepsWhetherItPushedAsItFinishes() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("BriefBarCopilotHome-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let stopping = "44444444-4444-4444-8444-444444444444", plain = "55555555-5555-4555-8555-555555555555"
        let failing = "66666666-6666-4666-8666-666666666666", unread = "77777777-7777-4777-8777-777777777777"
        for id in [task, stopping, plain, unread] { try finishedLog(of: id, in: home, after: now) }
        func shipping(_ id: String, _ thread: Int, fixes: Bool = true, head: String? = "c1") -> CopilotRun {
            var run = run(id, .pushAndReply, startedAt: now, taken: [TakenPart(.thread(thread), since: now, ships: true, fixes: fixes ? true : nil)])
            run.worktree = URL(fileURLWithPath: "/tmp/copilot-worktrees/payments-api/\(id)", isDirectory: true)
            run.fixes = fixes ? true : nil
            run.head = head
            return run
        }
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotRuns = [
            shipping(task, 12), shipping(stopping, 14), shipping(plain, 15, fixes: false), shipping(failing, 16),
            shipping(unread, 17, head: nil),
        ]
        let answers = PushAnswers(["/tmp/copilot-worktrees/payments-api/\(task)": true, "/tmp/copilot-worktrees/payments-api/\(stopping)": false])
        let store = store(settings)
        store.useEnvironment(["COPILOT_HOME": home.path])
        store.pushedForTests = { await answers.answer($0, $1, $2, $3) }
        store.refresh()
        try await settle { settings.copilotRuns.allSatisfy { $0.ended != nil } }
        #expect(settings.copilotRuns.map(\.ended) == [.finished, .finished, .finished, .failed, .finished])
        #expect(settings.copilotRuns.map(\.pushed) == [true, false, nil, nil, nil])
        #expect(await answers.asked.sorted() == [
            "/tmp/copilot-worktrees/payments-api/\(task) payments-retry c1", "/tmp/copilot-worktrees/payments-api/\(stopping) payments-retry c1",
        ])
        // As things stood as each ended, as its log says.
        #expect(await answers.ends.allSatisfy { $0.map { abs($0.timeIntervalSince(now.addingTimeInterval(2))) < 0.01 } ?? false })
        let name = PullRequestAction.fixPushAndReplyTitle
        #expect(store.work(on: .thread(12), of: key)?.sentence(name: name, forkOf: nil) == "Fixed, pushed and replied in the ‘Fix, Push & Reply’ task")
        #expect(store.work(on: .thread(14), of: key)?.sentence(name: name, forkOf: nil) == "Fixed in the ‘Fix, Push & Reply’ task, but not pushed")
        #expect(store.work(on: .thread(17), of: key)?.sentence(name: name, forkOf: nil) == "Fixed in the ‘Fix, Push & Reply’ task, but not pushed")

        // After BriefBar restarts, it reads how they ended again, but asks git nothing more, however it would answer now:
        // what they kept stays.
        let restarted = self.store(settings)
        restarted.useEnvironment(["COPILOT_HOME": home.path])
        let later = PushAnswers(["/tmp/copilot-worktrees/payments-api/\(task)": false, "/tmp/copilot-worktrees/payments-api/\(stopping)": true])
        restarted.pushedForTests = { await later.answer($0, $1, $2, $3) }
        restarted.refresh()
        try await settle { restarted.statuses.count == 5 }
        #expect(settings.copilotRuns.map(\.pushed) == [true, false, nil, nil, nil])
        #expect(await later.asked.isEmpty)
    }

    /// A task that goes on with a session takes the place of the one that ran there, with its ID: what a refresh read of the
    /// earlier one, while git was asked whether that pushed, isn't the later one's, which goes on, neither ended nor told
    /// how the earlier one did. Another task's end doesn't wait for git about it.
    @Test func goingOnWhileGitIsAskedLeavesTheLaterTaskGoing() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("BriefBarCopilotHome-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let other = "44444444-4444-4444-8444-444444444444"
        for id in [task, other] { try finishedLog(of: id, in: home, after: now) }
        func shipping(_ id: String, _ thread: Int) -> CopilotRun {
            var run = run(id, .pushAndReply, startedAt: now, taken: [TakenPart(.thread(thread), since: now, ships: true, fixes: true)])
            run.worktree = URL(fileURLWithPath: "/tmp/copilot-worktrees/payments-api/\(id)", isDirectory: true)
            run.fixes = true
            run.head = "c1"
            return run
        }
        let later = run(task, .fixComments, startedAt: now.addingTimeInterval(60), taken: [TakenPart(.thread(13), since: now.addingTimeInterval(60))])
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotRuns = [shipping(task, 12), shipping(other, 14)]
        let store = store(settings)
        store.useEnvironment(["COPILOT_HOME": home.path])
        let earlier = "/tmp/copilot-worktrees/payments-api/\(task)"
        // While git is asked about the earlier task, you go on with its session.
        store.pushedForTests = { folder, _, _, _ in
            guard folder.path == earlier else { return false }
            await MainActor.run { settings.copilotRuns = settings.copilotRuns.map { $0.id == later.id ? later : $0 } }
            return true
        }
        store.refresh()
        // Once git has told about both: the other ends, and you went on with the earlier one's session.
        try await settle {
            store.runsBeingTold.isEmpty && settings.copilotRuns.contains { $0.id == other && $0.ended != nil }
                && settings.copilotRuns.contains { $0.id == task && $0.startedAt == later.startedAt }
        }
        #expect(settings.copilotRuns.first { $0.id == other }?.pushed == false)
        #expect(settings.copilotRuns.first { $0.id == task } == later)
        #expect(store.statuses[task] == nil)
    }

    /// Once Send Work to Copilot is turned off while a task's log is read, git isn't asked whether it pushed; what git tells
    /// once it's turned off, or BriefBar stopped, while it was asked, isn't kept, and says nothing. The task stands as it
    /// did, and once the feature's on again, git is asked again.
    @Test func whatGitTellsOnceItsOffIsntKept() async throws {
        enum Off { case whileRead, whileAsked, stoppedWhileAsked }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("BriefBarCopilotHome-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try finishedLog(of: task, in: home, after: now)
        var shipping = run(task, .pushAndReply, startedAt: now, taken: [TakenPart(.thread(12), since: now, ships: true, fixes: true)])
        shipping.worktree = URL(fileURLWithPath: "/tmp/copilot-worktrees/payments-api/\(task)", isDirectory: true)
        shipping.fixes = true
        shipping.head = "c1"
        for off in [Off.whileRead, .whileAsked, .stoppedWhileAsked] {
            let settings = AppSettings(defaults: MemoryDefaults())
            settings.notifications = true
            settings.copilotRuns = [shipping]
            let recent = RecentNotifications(defaults: MemoryDefaults(), isDemo: false)
            let store = store(settings, notifier: Notifier(recent: recent, posts: false))
            store.useEnvironment(["COPILOT_HOME": home.path])
            let answers = PushAnswers([shipping.worktree.path: true])
            let gate = Gate()
            store.pushedForTests = {
                let answer = await answers.answer($0, $1, $2, $3)
                await gate.wait()
                return answer
            }
            store.refresh()
            if off == .whileRead {
                settings.copilotEnabled = false
                await gate.open()
                try await settle { !store.isRefreshing && store.runsBeingTold.isEmpty }
                #expect(await answers.asked.isEmpty)
            } else {
                try await waitUntilAsked(gate)
                if off == .stoppedWhileAsked { store.stop() } else { settings.copilotEnabled = false }
                await gate.open()
                try await settle { store.runsBeingTold.isEmpty }
                #expect(await answers.asked.count == 1)
            }
            #expect(settings.copilotRuns == [shipping])
            #expect(recent.history.entries.isEmpty)
            guard off != .stoppedWhileAsked else { continue }
            settings.copilotEnabled = true
            store.refresh()
            try await settle { settings.copilotRuns.first?.ended != nil }
            #expect(settings.copilotRuns.first?.pushed == true)
            #expect(recent.history.entries.map(\.id) == [CopilotTasksStore.notificationID(task)])
            #expect(await answers.asked.count == (off == .whileRead ? 1 : 2))
        }
    }

    /// A prompt sent to one of the Copilot app's sessions that fixes what it took on first, then was to push and reply,
    /// keeps whether it pushed a commit of its own as its turn finishes, as git in the checkout its session works in says,
    /// from where the branch was there as it went (`SentPrompt.pushed`): once, from the read that ends its turn, not one
    /// that's too early to, and it ends once git has told. Nothing asks git for a plain Push & Reply.
    @Test func aPromptThatShipsKeepsWhetherItPushedAsItsTurnFinishes() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let plain = "55555555-5555-4555-8555-555555555555"
        let checkout = home.appendingPathComponent("payments-api", isDirectory: true)
        let sent = Date()
        try finishedLog(of: session, in: home, after: sent, working: checkout)
        try finishedLog(of: plain, in: home, after: sent, working: checkout)
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        store.appHomeForTests = home
        let answers = PushAnswers([checkout.path: true])
        store.pushedForTests = { await answers.answer($0, $1, $2, $3) }
        var shipping = about(.pushAndReply, threads: [12])
        shipping.fixes = true
        shipping.source = "payments-retry"
        shipping.head = "c1"
        settings.copilotSentPrompts = [
            try #require(SentPrompt(shipping, session: session, sentAt: sent, copied: false)),
            try #require(SentPrompt(about(.pushAndReply, threads: [13]), session: plain, sentAt: sent, copied: false)),
        ]
        func follow(at date: Date) async throws {
            store.followSentPrompts(now: date)
            try await settle { !store.isFollowingPrompts }
        }
        // Over, once: it may be the end of a turn that ran as it was sent, so git isn't asked yet; nor a second time too
        // soon after, which doesn't end it.
        try await follow(at: sent.addingTimeInterval(3))
        try await follow(at: sent.addingTimeInterval(4))
        #expect(settings.copilotSentPrompts.map(\.ended) == [nil, nil])
        #expect(await answers.asked.isEmpty)
        try await follow(at: sent.addingTimeInterval(6))
        try await settle { store.promptsBeingTold.isEmpty && settings.copilotSentPrompts.allSatisfy { $0.ended != nil } }
        #expect(settings.copilotSentPrompts.map(\.ended) == [.finished, .finished])
        #expect(settings.copilotSentPrompts.map(\.pushed) == [true, nil])
        #expect(await answers.asked == ["\(checkout.path) payments-retry c1"])
        // As things stood as its turn ended, as the session's log says.
        #expect(await answers.ends.allSatisfy { $0.map { abs($0.timeIntervalSince(sent.addingTimeInterval(2))) < 0.01 } ?? false })
        #expect(store.work(on: .thread(12), of: key)?.sentence(name: "Retry backoff", forkOf: nil) == "Fixed, pushed and replied in ‘Retry backoff’")
        // Over, it isn't followed, nor asked about, any more.
        try await follow(at: sent.addingTimeInterval(9))
        #expect(await answers.asked.count == 1)
    }

    /// A fix sent with Push and Reply on whose turn was seen to finish has ended, though git hasn't told yet whether it
    /// pushed: a prompt sent its session meanwhile doesn't take it for one whose end wasn't seen (`overlap`), nor is its
    /// session's next turn read as its own. It ends with what git says.
    @Test func aFixWhosePushGitIsAskedAboutHasEnded() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let sent = Date()
        try finishedLog(of: session, in: home, after: sent, working: home.appendingPathComponent("payments-api", isDirectory: true))
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        store.appHomeForTests = home
        let gate = Gate()
        store.pushedForTests = { _, _, _, _ in
            await gate.wait()
            return true
        }
        var shipping = about(.pushAndReply, threads: [12])
        shipping.fixes = true
        shipping.source = "payments-retry"
        shipping.head = "c1"
        settings.copilotSentPrompts = [try #require(SentPrompt(shipping, session: session, sentAt: sent, copied: false))]
        let id = try #require(settings.copilotSentPrompts.first?.id)
        func follow(at seconds: TimeInterval) async throws {
            store.followSentPrompts(now: sent.addingTimeInterval(seconds))
            try await settle { !store.isFollowingPrompts }
        }
        try await follow(at: 3)
        try await follow(at: 6)
        #expect(store.promptsBeingTold == [id])
        // It stands as it did meanwhile, not ready to push.
        #expect(store.work(on: .thread(12), of: key)?.sentence(name: "Retry backoff", forkOf: nil)
            == "Copilot is fixing this in ‘Retry backoff’, to push and reply")
        #expect(store.readyFixes(of: key, among: [.thread(12)]).isEmpty)
        // Meanwhile you send the session a fix of 13, and it takes it up.
        _ = store.keep(about(threads: [13]), sentTo: .sent, from: session, forking: false, at: sent.addingTimeInterval(7))
        let stamp = sent.addingTimeInterval(8).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let log = try FileHandle(forWritingTo: home.appendingPathComponent("session-state/\(session)/events.jsonl"))
        try log.seekToEnd()
        try log.write(contentsOf: Data((#"{"type":"user.message","data":{"content":"Fix 13"},"id":"c","timestamp":"\#(stamp)","parentId":null}"# + "\n").utf8))
        try log.close()
        try await follow(at: 9)
        await gate.open()
        try await settle { store.promptsBeingTold.isEmpty }
        let fix = try #require(settings.copilotSentPrompts.first { $0.id == id })
        #expect(fix.ended == .finished)
        #expect(fix.pushed == true)
        #expect(!fix.overlapped)
        #expect(store.work(on: .thread(12), of: key)?.sentence(name: "Retry backoff", forkOf: nil) == "Fixed, pushed and replied in ‘Retry backoff’")
        #expect(settings.copilotSentPrompts.first { $0.parts == [.thread(13)] }?.isFollowed == true)
    }

    /// Whether a fix sent with Push and Reply on pushed is kept as it finished, so another push since doesn't change it
    /// (the review of #170's M1): one by another session while it fixed, which rejected its push; one of the session's other
    /// fix since, from the session, which takes along what it changed, without replying on it; or anything pushed after a
    /// fork's fix stopped. Neither its line nor the session's other fixes say it pushed, and they stay ready; a later push
    /// from its session that takes its change along says so, without a reply.
    @Test func anotherPushDoesntMakeAFixThatShipsSayItPushed() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let other = "55555555-5555-4555-8555-555555555555"
        func line(_ thread: Int, _ name: String = "Retry backoff", forkOf: String? = nil) -> String? {
            store.work(on: .thread(thread), of: key)?.sentence(name: name, forkOf: forkOf)
        }
        let fixed = try #require(SentPrompt(about(threads: [11]), session: session, sentAt: now.addingTimeInterval(-900), copied: false, ended: .finished))
        let fixed13 = try #require(SentPrompt(about(threads: [13]), session: other, sentAt: now.addingTimeInterval(-800), copied: false, ended: .finished))
        var shipping = about(.pushAndReply, threads: [12])
        shipping.fixes = true
        shipping.source = "payments-retry"
        shipping.head = "c1"
        var stopped = try #require(SentPrompt(shipping, session: session, sentAt: now.addingTimeInterval(-600), copied: false, ended: .finished))
        stopped.pushed = false
        // Another session's push of 13, while 12 was fixed, which rejected 12's push.
        let pushed13 = try #require(SentPrompt(
            about(.pushAndReply, threads: [13]), session: other, sentAt: now.addingTimeInterval(-500), copied: false, ended: .finished
        ))
        settings.copilotSentPrompts = [fixed, fixed13, stopped, pushed13]
        #expect(line(13, "Null check") == "Pushed and replied from ‘Null check’")
        #expect(line(12) == "Fixed in ‘Retry backoff’, but not pushed")
        #expect(line(11) == "Fixed in ‘Retry backoff’, not pushed")
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12), .thread(13)]).map(\.threads) == [[11]])

        // Then 11's Push & Reply from the session: it takes 12's change along, without replying on 12.
        var pushing11 = try #require(SentPrompt(about(.pushAndReply, threads: [11]), session: session, sentAt: now.addingTimeInterval(-120), copied: false))
        settings.copilotSentPrompts = [fixed, fixed13, stopped, pushed13, pushing11]
        #expect(line(12) == "Pushing from ‘Retry backoff’")
        pushing11.ended = .finished
        settings.copilotSentPrompts = [fixed, fixed13, stopped, pushed13, pushing11]
        #expect(line(11) == "Pushed and replied from ‘Retry backoff’")
        #expect(line(12) == "Pushed from ‘Retry backoff’, without a reply")
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12), .thread(13)]).isEmpty)
        // One that failed didn't take it along.
        pushing11.ended = .failed
        settings.copilotSentPrompts = [fixed, fixed13, stopped, pushed13, pushing11]
        #expect(line(12) == "Fixed in ‘Retry backoff’, but not pushed")

        // A fork's fix that stopped, then anything pushed elsewhere: 11 is still ready in the session.
        var forkStopped = try #require(SentPrompt(
            shipping, session: fork, forkedFrom: session, sentAt: now.addingTimeInterval(-600), copied: false, ended: .finished
        ))
        forkStopped.pushed = false
        settings.copilotSentPrompts = [fixed, fixed13, forkStopped, pushed13]
        #expect(line(12, "Retry backoff (fork)", forkOf: "Retry backoff") == "Fixed in a fork of ‘Retry backoff’, but not pushed")
        #expect(line(11) == "Fixed in ‘Retry backoff’, not pushed")
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).map(\.threads) == [[11]])
    }

    /// A fix sent with Push and Reply on whose thread you clear still fixed it first, as its run keeps: the session's other
    /// fixes it pushed along are pushed only once it pushed a commit of its own, rather than as soon as it finished, as a
    /// plain Push & Reply's are; and so once the session goes on.
    @Test func clearingAFixThatShipsKeepsThatItFixedFirst() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let first = now.addingTimeInterval(-600)
        var fixing = run(task, .pushAndReply, startedAt: first, ended: .finished, taken: [
            TakenPart(.thread(11), since: first.addingTimeInterval(-60), ended: .finished),
            TakenPart(.thread(12), since: first, ships: true, fixes: true),
        ])
        fixing.fixes = true
        fixing.head = "c1"
        settings.copilotRuns = [fixing]
        #expect(store.readyFixes(of: key, among: [.thread(11)]).map(\.threads) == [[11]])
        store.clear(.thread(12), of: key)
        #expect(settings.copilotRuns.first?.taken?.map(\.part) == [.thread(11)])
        #expect(store.entries.first?.fixesFirst == true)
        #expect(store.entries.first?.pushSeen == false)
        #expect(store.readyFixes(of: key, among: [.thread(11)]).map(\.threads) == [[11]])
        settings.copilotRuns[0].pushed = true
        #expect(store.entries.first?.pushSeen == true)
        #expect(store.readyFixes(of: key, among: [.thread(11)]).isEmpty)
        let reference = try #require(fixing.onPullRequest)
        #expect(
            CopilotRun.pushes(goingOnWith: settings.copilotRuns.first, on: reference)
                == [SessionPush(since: first, ended: .finished, fixes: true, pushed: true)]
        )
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
        // One that fixed what it took on first keeps so, with whether it pushed a commit of its own: once the session goes on,
        // the fix it made before pushed along only if it did.
        var fixing = run(task, .pushAndReply, startedAt: first, ended: .finished, taken: [
            TakenPart(.thread(11), since: before, ended: .finished), TakenPart(.thread(12), since: first, ships: true, fixes: true),
        ])
        #expect(CopilotRun.pushes(goingOnWith: fixing, on: reference) == [SessionPush(since: first, ended: .finished, fixes: true)])
        let shipping = fixing
        fixing.action = .fixBuild
        fixing.startedAt = now
        fixing.taken = [
            TakenPart(.thread(11), since: before, ended: .finished), TakenPart(.build(31), since: now),
        ]
        let carrying = AppSettings(defaults: MemoryDefaults())
        let carried = store(carrying)
        for pushed in [nil, false, true] as [Bool?] {
            var shipped = shipping
            shipped.pushed = pushed
            let pushes = CopilotRun.pushes(goingOnWith: shipped, on: reference)
            #expect(pushes == [SessionPush(since: first, ended: .finished, fixes: true, pushed: pushed)])
            fixing.pushes = pushes
            carrying.copilotRuns = [fixing]
            if pushed == true {
                #expect(carried.work(on: .thread(11), of: key)?.sentence(name: "Fix the Build", forkOf: nil) == "Pushed from the ‘Fix the Build’ task, without a reply")
                #expect(carried.readyFixes(of: key, among: [.thread(11)]).isEmpty)
            } else {
                #expect(carried.readyFixes(of: key, among: [.thread(11)]).map(\.threads) == [[11]])
            }
        }
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

    /// Push & Reply goes only while the pull request merges into the branch its prompt names, as the window wrote it, which
    /// the launcher checks what the session would push against (`Git.checkPush(in:source:target:)`): once the list has read
    /// another, nothing starts, and the task says why. The launcher asks Azure DevOps, right before git checks and again
    /// right before Copilot starts (`CopilotLauncher.Request.targetNow`), and the list again as each answer comes, since a
    /// read may answer from before a retarget the list has read meanwhile. Whatever else is sent goes whatever the target.
    @Test func pushAndReplyGoesOnlyWhileThePullRequestMergesIntoTheBranchItsPromptNames() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        var launched: [String] = []
        var asks: [(@Sendable () async throws -> String)?] = []
        store.launchForTests = { request, id, now in
            guard case .pullRequest(let pullRequest, let action) = request.subject else { throw CancellationError() }
            launched.append("\(action) \(pullRequest.targetBranch)")
            asks.append(request.targetNow)
            return Self.makeRun(id, action, startedAt: now)
        }
        let current = self.key
        store.currentTarget = { $0 == current ? "release/x" : nil }
        var retargeted = pullRequest
        retargeted.targetBranch = "release/x"
        #expect(store.retargetProblem(pullRequest) == "The pull request merges into release/x now, not the branch this prompt names, so nothing went. Close this window and open it again, for a prompt that names release/x.")
        #expect(store.retargetProblem(retargeted) == nil)
        #expect(store.retargetProblem(nil) == nil)

        // Its prompt names main: nothing starts, and the task says why.
        let repository = URL(fileURLWithPath: "/tmp/payments-api")
        store.send(.pullRequest(pullRequest, .pushAndReply), prompt: "Push and reply", options: CopilotModel.standard, repository: repository)
        try await settle { store.pending.first?.status.phase == .failed }
        #expect(store.pending.first?.status.detail == LaunchError.retargeted("release/x").description)
        #expect(launched.isEmpty)
        // Fixes go whatever the target; a push whose prompt names release/x goes, and so does one that names main once the
        // list reads none.
        store.send(.pullRequest(pullRequest, .fixComments), prompt: "Fix 12", options: CopilotModel.standard, repository: repository, parts: [.thread(12)])
        try await settle { launched.count == 1 }
        store.send(.pullRequest(retargeted, .pushAndReply), prompt: "Push and reply", options: CopilotModel.standard, repository: repository)
        try await settle { launched.count == 2 }
        store.currentTarget = { _ in "" }
        store.send(.pullRequest(pullRequest, .pushAndReply), prompt: "Push and reply", options: CopilotModel.standard, repository: repository)
        try await settle { launched.count == 3 }
        store.currentTarget = { _ in nil }
        store.send(.pullRequest(pullRequest, .pushAndReply), prompt: "Push and reply", options: CopilotModel.standard, repository: repository)
        try await settle { launched.count == 4 }
        #expect(launched == ["fixComments main", "pushAndReply release/x", "pushAndReply main", "pushAndReply main"])
        // Asked, it's what Azure DevOps says then, for the pull request, when that's another branch than the prompt names;
        // or it throws when that can't be read, or names no branch.
        #expect(asks.map { $0 != nil } == [false, true, true, true])
        var asked: [PRKey] = []
        store.readTarget = { key in
            asked.append(key)
            return "release/y"
        }
        #expect(try await asks[1]?() == "release/y")
        #expect(asked == [current])
        store.readTarget = { _ in throw ADOError.offline }
        await #expect(throws: ADOError.offline) { try await asks[1]?() }
        store.readTarget = { _ in "" }
        await #expect(throws: CopilotTasksStore.TargetUnread.self) { try await asks[1]?() }
        // When Azure DevOps names the branch the prompt does, it's the one the list has read by then, if that's another:
        // either one that says another branch keeps Copilot from starting.
        store.readTarget = { _ in "main" }
        store.currentTarget = { $0 == current ? "release/x" : nil }
        #expect(try await asks[3]?() == "release/x")
        store.currentTarget = { $0 == current ? "main" : nil }
        #expect(try await asks[3]?() == "main")
        store.currentTarget = { _ in nil }
        #expect(try await asks[3]?() == "main")
    }

    /// When Azure DevOps says a Push & Reply's pull request merges into another branch than the list has read, the list
    /// reads it again then (`rereadPullRequest`), rather than at its next refresh: so the window, opened again, writes its
    /// prompt for that branch, and it goes. Not while the two agree, nor when Azure DevOps can't be read.
    @Test func aRetargetAzureDevOpsSaysIsReadAgainForTheNextPrompt() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let list = PRStore(settings: settings, summarizer: .withoutModel, mode: .live)
        var snapshot = DemoData.snapshot(now: list.now)
        list.receive(snapshot)
        let store = store(settings)
        // As the source has them: what the list has read, and what Azure DevOps says.
        store.currentTarget = { [weak list] key in list?.record(for: key)?.pullRequest.targetBranch }
        store.readTarget = { _ in "release/x" }
        var reread: [PRKey] = []
        store.rereadPullRequest = { reread.append($0) }

        // The window wrote its prompt as the list has it: for main.
        let listed = try #require(list.record(for: key))
        let written = try #require(await list.copilotPrompts(.pushAndReply, for: listed))
        let first = PullRequestTasks.task(for: written.record)
        #expect(first.targetBranch == "main")
        #expect(await store.freshTargetProblem(first) == CopilotTasksStore.retargetedMessage("release/x"))
        #expect(reread == [key])

        // The list's next read, which that brings forward, has release/x: the window, opened again, names it, and it goes.
        let index = try #require(snapshot.records.firstIndex { $0.id == key })
        snapshot.records[index].pullRequest.targetBranch = "release/x"
        list.receive(snapshot)
        let refreshed = try #require(list.record(for: key))
        let again = try #require(await list.copilotPrompts(.pushAndReply, for: refreshed))
        let next = PullRequestTasks.task(for: again.record)
        #expect(next.targetBranch == "release/x")
        #expect(again.prompts.worktree.contains("This pull request merges into release/x"))
        #expect(again.prompts.session.contains("This pull request merges into release/x"))
        #expect(await store.freshTargetProblem(next) == nil)
        #expect(reread == [key])

        // Moved back to main in Azure DevOps: the list reads that again too.
        store.readTarget = { _ in "main" }
        #expect(await store.freshTargetProblem(next) == CopilotTasksStore.retargetedMessage("main"))
        #expect(reread == [key, key])
        // Not when Azure DevOps can't be read.
        store.readTarget = { _ in throw ADOError.offline }
        #expect(await store.freshTargetProblem(next)
            == "BriefBar couldn't read which branch the pull request merges into, so nothing went: \(ADOError.offline)")
        #expect(reread == [key, key])
    }

    /// The list reads which branch a pull request merges into in a task that stopping calls off, as turning Azure DevOps
    /// off does: what a read under way answers then doesn't count, and once stopped, nothing's read.
    @Test func stoppingCallsOffAReadOfWhichBranchAPullRequestMergesInto() async throws {
        let list = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .live)
        let main = try answer(target: "main")
        let retargeted = try answer(target: "release/x")
        list.readPullRequestNow = { _ in main }
        #expect(try await list.readTarget(of: key) == "main")
        #expect(list.targetReadsUnderWay == 0)

        let (started, startedOne) = AsyncStream<Void>.makeStream()
        let reads = Mutex(0)
        list.readPullRequestNow = { _ in
            reads.withLock { $0 += 1 }
            startedOne.yield()
            // It answers once it's called off, as an answer already on its way would.
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return retargeted
        }
        let reading = Task { try await list.readTarget(of: key) }
        for await _ in started { break }
        #expect(list.targetReadsUnderWay == 1)
        list.stop()
        #expect(list.targetReadsUnderWay == 0)
        await #expect(throws: CopilotTasksStore.TargetUnread.self) { try await reading.value }
        // Stopped, nothing more is read.
        await #expect(throws: CopilotTasksStore.TargetUnread.self) { try await list.readTarget(of: key) }
        #expect(reads.withLock { $0 } == 1)
    }

    /// A push goes only while its pull request is active: completed or abandoned while Copilot fixed what it pushes, which
    /// the list may not have read yet, nothing is pushed to it or replied on it. As Azure DevOps says right before it goes,
    /// the launcher refuses it (`LaunchError.notActive`), as delivery to the Copilot app does; as the list has read it, the
    /// Send to Copilot window doesn't send it, as a comment's composer doesn't.
    @Test func aPushGoesOnlyWhileItsPullRequestIsActive() async throws {
        let list = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .live)
        let completed = try answer(target: "main", status: .completed)
        let abandoned = try answer(target: "main", status: .abandoned)
        let other = try answer(target: "main", status: .other)
        list.readPullRequestNow = { _ in completed }
        await #expect(throws: PullRequestNotActive(status: "completed")) { try await list.readTarget(of: key) }
        list.readPullRequestNow = { _ in abandoned }
        await #expect(throws: PullRequestNotActive(status: "abandoned")) { try await list.readTarget(of: key) }
        list.readPullRequestNow = { _ in other }
        await #expect(throws: PullRequestNotActive(status: "other")) { try await list.readTarget(of: key) }
        #expect(PullRequestNotActive(status: "completed").description == "The pull request was completed")
        #expect(PullRequestNotActive(status: "abandoned").description == "The pull request was abandoned")
        #expect(PullRequestNotActive(status: "other").description == "The pull request isn't active")

        // A Push & Reply's task, or a fix sent with Push and Reply on, asks as it goes, and the launcher refuses it then
        // (`LaunchError.notActive`); so does delivery to one of the Copilot app's sessions.
        let store = store()
        store.readTarget = { _ in throw PullRequestNotActive(status: "completed") }
        #expect(await store.freshTargetProblem(pullRequest) == "The pull request was completed, so nothing went.")
        var asks: [(@Sendable () async throws -> String)?] = []
        store.launchForTests = { request, id, now in
            asks.append(request.targetNow)
            return Self.makeRun(id, .pushAndReply, startedAt: now)
        }
        store.send(
            .pullRequest(pullRequest, .pushAndReply), prompt: "Fix 12, push and reply", options: CopilotModel.standard,
            repository: URL(fileURLWithPath: "/tmp/payments-api"), parts: [.thread(12)], fixing: true
        )
        try await settle { asks.count == 1 }
        await #expect(throws: PullRequestNotActive(status: "completed")) { try await asks[0]?() }
        // Nor once the list read it completed meanwhile, though Azure DevOps answered from before.
        store.readTarget = { _ in "main" }
        #expect(try await asks[0]?() == "main")
        store.pullRequestIsOpen = { _ in false }
        await #expect(throws: PullRequestNotActive.self) { try await asks[0]?() }
        store.pullRequestIsOpen = { _ in true }

        // The window, as the list has read it.
        #expect(store.closedProblem(pullRequest) == nil)
        store.pullRequestIsOpen = { _ in false }
        #expect(store.closedProblem(pullRequest) == CopilotSending.pullRequestGone)
        #expect(store.closedProblem(nil) == nil)
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
        #expect(settings.copilotRuns.first?.taken == [])
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
        #expect(settings.copilotRuns.first?.taken == [])
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

    /// Writes a prompt's report, as the extension that sent it does: by this process, which runs, unless `startedAt` says
    /// the extension started long before it.
    private func writeReport(
        _ requestId: String, in outbox: CopilotOutbox, state: String, since: Date, startedAt: Date? = nil, _ fields: [String: Any] = [:]
    ) throws {
        let folder = outbox.url.appendingPathComponent("reports", isDirectory: true)
        for url in [outbox.url, folder] where !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let iso = { (date: Date) in date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) }
        let started = startedAt ?? DetachedProgram.startTime(of: getpid()) ?? Date()
        let report: [String: Any] = [
            "version": 1, "requestId": requestId, "sessionId": session, "messageId": "message-1", "pid": Int(getpid()),
            "startedAt": iso(started), "name": "Retry backoff", "state": state, "since": iso(since), "updatedAt": iso(Date()),
        ]
        let temporary = folder.appendingPathComponent(".\(requestId).json.\(UUID().uuidString).tmp")
        try JSONSerialization.data(withJSONObject: report.merging(fields) { $1 }).write(to: temporary)
        chmod(temporary.path, 0o600)
        guard rename(temporary.path, folder.appendingPathComponent("\(requestId).json").path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A store that follows a prompt its extension reports, in an outbox of its own, and lists what it notifies.
    private func reportedPrompt(_ about: SentPrompt.About? = nil, settings: AppSettings = AppSettings(defaults: MemoryDefaults()))
        throws -> (store: CopilotTasksStore, outbox: CopilotOutbox, recent: RecentNotifications, requestId: String, home: URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let recent = RecentNotifications(defaults: MemoryDefaults(), isDemo: false)
        let store = store(settings, notifier: Notifier(recent: recent, posts: false))
        let outbox = CopilotOutbox(root: home, path: ["Outbox"])
        store.outboxForTests = outbox
        let requestId = UUID().uuidString.lowercased()
        settings.copilotSentPrompts = [try #require(SentPrompt(about ?? self.about(), session: session, sentAt: Date(), copied: false, report: requestId))]
        return (store, outbox, recent, requestId, home)
    }

    private func follow(_ store: CopilotTasksStore, at date: Date = Date()) async throws {
        store.followSentPrompts(now: date)
        try await settle { !store.isFollowingPrompts }
    }

    /// A prompt whose extension reports its turn is followed from its report, not its session's log: its step; that it
    /// waits on you, which it notifies once, a moment in, and withdraws once it goes on; and how it ended, at once, with
    /// what Copilot said, which it notifies in the same notification's place. Then the report goes.
    @Test func followsAPromptsTurnFromItsReport() async throws {
        let (store, outbox, recent, requestId, home) = try reportedPrompt()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = store.settings
        let sent = try #require(settings.copilotSentPrompts.first?.sentAt)
        try writeReport(requestId, in: outbox, state: "working", since: sent.addingTimeInterval(1), ["step": "Run the tests"])
        try await follow(store)
        #expect(store.work(on: .thread(11), of: key)?.state == .working("Run the tests"))
        #expect(recent.history.entries.isEmpty)

        // Only once it's waited a moment.
        let asked = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        try writeReport(requestId, in: outbox, state: "needsYou", since: asked, ["asks": "question", "said": "Push it now?\nOr wait?"])
        try await follow(store, at: asked.addingTimeInterval(1))
        #expect(store.work(on: .thread(11), of: key)?.state == .needsYou)
        #expect(recent.history.entries.isEmpty)
        try await follow(store, at: asked.addingTimeInterval(CopilotTasksStore.needsYouAfter))
        let asking = try #require(recent.history.entries.first)
        #expect(recent.history.entries.count == 1)
        #expect(asking.id == CopilotTasksStore.promptNotificationID(requestId))
        #expect(asking.title == "‘Retry backoff’ is waiting for your answer")
        #expect(asking.subtitle == "!4102")
        #expect(asking.body == "Push it now?")
        #expect(asking.state == .needsYou)
        #expect(settings.copilotSentPrompts.first?.notifiedNeedsYou == asked)
        // Once each time: not again, even after a restart.
        try await follow(store, at: asked.addingTimeInterval(10))
        #expect(recent.history.entries.first?.date == asking.date)
        #expect(SentPrompt.load(from: settings.defaults).first?.notifiedNeedsYou == asked)

        // Asked something else meanwhile, which you answered first: the first question waits still, as since it was asked,
        // which its report says again, and its notification says it again, in the other's place.
        let again = asked.addingTimeInterval(20)
        try writeReport(requestId, in: outbox, state: "needsYou", since: again, ["asks": "question", "said": "Which branch?"])
        try await follow(store, at: again.addingTimeInterval(CopilotTasksStore.needsYouAfter))
        #expect(recent.history.entries.first?.body == "Which branch?")
        try writeReport(requestId, in: outbox, state: "needsYou", since: asked, ["asks": "question", "said": "Push it now?\nOr wait?"])
        try await follow(store, at: again.addingTimeInterval(5))
        #expect(recent.history.entries.first?.body == "Push it now?")
        #expect(recent.history.entries.count == 1)
        #expect(settings.copilotSentPrompts.first?.notifiedNeedsYou == asked)

        // It went on: what said it waits goes.
        try writeReport(requestId, in: outbox, state: "working", since: sent.addingTimeInterval(1))
        try await follow(store)
        #expect(recent.history.entries.isEmpty)
        #expect(settings.copilotSentPrompts.first?.notifiedNeedsYou == nil)
        #expect(store.work(on: .thread(11), of: key)?.state == .working(nil))

        // Over: at once, with what Copilot said, which it notifies. Then the report goes, and what it said stays only while
        // BriefBar runs.
        try writeReport(requestId, in: outbox, state: "finished", since: Date(), ["said": "Fixed the backoff.\n\nIt isn't pushed."])
        try await follow(store)
        #expect(settings.copilotSentPrompts.first?.ended == .finished)
        #expect(store.work(on: .thread(11), of: key)?.state == .done("Fixed the backoff.\n\nIt isn't pushed."))
        let done = try #require(recent.history.entries.first)
        #expect(recent.history.entries.count == 1)
        #expect(done.title == "Fixed in ‘Retry backoff’, not pushed")
        #expect(done.body == "Fixed the backoff.")
        #expect(done.state == .done)
        try await settle { outbox.report(of: requestId, sentTo: session) == nil }
        #expect(SentPrompt.load(from: settings.defaults).first?.ended == .finished)
    }

    /// Turning Send Work to Copilot off takes back the notification that a reported prompt's turn waits on you, as a task's
    /// working one goes: no report is read while it's off, so nothing would take it back once the turn goes on. Turned back
    /// on, one that still waits says so again.
    @Test func turningSendWorkOffTakesBackThatATurnWaitsOnYou() async throws {
        let (store, outbox, recent, requestId, home) = try reportedPrompt()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = store.settings
        let asked = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 10)
        try writeReport(requestId, in: outbox, state: "needsYou", since: asked, ["asks": "question", "said": "Push it now?"])
        try await follow(store)
        #expect(recent.history.entries.first?.body == "Push it now?")
        store.start()
        defer { store.stop() }

        settings.copilotEnabled = false
        try await settle { recent.history.entries.isEmpty }
        #expect(recent.history.entries.isEmpty)
        #expect(settings.copilotSentPrompts.first?.notifiedNeedsYou == nil)
        #expect(SentPrompt.load(from: settings.defaults).first?.notifiedNeedsYou == nil)

        settings.copilotEnabled = true
        try await follow(store)
        try await settle { !recent.history.entries.isEmpty }
        #expect(recent.history.entries.first?.body == "Push it now?")
        #expect(settings.copilotSentPrompts.first?.notifiedNeedsYou == asked)
    }

    /// A prompt its extension reports goes on being followed while another prompt is sent to its session, and after: its
    /// report is of its own message. One followed from the log isn't.
    @Test func followsAReportedPromptWhileAnotherIsSentToItsSession() async throws {
        let (store, outbox, _, requestId, home) = try reportedPrompt()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = store.settings
        let reported = try #require(settings.copilotSentPrompts.first)
        let fromLog = try #require(SentPrompt(about(threads: [12]), session: session, sentAt: reported.sentAt.addingTimeInterval(-5), copied: false))
        settings.copilotSentPrompts = [fromLog, reported]
        try writeReport(requestId, in: outbox, state: "working", since: Date(), ["step": "Read the diff"])
        store.pauseFollowing(session)
        try await follow(store)
        #expect(store.work(on: .thread(11), of: key)?.state == .working("Read the diff"))
        store.overlap(promptsIn: session, before: Date())
        store.resumeFollowing(session)
        #expect(settings.copilotSentPrompts.first { $0.report == nil }?.overlapped == true)
        #expect(settings.copilotSentPrompts.first { $0.report != nil }?.isFollowed == true)
    }

    /// One whose extension stopped before its report said how its turn ended, or whose report went, BriefBar no longer
    /// follows: it says it doesn't know how it went, takes back what said it waits on you, and removes the report.
    @Test func losesTrackOfAPromptWhoseExtensionStoppedBeforeItsEnd() async throws {
        let (store, outbox, recent, requestId, home) = try reportedPrompt()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = store.settings
        let asked = Date().addingTimeInterval(-10)
        try writeReport(requestId, in: outbox, state: "needsYou", since: asked, ["asks": "plan", "said": "Fix it, then test it."])
        try await follow(store)
        #expect(recent.history.entries.first?.body == "Fix it, then test it.")
        // The process with its ID started after the extension says it did: it's another's.
        try writeReport(requestId, in: outbox, state: "needsYou", since: asked, startedAt: Date().addingTimeInterval(-3 * 86_400))
        try await follow(store)
        let kept = try #require(settings.copilotSentPrompts.first)
        #expect(kept.lostTrack)
        #expect(kept.ended == nil)
        #expect(store.work(on: .thread(11), of: key)?.state == .unknown(copied: false))
        #expect(recent.history.entries.isEmpty)
        try await settle { outbox.report(of: requestId, sentTo: session) == nil }

        // Gone before it said.
        let (gone, _, goneRecent, _, goneHome) = try reportedPrompt()
        defer { try? FileManager.default.removeItem(at: goneHome) }
        try await follow(gone)
        #expect(gone.settings.copilotSentPrompts.first?.lostTrack == true)
        #expect(goneRecent.history.entries.isEmpty)
    }

    /// Once its extension isn't running, a report is read again: the extension may have said how the turn ended as it
    /// stopped, after it was first read.
    @Test func readsAReportAgainOnceItsExtensionStopped() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let outbox = CopilotOutbox(root: home, path: ["Outbox"])
        let requestId = UUID().uuidString.lowercased()
        try writeReport(requestId, in: outbox, state: "working", since: Date())
        let read = CopilotTasksStore.readReport(requestId, sentTo: session, in: outbox) { _ in
            try? writeReport(requestId, in: outbox, state: "finished", since: Date(), ["said": "Done."])
            return false
        }
        #expect(read.report?.state == .finished)
        #expect(read.report?.said == "Done.")
        #expect(!read.follows)
        #expect(CopilotTasksStore.readReport(requestId, sentTo: session, in: outbox) { _ in true }.report?.state == .finished)
        let missing = CopilotTasksStore.readReport(UUID().uuidString.lowercased(), sentTo: session, in: outbox) { _ in true }
        #expect(missing == CopilotTasksStore.Reported(report: nil, follows: false))
    }

    /// How a reported turn ended is notified when it failed, or stopped for a cause of its own, such as the session
    /// closing; not when you stopped it, which takes back what said it waited on you; and nothing while Notifications are
    /// off, though the prompt keeps how it ended.
    @Test func notifiesHowAReportedTurnEndedButForYourStop() async throws {
        for (state, fields, title, body) in [
            ("failed", ["said": "Rate limited.\nTry later."], "Couldn't fix it in ‘Retry backoff’", "Rate limited."),
            ("failed", [:], "Couldn't fix it in ‘Retry backoff’", "It reported an error."),
            ("stopped", ["cause": "closed"], "Stopped in ‘Retry backoff’ before it fixed it", "The session closed before it finished."),
            ("stopped", ["cause": "creditLimit"], "Stopped in ‘Retry backoff’ before it fixed it", "Autopilot reached the most it may spend."),
            ("finished", [:], "Fixed in ‘Retry backoff’, not pushed", "It didn't say what it did."),
        ] as [(String, [String: Any], String, String)] {
            let (store, outbox, recent, requestId, home) = try reportedPrompt()
            defer { try? FileManager.default.removeItem(at: home) }
            try writeReport(requestId, in: outbox, state: state, since: Date(), fields)
            try await follow(store)
            let note = try #require(recent.history.entries.first, "\(state) \(fields)")
            #expect(note.title == title)
            #expect(note.body == body)
            #expect(note.state == (state == "finished" ? .done : .failing))
        }

        let (stopped, outbox, recent, requestId, home) = try reportedPrompt()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeReport(requestId, in: outbox, state: "needsYou", since: Date().addingTimeInterval(-10), ["asks": "permission"])
        try await follow(stopped)
        #expect(recent.history.entries.first?.body == "It asks for your permission.")
        try writeReport(requestId, in: outbox, state: "stopped", since: Date())
        try await follow(stopped)
        #expect(stopped.settings.copilotSentPrompts.first?.ended == .stopped)
        #expect(recent.history.entries.isEmpty)

        let quiet = AppSettings(defaults: MemoryDefaults())
        quiet.notifications = false
        let (off, offOutbox, offRecent, offRequest, offHome) = try reportedPrompt(settings: quiet)
        defer { try? FileManager.default.removeItem(at: offHome) }
        try writeReport(offRequest, in: offOutbox, state: "needsYou", since: Date().addingTimeInterval(-10), ["asks": "question"])
        try await follow(off)
        #expect(offRecent.history.entries.isEmpty)
        try writeReport(offRequest, in: offOutbox, state: "finished", since: Date(), ["said": "Done."])
        try await follow(off)
        #expect(off.settings.copilotSentPrompts.first?.ended == .finished)
        #expect(offRecent.history.entries.isEmpty)
    }

    /// A fix sent to push and reply that its extension says finished ends once git, in the checkout its session works in,
    /// has told whether it pushed a commit of its own, as things stood when its report says the turn ended: until then its
    /// line says it's fixing, and isn't ready to push, nothing is notified, and its report stays; then it keeps what git
    /// told, and its notification says Copilot finished, not whether it pushed, which what Copilot said tells, and its report
    /// goes. Nothing asks git for one that failed, which ends at once. Turned off while git is asked, nothing git told is
    /// kept, nor notified, and the report stays, to be read again once it's on.
    @Test func aReportedFixSentToPushAndReplyEndsOnceGitTells() async throws {
        var ships = SentPrompt.About(pullRequest: key, purpose: .pushAndReply, parts: [.thread(11)], fixes: true)
        ships.source = "payments-retry"
        ships.head = "c1"
        let ended = Date().addingTimeInterval(-5)
        func reported(answering pushed: Bool) throws
            -> (store: CopilotTasksStore, outbox: CopilotOutbox, recent: RecentNotifications, report: URL, home: URL, answers: PushAnswers, gate: Gate) {
            let (store, outbox, recent, requestId, home) = try reportedPrompt(ships)
            let checkout = home.appendingPathComponent("payments-api", isDirectory: true)
            try finishedLog(of: session, in: home, after: ended, working: checkout)
            store.appHomeForTests = home
            let answers = PushAnswers([checkout.path: pushed])
            let gate = Gate()
            store.pushedForTests = { folder, branch, start, end in
                await gate.wait()
                return await answers.answer(folder, branch, start, end)
            }
            return (store, outbox, recent, outbox.url.appendingPathComponent("reports/\(requestId).json"), home, answers, gate)
        }
        func said(_ store: CopilotTasksStore) -> String? {
            store.work(on: .thread(11), of: key)?.sentence(name: "Retry backoff", forkOf: nil)
        }
        for (state, words, title) in [
            ("finished", "Pushed and replied on the thread.", "Copilot finished fixing a comment in ‘Retry backoff’"),
            ("failed", "The tests failed.", "Couldn't fix and push it in ‘Retry backoff’"),
        ] {
            let (store, outbox, recent, report, home, answers, gate) = try reported(answering: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let requestId = report.deletingPathExtension().lastPathComponent
            try writeReport(requestId, in: outbox, state: state, since: ended, ["said": words])
            try await follow(store)
            if state == "finished" {
                #expect(!store.promptsBeingTold.isEmpty)
                #expect(said(store) == "Copilot is fixing this in ‘Retry backoff’, to push and reply")
                #expect(store.readyFixes(of: key, among: [.thread(11)]).isEmpty)
                #expect(recent.history.entries.isEmpty)
                #expect(store.settings.copilotSentPrompts.first?.ended == nil)
                #expect(FileManager.default.fileExists(atPath: report.path))
                await gate.open()
                try await settle { store.promptsBeingTold.isEmpty }
                #expect(await answers.asked == ["\(home.appendingPathComponent("payments-api", isDirectory: true).path) payments-retry c1"])
                let end = try #require(await answers.ends.first ?? nil)
                #expect(abs(end.timeIntervalSince(ended)) < 0.001)
                #expect(store.settings.copilotSentPrompts.first?.pushed == true)
                #expect(said(store) == "Fixed, pushed and replied in ‘Retry backoff’")
            } else {
                #expect(await answers.asked.isEmpty)
                #expect(store.settings.copilotSentPrompts.first?.pushed == nil)
            }
            #expect(store.settings.copilotSentPrompts.first?.ended == (state == "finished" ? .finished : .failed))
            #expect(recent.history.entries.map(\.title) == [title])
            #expect(recent.history.entries.first?.body == words)
            try await settle { !FileManager.default.fileExists(atPath: report.path) }
        }

        let (store, outbox, recent, report, home, answers, gate) = try reported(answering: false)
        defer { try? FileManager.default.removeItem(at: home) }
        try writeReport(report.deletingPathExtension().lastPathComponent, in: outbox, state: "finished", since: ended, ["said": "Done."])
        try await follow(store)
        #expect(!store.promptsBeingTold.isEmpty)
        try await waitUntilAsked(gate)
        store.settings.copilotEnabled = false
        await gate.open()
        try await settle { store.promptsBeingTold.isEmpty }
        #expect(store.settings.copilotSentPrompts.first?.ended == nil)
        #expect(recent.history.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: report.path))
        store.settings.copilotEnabled = true
        try await follow(store)
        try await settle { store.settings.copilotSentPrompts.first?.ended != nil }
        #expect(store.settings.copilotSentPrompts.first?.pushed == false)
        #expect(await answers.asked.count == 2)
        #expect(said(store) == "Fixed in ‘Retry backoff’, but not pushed")
        #expect(recent.history.entries.map(\.title) == ["Copilot finished fixing a comment in ‘Retry backoff’"])
        try await settle { !FileManager.default.fileExists(atPath: report.path) }

        let requestId = UUID().uuidString.lowercased()
        let both = try #require(SentPrompt(
            SentPrompt.About(pullRequest: key, purpose: .pushAndReply, parts: [.thread(11), .thread(12)], fixes: true),
            session: session, sentAt: now, copied: false, report: requestId
        ))
        let done = OutboxReport(requestId: requestId, sessionId: session, pid: 1, startedAt: now, name: "Retry backoff", state: .finished, since: now)
        #expect(CopilotTasksStore.promptNotification(both, requestId: requestId, report: done, pullRequest: nil).title
            == "Copilot finished fixing the comments in ‘Retry backoff’")
    }

    /// What a prompt's notification says, and opens: the line's words, by the name of the session it went to, a fork's own;
    /// the pull request, as BriefBar read it; and a click opens it, at the thread a thread's prompt took on, as the list has
    /// it by then for one posted before the list read it.
    @Test func aPromptsNotificationSaysWhereAndOpensThePullRequest() throws {
        let pullRequest = PullRequest(
            key: key, title: "Add retry with backoff", author: Person(id: "robin", name: "Robin Diaz"), createdAt: now, projectId: "p",
            projectName: "Storefront", repositoryId: "r", repositoryName: "payments-api"
        )
        let requestId = UUID().uuidString.lowercased()
        func report(_ state: OutboxReport.State, name: String? = "Retry backoff (fork)", asks: OutboxReport.Asks? = nil, said: String? = nil) -> OutboxReport {
            OutboxReport(requestId: requestId, sessionId: fork, pid: 1, startedAt: now, name: name, state: state, since: now, asks: asks, said: said)
        }
        let inFork = try #require(SentPrompt(about(threads: [11, 12]), session: fork, forkedFrom: session, sentAt: now, copied: false, report: requestId))
        let done = CopilotTasksStore.promptNotification(inFork, requestId: requestId, report: report(.finished, said: "Capped it."), pullRequest: pullRequest)
        #expect(done.title == "Fixed in ‘Retry backoff (fork)’, not pushed")
        #expect(done.subtitle == "!4102 Add retry with backoff")
        #expect(done.body == "Capped it.")
        #expect(done.thread == "copilot")
        #expect(done.source == .azureDevOps)
        #expect(done.userInfo == ["url": pullRequest.threadURL(11).absoluteString, "pullRequest": key.description])
        #expect(CopilotTasksStore.promptNotification(inFork, requestId: requestId, report: report(.finished, name: nil), pullRequest: nil).title
            == "Fixed in its session, not pushed")

        let build = try #require(SentPrompt(
            SentPrompt.About(pullRequest: key, purpose: .explain, parts: [.build(31)]), session: session, sentAt: now, copied: false, report: requestId
        ))
        let answered = CopilotTasksStore.promptNotification(build, requestId: requestId, report: report(.finished, name: "Retry backoff"), pullRequest: pullRequest)
        #expect(answered.title == "Answered in ‘Retry backoff’")
        #expect(answered.userInfo["url"] == pullRequest.webURL.absoluteString)
        let plan = CopilotTasksStore.promptNotification(
            build, requestId: requestId, report: report(.needsYou, name: "Retry backoff", asks: .plan, said: "Fix the backoff.\nThen test it."), pullRequest: nil
        )
        #expect(plan.title == "‘Retry backoff’ is waiting for your answer")
        #expect(plan.body == "Fix the backoff.")
        #expect(plan.subtitle == "!4102")
        #expect(plan.id == "copilot.prompt.\(requestId)")

        // Posted before the list read the pull request, as when BriefBar had just started: it names the pull request, and the
        // thread, for a click to find them where the list has them then.
        #expect(plan.userInfo == ["pullRequest": key.description])
        let early = CopilotTasksStore.promptNotification(inFork, requestId: requestId, report: report(.finished), pullRequest: nil)
        #expect(early.userInfo == ["pullRequest": key.description, "thread": "11"])
        let store = store()
        #expect(store.promptLink(early.userInfo) == nil)
        store.knownPullRequest = { $0 == key.linkRef ? pullRequest : nil }
        #expect(store.promptLink(early.userInfo) == pullRequest.threadURL(11))
        #expect(store.promptLink(plan.userInfo) == pullRequest.webURL)
        // One that says where it opens, as other notifications do, opens there.
        #expect(store.promptLink(done.userInfo) == nil)
    }

    /// A prompt keeps its report's request, and when BriefBar last said its turn waits on you, checked as it loads: one whose
    /// report isn't a request's ID isn't kept.
    @Test func keepsAPromptsReportByItsRequest() throws {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        let requestId = UUID().uuidString.lowercased()
        var prompt = try #require(SentPrompt(about(), session: session, sentAt: now, copied: false, report: requestId))
        prompt.notifiedNeedsYou = Date(timeIntervalSince1970: 1_794_294_000)
        settings.copilotSentPrompts = [prompt]
        #expect(SentPrompt.load(from: defaults, now: now) == [prompt])
        #expect(SentPrompt(about(), session: session, sentAt: now, copied: false, report: "../\(requestId)") == nil)
        var data = try JSONEncoder().encode([prompt])
        data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: requestId, with: "../elsewhere").utf8)
        defaults.set(data, forKey: SettingsKey.copilotSentPrompts)
        #expect(SentPrompt.load(from: defaults, now: now).isEmpty)
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

    /// The menus don't push what a task did once it was let go, as a resolution of conflicts the pull request was
    /// retargeted from, which would push the merge of the old target branch: a task from before BriefBar recorded what it
    /// took on is still offered, and so is one that took on nothing itself, going on with a session whose earlier task did.
    @Test func theMenusDontPushWorkThatsOver() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        var record = try #require(DemoData.records(now: now).first { $0.id == key })
        // Not conflicting any more, and not yet read as merging cleanly either.
        record.pullRequest.mergeStatus = "queued"
        let first = now.addingTimeInterval(-600)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var resolved = run(task, .resolveConflicts, startedAt: first, ended: .finished, taken: [
            TakenPart(.conflicts, since: first, target: record.pullRequest.targetBranch),
        ])
        resolved.worktree = folder
        settings.copilotRuns = [resolved]
        #expect(store.pushes(of: record).map(\.session) == [task])
        // Retargeted: the resolution is over, and nothing of it is pushed.
        record.pullRequest.targetBranch = "release/2.0"
        store.endWorkThatsOver(in: [record], now: now)
        #expect(settings.copilotRuns.first?.taken == [])
        #expect(settings.copilotRuns.first?.workLetGo == true)
        #expect(store.pushes(of: record).isEmpty)
        // Nor once you cleared what it fixed.
        var fixed = run(task, startedAt: first, ended: .finished, taken: [TakenPart(.thread(11), since: first)])
        fixed.worktree = folder
        settings.copilotRuns = [fixed]
        store.clear(.thread(11), of: key)
        #expect(settings.copilotRuns.first?.workLetGo == true)
        #expect(store.pushes(of: record).isEmpty)
        // One kept before BriefBar recorded what tasks take on still is.
        fixed.taken = nil
        settings.copilotRuns = [fixed]
        #expect(store.pushes(of: record).map(\.session) == [task])
        // So is one that took on nothing itself, going on with a session whose earlier task fixed a thread that's resolved
        // since: it keeps only what that one took on, which it didn't let go of.
        var later = run(task, .fixComments, startedAt: now.addingTimeInterval(-60), ended: .finished, taken: [
            TakenPart(.thread(999), since: first, ended: .finished),
        ])
        later.worktree = folder
        settings.copilotRuns = [later]
        #expect(store.pushes(of: record).map(\.session) == [task])
        // Letting go of what the earlier task took on, as you clear it, doesn't say this one's work was let go.
        store.clear(.thread(999), of: key)
        #expect(settings.copilotRuns.first?.taken == [])
        #expect(settings.copilotRuns.first?.workLetGo == nil)
        #expect(store.pushes(of: record).map(\.session) == [task])
    }

    /// A push of no thread's fix, as of a build's alone, is called for what it does, wherever it's named.
    @Test func aPushOfNoThreadIsCalledPush() throws {
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
        // One that fixes them first, as a comment's Fix sent with Push and Reply on, is named for that; not one that ships
        // what an earlier one in its session fixed so.
        entry.taken = [TakenPart(.thread(11), since: now, ships: true, fixes: true)]
        #expect(entry.fixesFirst)
        #expect(!entry.onlyPushes)
        #expect(entry.actionTitle == "Fix, Push & Reply")
        // Finished: pushed only once it pushed a commit of its own, as its run keeps (`pushSeen`).
        #expect(entry.sentence(now: nil) == "Fixed, but not pushed")
        entry.pushSeen = true
        #expect(entry.sentence(now: nil) == "Fixed, pushed and replied")
        entry.pushSeen = false
        #expect(CopilotTasksStore.startedNotification(entry, subject: "!4102").title == "Copilot is fixing a comment")
        // Its notification doesn't say whether it pushed: what Copilot said tells.
        let stopped = RunStatus(phase: .finished, detail: "The tests still fail, so I didn't commit, push or reply.\nMore.")
        let ended = try #require(CopilotTasksStore.endedNotification(entry, status: stopped, subject: "!4102"))
        #expect(ended.title == "Copilot finished fixing a comment")
        #expect(ended.body == "The tests still fail, so I didn't commit, push or reply.")
        entry.taken?.append(TakenPart(.thread(12), since: now, ships: true, fixes: true))
        #expect(CopilotTasksStore.endedNotification(entry, status: RunStatus(phase: .finished), subject: "!4102")?.title == "Copilot finished fixing the comments")
        #expect(CopilotTasksStore.endedNotification(entry, status: RunStatus(phase: .working), subject: "!4102") == nil)
        entry.taken = [TakenPart(.thread(11), since: now, ships: true)]
        #expect(CopilotTasksStore.endedNotification(entry, status: RunStatus(phase: .finished), subject: "!4102")?.title == "Copilot pushed and replied")
        entry.taken = [TakenPart(.thread(11), since: now, ended: .finished, ships: true, fixes: true), TakenPart(.build(31), since: now, ships: true)]
        #expect(!entry.fixesFirst)
        #expect(entry.actionTitle == "Push")
        #expect(PullRequestAction.pushAndReply.title(taking: [.thread(11)], fixing: true) == "Fix, Push & Reply")
        #expect(PullRequestAction.fixComments.title(taking: [.thread(11)], fixing: true) == "Fix Comments")
    }

    // MARK: Forks

    /// A fix sent with Push and Reply on to a fork of a session pushes what the fork has of the session's fixes: the Copilot
    /// app's fork has all the session changed, its changes that aren't committed too; a fork the Copilot CLI makes of one of
    /// BriefBar's tasks starts at the commit the task's checkout has, with the conflicts' resolution, which Resolve Conflicts
    /// commits, and no fix of a thread or a build, which nothing commits. Once it pushed a commit of its own, they're pushed,
    /// without a reply, and not ready any more; while it's under way, they're being pushed. A fork made before a fix was
    /// done, or of another session, doesn't have it.
    @Test func aFixThatShipsFromAForkPushesWhatTheForkHasOfTheSessionsFixes() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let first = now.addingTimeInterval(-600)
        let fixed = try #require(SentPrompt(about(threads: [11]), session: session, sentAt: first, copied: false, ended: .finished))
        var shipping = about(.pushAndReply, threads: [12])
        shipping.fixes = true
        shipping.source = "payments-retry"
        shipping.head = "c1"
        /// A prompt that pushed a commit of its own, as git in its checkout said as its turn finished.
        func pushed(_ prompt: SentPrompt) -> SentPrompt {
            var prompt = prompt
            prompt.pushed = true
            return prompt
        }
        let shipped = try #require(SentPrompt(shipping, session: fork, forkedFrom: session, sentAt: now, copied: false, ended: .finished))
        settings.copilotSentPrompts = [fixed, shipped]
        func said(_ part: PullRequestPart, _ name: String = "Retry backoff (fork)", forkOf: String = "Retry backoff") -> String? {
            store.work(on: part, of: key)?.sentence(name: name, forkOf: forkOf)
        }
        // Done, but it didn't push: 11's fix is still ready, and 12's isn't to push again.
        #expect(said(.thread(12)) == "Fixed in a fork of ‘Retry backoff’, but not pushed")
        #expect(said(.thread(11), "Retry backoff", forkOf: "") == "Fixed in ‘Retry backoff’, not pushed")
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).map(\.threads) == [[11]])
        settings.copilotSentPrompts = [fixed, pushed(shipped)]
        #expect(said(.thread(12)) == "Fixed, pushed and replied in a fork of ‘Retry backoff’")
        #expect(said(.thread(11)) == "Pushed from a fork of ‘Retry backoff’, without a reply")
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).isEmpty)
        // Under way.
        var working = shipped
        working.ended = nil
        settings.copilotSentPrompts = [fixed, working]
        #expect(said(.thread(11)) == "Pushing from a fork of ‘Retry backoff’")
        // A fork made before 11 was fixed, or of another session, doesn't have it.
        let early = pushed(try #require(SentPrompt(
            shipping, session: fork, forkedFrom: session, sentAt: first.addingTimeInterval(-60), copied: false, ended: .finished
        )))
        let otherFork = pushed(try #require(SentPrompt(shipping, session: fork, forkedFrom: task, sentAt: now, copied: false, ended: .finished)))
        for push in [early, otherFork] {
            settings.copilotSentPrompts = [fixed, push]
            #expect(store.readyFixes(of: key, among: [.thread(11)]).map(\.threads) == [[11]])
        }
        // A fork a plain fix made, which a fix sent to push and reply went on with since, has 11's fix too, unless it was
        // made before 11 was fixed.
        let wentOn = pushed(try #require(SentPrompt(shipping, session: fork, sentAt: now, copied: false, ended: .finished)))
        let madeIt = try #require(SentPrompt(
            about(threads: [13]), session: fork, forkedFrom: session, sentAt: first.addingTimeInterval(60), copied: false, ended: .finished
        ))
        settings.copilotSentPrompts = [fixed, madeIt, wentOn]
        #expect(store.readyFixes(of: key, among: [.thread(11)]).isEmpty)
        let madeEarly = try #require(SentPrompt(
            about(threads: [13]), session: fork, forkedFrom: session, sentAt: first.addingTimeInterval(-60), copied: false, ended: .finished
        ))
        settings.copilotSentPrompts = [fixed, madeEarly, wentOn]
        #expect(store.readyFixes(of: key, among: [.thread(11)]).map(\.threads) == [[11]])
        // So does a task that goes on with that fork with the CLI.
        var withTheCLI = run(fork, .pushAndReply, startedAt: now, ended: .finished, taken: [
            TakenPart(.thread(12), since: now, ships: true, fixes: true),
        ])
        withTheCLI.isAppSession = true
        withTheCLI.pushed = true
        settings.copilotSentPrompts = [fixed, madeIt]
        settings.copilotRuns = [withTheCLI]
        #expect(store.readyFixes(of: key, among: [.thread(11)]).isEmpty)
        settings.copilotSentPrompts = [fixed, madeEarly]
        #expect(store.readyFixes(of: key, among: [.thread(11)]).map(\.threads) == [[11]])
        settings.copilotRuns = []

        // One of BriefBar's tasks fixed 11, then resolved the conflicts, which it committed; a fork of it with the CLI
        // fixed 12 and pushed: the conflicts' resolution went along, but not 11's fix, which wasn't committed.
        settings.copilotSentPrompts = []
        let taskFork = "44444444-4444-4444-8444-444444444444"
        let resolved = run(task, .resolveConflicts, startedAt: first, ended: .finished, taken: [
            TakenPart(.thread(11), since: first.addingTimeInterval(-60), ended: .finished), TakenPart(.conflicts, since: first, target: "main"),
        ])
        var forked = run(taskFork, .pushAndReply, startedAt: now, ended: .finished, taken: [
            TakenPart(.thread(12), since: now, ships: true, fixes: true),
        ], forkedFrom: task)
        settings.copilotRuns = [resolved, forked]
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12), .conflicts]).map(\.parts) == [[.thread(11), .conflicts]])
        forked.pushed = true
        settings.copilotRuns = [resolved, forked]
        #expect(said(.conflicts, "Resolve Conflicts (fork)", forkOf: "Resolve Conflicts") == "Pushed from a fork of the ‘Resolve Conflicts’ task")
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12), .conflicts]).map(\.parts) == [[.thread(11)]])
        // Forked before it resolved them: the fork doesn't have the resolution.
        forked.startedAt = first.addingTimeInterval(-30)
        forked.taken = [TakenPart(.thread(12), since: forked.startedAt, ships: true, fixes: true)]
        settings.copilotRuns = [resolved, forked]
        #expect(store.readyFixes(of: key, among: [.thread(11), .conflicts]).map(\.parts) == [[.thread(11), .conflicts]])
        // Forked before it resolved them, as the fork's first task took 9 on, and pushing from there since: still not.
        forked.startedAt = now
        forked.taken = [
            TakenPart(.thread(9), since: first.addingTimeInterval(-30), ended: .finished),
            TakenPart(.thread(12), since: now, ships: true, fixes: true),
        ]
        settings.copilotRuns = [resolved, forked]
        #expect(store.readyFixes(of: key, among: [.thread(11), .conflicts]).map(\.parts) == [[.thread(11), .conflicts]])
        // Nor once what its first task took on is let go, or taken on again: it keeps when it was made.
        forked.forkedAt = first.addingTimeInterval(-30)
        forked.taken = [TakenPart(.thread(12), since: now, ships: true, fixes: true)]
        settings.copilotRuns = [resolved, forked]
        #expect(store.readyFixes(of: key, among: [.thread(11), .conflicts]).map(\.parts) == [[.thread(11), .conflicts]])
        // Forked while it resolved them, which the task that went on with the session since keeps as done: that was over
        // only by when the next task started, after the fork was made.
        var goneOn = resolved
        goneOn.action = .fixComments
        goneOn.startedAt = now.addingTimeInterval(-100)
        let reference = try #require(resolved.onPullRequest)
        goneOn.taken = CopilotRun.taken(goingOnWith: resolved, on: reference, taking: [.thread(13)], for: .fixComments, at: goneOn.startedAt)
        #expect(goneOn.taken?.first { $0.part == .conflicts }?.overBy == goneOn.startedAt)
        forked.forkedAt = first.addingTimeInterval(60)
        settings.copilotRuns = [goneOn, forked]
        #expect(store.readyFixes(of: key, among: [.thread(11), .conflicts]).map(\.parts) == [[.thread(11), .conflicts]])
        // Forked once the next task there started, it has it, however often the session goes on since.
        forked.forkedAt = now.addingTimeInterval(-50)
        settings.copilotRuns = [goneOn, forked]
        #expect(store.readyFixes(of: key, among: [.thread(11), .conflicts]).map(\.parts) == [[.thread(11)]])
        var again = goneOn
        again.startedAt = now.addingTimeInterval(30)
        again.taken = CopilotRun.taken(goingOnWith: goneOn, on: reference, taking: [.thread(14)], for: .fixComments, at: again.startedAt)
        settings.copilotRuns = [again, forked]
        #expect(store.readyFixes(of: key, among: [.thread(11), .conflicts]).map(\.parts) == [[.thread(11)]])
    }
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
        store.copiedPrompts[copied.id] = (
            "Fix 11", CommentHandOff(key: key, waiting: [], account: nil, me: "me", dismissedCutoff: .distantPast, read: [:], unanswered: [:])
        )
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
        #expect(settings.copilotRuns.first?.taken == [])
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
        let answer = CopilotAnswer(question: nil, answer: "Cap it at 30 seconds.")
        drafts.retry(composer, words: CopilotTasksStore.FixWords(text: "Use the shared helper", takenAt: now, answer: answer), to: .session(session))
        #expect(drafts.retries[composer]?.words?.text == "Use the shared helper")
        #expect(drafts.retries[composer]?.words?.answer == answer)
        #expect(drafts.retries[composer]?.destination == .session(session))
        drafts.retry(composer, words: nil, to: .session(session))
        #expect(drafts.retries[composer]?.destination == .session(session))
        #expect(drafts.retries[composer]?.words == nil)
        #expect(CopilotComposerID(ask: .fix, tries: 0) != CopilotComposerID(ask: .fix, tries: 1))
    }

    /// Taking what Try Again asked of a composer, as it opens anew, calls off what the composer it replaces was sending,
    /// as closing it would, whether or not the new one sends at once; and it's taken once.
    @Test func takingARetryCallsOffWhatItsComposerWasSending() async {
        let drafts = CopilotDrafts()
        let composer = CopilotComposing(part: .thread(11), ask: .fix)
        let other = CopilotComposing(part: .thread(12), ask: .fix)
        let sending = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        let elsewhere = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        defer { elsewhere.cancel() }
        drafts.sends[composer] = sending
        drafts.sends[other] = elsewhere
        #expect(drafts.takeRetry(for: composer) == nil)
        #expect(drafts.sends[composer] != nil)
        drafts.retry(composer, words: nil, to: .session(session))
        let retry = drafts.takeRetry(for: composer)
        #expect(retry?.destination == .session(session))
        #expect(drafts.sends[composer] == nil)
        #expect(sending.isCancelled)
        #expect(drafts.sends[other] != nil)
        #expect(!elsewhere.isCancelled)
        #expect(drafts.takeRetry(for: composer) == nil)
    }

    /// Fix, or Resolve, waits while a fix of it runs, or a push of its fix, though a question about it sent since to another
    /// session is what its line says.
    @Test func aQuestionSentSinceDoesntBringFixBack() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let other = "2f8a4c6e-1b3d-4e5f-8a7b-9c0d1e2f3a15"
        settings.copilotRuns = [run(task, startedAt: now.addingTimeInterval(-600), taken: [TakenPart(.thread(11), since: now.addingTimeInterval(-600))])]
        #expect(store.isFixing(.thread(11), of: key))
        settings.copilotSentPrompts = [try #require(SentPrompt(about(.explain, threads: [11]), session: other, sentAt: now, copied: false))]
        let shown = try #require(store.work(on: .thread(11), of: key))
        #expect(shown.purpose == .explain)
        #expect(!shown.isFixing)
        #expect(store.isFixing(.thread(11), of: key))
        // Once the fix is over, it's offered again.
        settings.copilotRuns[0].ended = .finished
        #expect(!store.isFixing(.thread(11), of: key))
        // And while a push of its fix runs in its session.
        settings.copilotRuns = [run(task, .pushAndReply, startedAt: now.addingTimeInterval(-60), taken: [
            TakenPart(.thread(11), since: now.addingTimeInterval(-60), ships: true),
        ])]
        #expect(store.isFixing(.thread(11), of: key))
        #expect(!store.isFixing(.thread(12), of: key))
    }

    /// What a composer that Try Again opened does as it opens (`CopilotDrafts.plan`): it sends at once only a moment after
    /// Try Again, as the fix went, quoting the same answer, or none, as Include the Answer Above was; else the words still
    /// come back, going where the fix went, and it says why it waits for you; and nothing of it comes back once BriefBar
    /// forgot the words.
    @Test func tryAgainsComposerSendsOnlyAsTheFixWent() {
        let at = now
        let answer = CopilotAnswer(question: nil, answer: "Cap it at 30 seconds.")
        let words = CopilotTasksStore.FixWords(text: "Use the shared helper", takenAt: at.addingTimeInterval(-600), answer: answer)
        let retry = CopilotDrafts.Retry(at: at, destination: .session(session), words: words)
        var restored: [CopilotTasksStore.FixWords] = []
        func plan(
            _ retry: CopilotDrafts.Retry, kept: CopilotTasksStore.FixWords?, shown: CopilotAnswer? = nil, after: TimeInterval = 1,
            available: Bool = true, restore: String? = nil
        ) -> CopilotDrafts.RetryPlan? {
            CopilotDrafts.plan(
                retry, kept: kept, answer: shown, now: at.addingTimeInterval(after), isAvailable: { _ in available },
                restore: { restored.append($0); return restore }
            )
        }
        // A moment after Try Again, as the fix went: it goes where that went, with its words and the answer it quoted.
        let sent = plan(retry, kept: words, shown: answer)
        #expect(sent == CopilotDrafts.RetryPlan(words: words, destination: .session(session), problem: nil, sends: true))
        #expect(sent?.text == "Use the shared helper")
        #expect(sent?.includesAnswer == true)
        #expect(restored == [words])
        // A while after: the words come back all the same, going there, but it waits for you, saying why.
        #expect(plan(retry, kept: words, shown: answer, after: CopilotDrafts.retryWait + 1) == CopilotDrafts.RetryPlan(
            words: words, destination: .session(session), problem: CopilotDrafts.retryLate, sends: false
        ))
        // The answer it quoted doesn't show now, or another one does: it waits.
        #expect(plan(retry, kept: words)?.problem == CopilotDrafts.retryAnswerGone)
        #expect(plan(retry, kept: words, shown: CopilotAnswer(question: nil, answer: "Leave it."))?.sends == false)
        // One that quoted no answer goes without the one that shows now.
        let plain = CopilotTasksStore.FixWords(text: "Use the shared helper", takenAt: at.addingTimeInterval(-600))
        let unanswered = plan(CopilotDrafts.Retry(at: at, destination: .session(session), words: plain), kept: plain, shown: answer)
        #expect(unanswered?.sends == true)
        #expect(unanswered?.includesAnswer == false)
        // What else it chose isn't there to put back, as a suggestion that isn't the thread's latest now: it waits, saying so.
        #expect(plan(retry, kept: words, shown: answer, restore: "Not that suggestion") == CopilotDrafts.RetryPlan(
            words: words, destination: .session(session), problem: "Not that suggestion", sends: false
        ))
        // Where it went isn't there: it says so, with its words, and goes nowhere else on its own.
        #expect(plan(retry, kept: words, shown: answer, available: false) == CopilotDrafts.RetryPlan(
            words: words, destination: nil, problem: CopilotDrafts.retryGone, sends: false
        ))
        // Forgotten since, as Send Work to Copilot was turned off, or another fix of it went: nothing of it comes back.
        #expect(plan(retry, kept: nil, shown: answer) == nil)
        #expect(plan(retry, kept: plain, shown: answer) == nil)
        // Without the words, as once BriefBar restarted: it only goes there, for you to send.
        let wordless = CopilotDrafts.Retry(at: at, destination: .newSession, words: nil)
        #expect(plan(wordless, kept: nil) == CopilotDrafts.RetryPlan(words: nil, destination: .newSession, problem: nil, sends: false))
        #expect(plan(wordless, kept: nil)?.text == nil)
        #expect(plan(wordless, kept: nil)?.includesAnswer == nil)
    }

    /// An open build's composer, and so a fix Try Again sends as it opens, shows only once what shows of its run is
    /// current: not while the run read before it ran again, or changed, shows as it's read again.
    @Test func aBuildsComposerWaitsForItsRunToBeCurrent() {
        #expect(BuildCopilot.composer(.fix, isCurrent: true) == .fix)
        #expect(BuildCopilot.composer(.fix, isCurrent: false) == nil)
        #expect(BuildCopilot.composer(.explain, isCurrent: false) == nil)
        #expect(BuildCopilot.composer(nil, isCurrent: true) == nil)
    }

    /// Try Again sends the words a fix went with only for that very attempt, as when it took on what it's about tells: not
    /// for another sent meanwhile, as while the first waited for its session, or since, such as from the Send to Copilot
    /// window, whose words BriefBar doesn't keep.
    @Test func tryAgainSendsTheWordsOfThatFixAlone() {
        let store = store()
        let taken = now.addingTimeInterval(-600)
        store.remember(CopilotTasksStore.FixWords(text: "Use the shared helper", takenAt: taken), for: [.thread(11)], of: key, from: .fix)
        func work(takenAt: Date) -> CopilotWork {
            CopilotWork(part: .thread(11), purpose: .fix, state: .failed(nil), session: session, isTask: false, since: takenAt, takenAt: takenAt)
        }
        #expect(store.retryWords(for: work(takenAt: taken), of: key)?.text == "Use the shared helper")
        // What a retry has is what BriefBar still keeps, with the suggestion its fix applied: once another fix of it went,
        // or BriefBar forgot it, its composer lets the retry go (`CopilotPartComposer.retryIfAsked`).
        let suggested = CommentSuggestion(author: Person(id: "sam", name: "Sam Rivera"), commentId: 2, code: "delay = min(delay * 2, cap)")
        let applied = CopilotTasksStore.FixWords(text: "Apply it", takenAt: taken, suggestion: suggested)
        store.remember(applied, for: [.thread(14)], of: key, from: .fix)
        #expect(store.fixWords[CopilotTasksStore.PartKey(pullRequest: key, part: .thread(14))] == applied)
        #expect(applied != CopilotTasksStore.FixWords(text: "Apply it", takenAt: taken))
        #expect(applied != CopilotTasksStore.FixWords(text: "Apply it", takenAt: now, suggestion: suggested))
        #expect(store.retryWords(for: work(takenAt: taken.addingTimeInterval(0.5)), of: key) == nil)
        #expect(store.retryWords(for: work(takenAt: now), of: key) == nil)
        #expect(store.retryWords(for: work(takenAt: taken), of: PRKey("contoso", 4099)) == nil)
        // Not kept once Send Work to Copilot is off, or Azure DevOps stopped, as a send that took a while may end after.
        store.settings.copilotEnabled = false
        store.remember(CopilotTasksStore.FixWords(text: "Later", takenAt: now), for: [.thread(12)], of: key, from: .fix)
        store.settings.copilotEnabled = true
        store.stop()
        store.remember(CopilotTasksStore.FixWords(text: "Later", takenAt: now), for: [.thread(13)], of: key, from: .fix)
        #expect(store.fixWords[CopilotTasksStore.PartKey(pullRequest: key, part: .thread(12))] == nil)
        #expect(store.fixWords[CopilotTasksStore.PartKey(pullRequest: key, part: .thread(13))] == nil)
        // Fix All's, written for all the threads it took on, aren't kept for each: Try Again on one opens its own composer,
        // going where Fix All went, for you to write.
        let all = self.store()
        all.remember(CopilotTasksStore.FixWords(text: "Leave the logging comments", takenAt: taken), for: [.thread(15), .thread(16)], of: key, from: .fixAll)
        #expect(all.fixWords.isEmpty)
        #expect(all.retryWords(for: work(takenAt: taken), of: key) == nil)
        // A task's send says when it took them on, as its parts keep it.
        let settings = AppSettings(defaults: MemoryDefaults())
        let sending = self.store(settings)
        sending.launchForTests = { _, _, _ in throw CancellationError() }
        let at = sending.send(.pullRequest(pullRequest, .fixComments), prompt: "Fix 12", options: CopilotModel.standard,
                              repository: URL(fileURLWithPath: "/tmp/payments-api"), parts: [.thread(12)])
        #expect(at != nil)
        #expect(sending.pending.first?.taken?.first?.since == at)
        sending.stop()
        #expect(sending.send(.pullRequest(pullRequest, .fixComments), prompt: "Fix 13", options: CopilotModel.standard,
                             repository: URL(fileURLWithPath: "/tmp/payments-api"), parts: [.thread(13)]) == nil)
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

    /// Clear on a thread of a prompt copied for you to paste that takes on more, or of a copied Push & Reply, which stays:
    /// once you paste it, the thread's comments stay on Needs You, and they hold back how far the others leave it.
    @Test func clearKeepsAClearedThreadOnNeedsYou() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let early = now.addingTimeInterval(-3_600), late = now.addingTimeInterval(-60)
        let handOff = CommentHandOff(key: key, waiting: [
            CommentHandOff.Waiting(thread: 11, entry: "1. Thread 11", comments: [1], first: early, last: early),
            CommentHandOff.Waiting(thread: 13, entry: "2. Thread 13", comments: [2], first: late, last: late),
        ], account: nil, me: "me", dismissedCutoff: .distantPast, read: [:], unanswered: [11: [1: early], 13: [2: late]])
        let text = "Fix these:\n1. Thread 11\n2. Thread 13"
        #expect(handOff.handedOff(in: text) == late)
        let copied = try #require(SentPrompt(about(threads: [11, 13]), session: session, sentAt: now, copied: true))
        settings.copilotSentPrompts = [copied]
        store.copiedPrompts[copied.id] = (text, handOff)
        store.clear(.thread(11), of: key)
        let kept = try #require(store.copiedPrompts[copied.id]?.handOff)
        #expect(kept.waiting.map(\.entry) == [nil, "2. Thread 13"])
        #expect(kept.handedOff(in: text) == early.addingTimeInterval(-0.001))
        // A copied Push & Reply stays, handing off nothing of the thread it listed.
        let push = try #require(SentPrompt(about(.pushAndReply, threads: [13]), session: session, sentAt: now.addingTimeInterval(1), copied: true))
        settings.copilotSentPrompts = [push]
        store.copiedPrompts = [push.id: (text, handOff.without(thread: 11))]
        store.clear(.thread(13), of: key)
        #expect(settings.copilotSentPrompts.map(\.id) == [push.id])
        #expect(store.copiedPrompts[push.id]?.handOff?.handedOff(in: text) == nil)
    }

    /// Clearing the last thread a Push & Reply listed leaves the push, seen done only once so far, for the fixes it pushed
    /// along to stay pushed.
    @Test func clearLeavesAPushItEmpties() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let fixed = try #require(SentPrompt(about(threads: [11]), session: session, sentAt: now.addingTimeInterval(-600), copied: false, ended: .finished))
        let push = try #require(SentPrompt(about(.pushAndReply, threads: [12]), session: session, sentAt: now.addingTimeInterval(-60), copied: false))
        settings.copilotSentPrompts = [fixed, push]
        store.promptTurns[push.id] = SessionTurn(phase: .finished(summary: nil), since: now)
        let pushedAlong = "Pushed from ‘Retry backoff’, without a reply"
        #expect(store.work(on: .thread(11), of: key)?.sentence(name: "Retry backoff", forkOf: nil) == pushedAlong)
        store.clear(.thread(12), of: key)
        #expect(store.work(on: .thread(12), of: key) == nil)
        #expect(settings.copilotSentPrompts.first { $0.id == push.id }?.parts == [])
        #expect(store.work(on: .thread(11), of: key)?.sentence(name: "Retry backoff", forkOf: nil) == pushedAlong)
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
