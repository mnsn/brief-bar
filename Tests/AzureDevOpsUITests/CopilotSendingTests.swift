import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import Testing
@testable import AzureDevOpsUI

/// Where a composer in place on a pull request's comments, builds or conflicts sends what you ask, and how it says so.
@MainActor
@Suite struct CopilotSendingTests {
    private let task = "11111111-1111-4111-8111-111111111111"
    private let app = "2f8a4c6e-1b3d-4e5f-8a7b-9c0d1e2f3a14"
    private let other = "44444444-4444-4444-8444-444444444444"
    private let elsewhere = "55555555-5555-4555-8555-555555555555"

    /// One of BriefBar's tasks on the pull request, which the Copilot CLI forks.
    private func taskChoice(isBusy: Bool = false) -> SessionChoice {
        let pullRequest = PullRequestReference(organization: "contoso", project: "Storefront", repository: "payments-api", id: 4102,
                                               sourceBranch: "payments-retry")
        let run = CopilotRun(
            id: task, workItem: nil, onPullRequest: pullRequest, action: .fixComments, options: CopilotModel.standard,
            repository: URL(fileURLWithPath: "/tmp/payments-api"), worktree: URL(fileURLWithPath: "/tmp/copilot-worktrees/payments-api/pr-4102"),
            startedAt: Date(), process: DetachedProgram.Handle(pid: 0, startedAt: nil)
        )
        var choice = SessionChoice(kind: .task(run), name: "Fix Comments", reasons: [.earlierTask])
        choice.isBusy = isBusy
        return choice
    }

    /// One of the Copilot app's sessions, which the app forks.
    private func appChoice(_ id: String, name: String = "Retry backoff", reasons: [SessionChoice.Reason] = [.onItsBranch], isBusy: Bool = false) -> SessionChoice {
        var choice = SessionChoice(kind: .app(AppSession(id: id, name: name)), name: name, reasons: reasons)
        choice.isBusy = isBusy
        return choice
    }

    private func session(_ picked: SessionChoice?, candidates: [SessionChoice], others: [SessionChoice] = []) -> PullRequestSession {
        PullRequestSession(
            pick: picked.map { .session($0, .onItsBranch) } ?? .newSession(chosenByYou: false), candidates: candidates, others: others,
            guess: nil, canChoose: true
        )
    }

