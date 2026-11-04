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
        // And each says where it is in the details: a build by its row, conflicts at their top.
        let snapshot = try #require(PRClassifier.snapshot(for: record, seenCutoff: now, dismissedCutoff: now, now: now))
        let panel = PullRequestPanel(snapshot, record: record)
        #expect(PullRequestDetailsStore.Place.of(pipeline, in: panel) == .of(try #require(panel.checks.first { $0.check?.part == pipeline })))
        #expect(PullRequestDetailsStore.Place.of(.thread(11), in: panel) == .thread(11))
        #expect(PullRequestDetailsStore.Place.of(.build(999), in: panel) == .section(.checks))
        #expect(PullRequestDetailsStore.Place.of(.conflicts, in: panel) == .top)
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
        // Push & Reply of a build's fix alone replies on none of its threads.
        #expect(PullRequestTasks.parts(.pushAndReply, for: record, shipping: [.build(31)]) == [.build(31)])
        #expect(PullRequestTasks.shippedThreads([.build(31)]) == [])
        #expect(PullRequestTasks.shippedThreads([]) == nil)
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

    /// A Push & Reply whose prompt lists some of the threads its session fixed replies on those alone: the others stay
    /// fixed and not pushed, and one that another session fixed since stays that one's.
    @Test func pushAndReplySaysItShipsOnlyTheThreadsItListed() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = store(settings)
        let first = now.addingTimeInterval(-600), second = now.addingTimeInterval(-300)
        // The task fixed 11 and 12; it ships 12 alone.
        settings.copilotRuns = [run(task, .pushAndReply, startedAt: now, ended: .finished, taken: [
            TakenPart(.thread(11), since: first, ended: .finished), TakenPart(.thread(12), since: now, ships: true),
        ])]
        #expect(store.work(on: .thread(12), of: key)?.sentence(name: "Fix Comments", forkOf: nil) == "Pushed and replied from the ‘Fix Comments’ task")
        let eleven = try #require(store.work(on: .thread(11), of: key))
        #expect(eleven.sentence(name: "Fix Comments", forkOf: nil) == "Fixed in the ‘Fix Comments’ task, not pushed")
        #expect(eleven.since == first)
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).map(\.threads) == [[11]])
        // A fork fixed 11 again since: its fix is 11's latest, and it's ready there.
        settings.copilotRuns.append(run(fork, startedAt: second, ended: .finished, taken: [TakenPart(.thread(11), since: second)], forkedFrom: task))
        #expect(store.work(on: .thread(11), of: key)?.session == fork)
        #expect(store.readyFixes(of: key, among: [.thread(11), .thread(12)]).map(\.session) == [fork])
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
    /// so is what's too old, or waited too long for its turn to end.
    @Test func keepsOnlyWhatCanBeUsed() throws {
        let defaults = MemoryDefaults()
        let good = try #require(SentPrompt(about(), session: session, sentAt: now.addingTimeInterval(-60), copied: false))
        let ended = try #require(SentPrompt(about(), session: session, sentAt: now.addingTimeInterval(-86_400), copied: false, ended: .finished))
        let stale = try #require(SentPrompt(about(), session: session, sentAt: now.addingTimeInterval(-86_400), copied: false))
        let old = try #require(SentPrompt(about(), session: session, sentAt: now.addingTimeInterval(-SentPrompt.lifetime - 60), copied: false, ended: .finished))
        var written = try JSONSerialization.jsonObject(with: try JSONEncoder().encode([good, ended, stale, old])) as! [[String: Any]]
        written.append(["pullRequest": ["kind": "pullRequest", "scope": "contoso", "id": "4102"], "session": "../../Library",
                        "purpose": "fix", "parts": [["kind": "thread", "id": 11]], "sentAt": now.timeIntervalSinceReferenceDate])
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
        #expect(!restarted.contains { $0.parts == [.thread(12)] })
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