    /// The session that worked on the thread leads, then a fork of it and a new session for a fix; then the pull request's
    /// other sessions, then the app's others. Explain asks sessions only.
    /// A fix called off before it goes, as when its composer closes, starts nothing: no task, and no prompt.
    @Test func aFixCalledOffBeforeItGoesStartsNothing() async throws {
        let prs = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .demo)
        await prs.loadOnce()
        let item = try #require(prs.items.first { prs.record(for: $0.key)?.role == .author })
        let record = try #require(prs.record(for: item.key))
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        let copilot = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        copilot.useEnvironment(["COPILOT_HOME": "/nonexistent"])
        copilot.appHomeForTests = URL(fileURLWithPath: "/nonexistent/copilot-app", isDirectory: true)
        let sending = CopilotSending(item: item, record: record, store: prs, copilot: copilot, session: nil)
        let fix = Task { await sending.fix(sending.commentFix(nil, how: nil, suggestion: nil, excerpt: nil), to: .newSession, choice: nil) }
        fix.cancel()
        let outcome = await fix.value
        #expect(outcome == CopilotSending.Outcome.notSent(CopilotSending.calledOff))
        #expect(copilot.pending.isEmpty)
        #expect(settings.copilotRuns.isEmpty)
    }

    /// A pull request that left your lists while a send waited, as merged or abandoned, gets nothing: no task, no prompt.
    @Test func nothingGoesForAPullRequestNoLongerListed() async throws {
        let prs = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .demo)
        await prs.loadOnce()
        let listed = try #require(prs.items.first { prs.record(for: $0.key)?.role == .author })
        var record = try #require(prs.record(for: listed.key))
        record.pullRequest.key = PRKey(listed.key.organization, 9_999)
        var item = listed
        item.key = record.pullRequest.key
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        let copilot = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        copilot.useEnvironment(["COPILOT_HOME": "/nonexistent"])
        copilot.appHomeForTests = URL(fileURLWithPath: "/nonexistent/copilot-app", isDirectory: true)
        let sending = CopilotSending(item: item, record: record, store: prs, copilot: copilot, session: nil)
        #expect(!sending.isListed)
        let fix = CopilotSending.Fix(prompts: ("Resolve them.", "Resolve them."), action: .resolveConflicts, parts: [.conflicts], handOff: nil)
        #expect(await sending.fix(fix, to: .newSession, choice: nil) == .notSent(CopilotSending.pullRequestGone))
        #expect(await sending.explainAsPrompt("Why?", about: .conflicts, to: appChoice(app)) == .notSent(CopilotSending.pullRequestGone))
        #expect(copilot.pending.isEmpty)
        #expect(settings.copilotRuns.isEmpty)
        // Listed, it goes on.
        #expect(CopilotSending(item: listed, record: try #require(prs.record(for: listed.key)), store: prs, copilot: copilot, session: nil).isListed)
    }

    @Test func theSessionThatWorkedOnItLeadsThenItsForkAndANewSession() {
        let picked = appChoice(app)
        let pullRequest = session(picked, candidates: [picked, taskChoice()], others: [appChoice(elsewhere, reasons: [])])
        let fix = CopilotDestinations.make(pullRequest, worked: task, ask: .fix)
        #expect(fix.first.map(\.destination) == [.session(task), .fork(task), .newSession])
        #expect(fix.more.map(\.destination) == [.session(app)])
        #expect(fix.others.map(\.destination) == [.session(elsewhere)])
        #expect(fix.preselected == .session(task))
        // Without one that worked on it, the pull request's.
        #expect(CopilotDestinations.make(pullRequest, worked: nil, ask: .fix).preselected == .session(app))
        let explain = CopilotDestinations.make(pullRequest, worked: nil, ask: .explain)
        #expect(explain.first.map(\.destination) == [.session(app)])
        #expect(explain.all.allSatisfy { if case .session = $0.destination { true } else { false } })
        // Nobody to ask: no session goes with it.
        #expect(CopilotDestinations.make(session(nil, candidates: []), worked: nil, ask: .explain).all.isEmpty)
        #expect(CopilotDestinations.make(session(nil, candidates: []), worked: nil, ask: .fix).preselected == .newSession)
    }

    /// A task of BriefBar's that's busy goes to a fork of it, which works in a worktree of its own; one of the app's
    /// sessions that's busy can't be forked now, so it stays, saying why.
    @Test func aBusyTaskGoesToItsForkFirst() {
        let busyTask = taskChoice(isBusy: true)
        #expect(CopilotDestinations.make(session(busyTask, candidates: [busyTask]), worked: nil, ask: .fix).preselected == .fork(task))
        #expect(CopilotDestinations.make(session(busyTask, candidates: [busyTask]), worked: nil, ask: .explain).preselected == .session(task))
        let busyApp = appChoice(app, isBusy: true)
        #expect(CopilotDestinations.make(session(busyApp, candidates: [busyApp]), worked: nil, ask: .fix).preselected == .session(app))
    }

    /// Fix All says what it takes on: all the open threads, or only those that wait on you.
    @Test func fixAllSaysWhatItTakesOn() {
        #expect(CopilotAsk.fixAllTitle(waiting: 3, open: 3) == "Fix All")
        #expect(CopilotAsk.fixAllTitle(waiting: 1, open: 2) == "Fix 1 Comment")
        #expect(CopilotAsk.fixAllTitle(waiting: 2, open: 5) == "Fix 2 Comments")
        #expect(CopilotAsk.explain.placeholder() == "What do you want to know? (optional)")
        #expect(CopilotAsk.explain.placeholder(followingUp: true) == "What else do you want to know? (optional)")
    }

    /// Each says what it's about: a comment's Explain and Fix, a build's Explain the Failure and Fix, and conflicts'
    /// Explain the Conflicts and Resolve.
    @Test func asksSayWhatTheyreAbout() {
        #expect(CopilotAsk.explain.title(about: .thread(11)) == "Explain")
        #expect(CopilotAsk.explain.sendTitle(about: .thread(11)) == "Ask")
        #expect(CopilotAsk.fix.title(about: .thread(11)) == "Fix")
        #expect(CopilotAsk.explain.title(about: .build(31)) == "Explain the Failure")
        #expect(CopilotAsk.fix.sendTitle(about: .build(31)) == "Fix")
        #expect(CopilotAsk.explain.title(about: .conflicts) == "Explain the Conflicts")
        #expect(CopilotAsk.fix.title(about: .conflicts) == "Resolve")
        #expect(CopilotAsk.fix.sendTitle(about: .conflicts) == "Resolve")
        #expect(CopilotAsk.fixAll.title(about: nil) == "Fix All")
    }

    /// A name a paragraph long is cut short in its middle, so ▾ keeps its place.
    @Test func longNamesAreCutShortInTheirMiddle() {
        #expect(CopilotDestinationNames.short("Retry backoff") == "Retry backoff")
        let long = "Investigate why the payments client retries forever when the provider is down"
        let short = CopilotDestinationNames.short(long)
        #expect(short.count <= CopilotDestinationNames.limit)
        #expect(short == "Investigate why…rovider is down")
    }

    /// VoiceOver says the names a sentence quotes without their quotes, but keeps an apostrophe in one.
    @Test func voiceOverSaysQuotedNamesWithoutTheirQuotes() {
        #expect(SpokenText.unquoted("Copilot is fixing this in ‘Retry backoff’") == "Copilot is fixing this in Retry backoff")
        #expect(SpokenText.unquoted("Fixed in ‘Retry backoff’, not pushed") == "Fixed in Retry backoff, not pushed")
        #expect(SpokenText.unquoted("Fixing this in a fork of ‘Sam’s fix’") == "Fixing this in a fork of Sam’s fix")
        #expect(SpokenText.unquoted("Couldn’t fix it") == "Couldn’t fix it")
    }
}
