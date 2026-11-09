import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import Testing
@testable import AzureDevOpsUI

/// Where a composer in place on a pull request's comments, builds or conflicts sends what you ask, and how it says so.
@MainActor
@Suite(.opensNothing) struct CopilotSendingTests {
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
        let sent = await fix.value
        #expect(sent.outcome == CopilotSending.Outcome.notSent(CopilotSending.calledOff))
        #expect(sent.takenAt == nil)
        #expect(copilot.pending.isEmpty)
        #expect(settings.copilotRuns.isEmpty)
    }

    /// A pull request that left your lists, or was completed or abandoned, while a send waited gets nothing: no task, no
    /// prompt.
    @Test func nothingGoesForAPullRequestNoLongerOpen() async throws {
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
        #expect(!sending.isOpen)
        let fix = CopilotSending.Fix(prompts: ("Resolve them.", "Resolve them."), action: .resolveConflicts, parts: [.conflicts], handOff: nil)
        #expect(await sending.fix(fix, to: .newSession, choice: nil).outcome == .notSent(CopilotSending.pullRequestGone))
        #expect(await sending.explainAsPrompt("Why?", about: .conflicts, to: appChoice(app)) == .notSent(CopilotSending.pullRequestGone))
        #expect(copilot.pending.isEmpty)
        #expect(settings.copilotRuns.isEmpty)
        // Completed, as Done keeps it: nothing goes either.
        let done = try #require(prs.items.first { prs.record(for: $0.key)?.pullRequest.status == .completed })
        let completed = CopilotSending(item: done, record: try #require(prs.record(for: done.key)), store: prs, copilot: copilot, session: nil)
        #expect(!completed.isOpen)
        #expect(await completed.fix(fix, to: .newSession, choice: nil).outcome == .notSent(CopilotSending.pullRequestGone))
        #expect(copilot.pending.isEmpty)
        // Open in your lists, it goes on.
        #expect(CopilotSending(item: listed, record: try #require(prs.record(for: listed.key)), store: prs, copilot: copilot, session: nil).isOpen)
    }

    /// While Pull Request Order is on, what BriefBar sends to change code ends asking the session to tell BriefBar the pull
    /// request's stage once it pushed: a fix sent in place, and a work item sent with Send With, as it is; while it's off,
    /// neither does.
    @Test func whatChangesCodeAsksForTheStageWhilePullRequestOrderIsOn() async throws {
        let prs = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .demo)
        await prs.loadOnce()
        let item = try #require(prs.items.first { prs.record(for: $0.key)?.role == .author })
        let record = try #require(prs.record(for: item.key))
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        let workItem = WorkItem(id: 7, organization: "contoso", project: "Storefront", type: "Bug", title: "Totals", state: "New", category: .proposed)
        settings.copilotRepositories[workItem.copilotTask.reference.projectKey] = "/tmp/storefront"
        let copilot = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        copilot.useEnvironment(["COPILOT_HOME": "/nonexistent"])
        copilot.appHomeForTests = URL(fileURLWithPath: "/nonexistent/copilot-app", isDirectory: true)
        let services = AppServices(defaults: MemoryDefaults(), isDemo: false)
        copilot.services = services
        final class Sent { var prompts: [String] = [] }
        let sent = Sent()
        copilot.launchForTests = { request, _, _ in
            sent.prompts.append(request.prompt)
            throw CancellationError()
        }
        let sending = CopilotSending(item: item, record: record, store: prs, copilot: copilot, session: nil)
        let fix = CopilotSending.Fix(prompts: ("Resolve them.", "Resolve them."), action: .resolveConflicts, parts: [.conflicts], handOff: nil)
        let line = "\n\n" + PromptTemplate.stageLine
        let rendered = PromptTemplate.render(settings.copilotPromptTemplate, item: workItem.copilotTask)

        for on in [true, false] {
            services.pullRequestOrder.setOn(on)
            sent.prompts = []
            #expect(await sending.fix(fix, to: .fork(task), choice: taskChoice()).outcome == .sent)
            copilot.quickSend(workItem, options: CopilotModel.standard)
            for _ in 0..<200 where sent.prompts.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(Set(sent.prompts) == (on ? ["Resolve them." + line, rendered + line] : ["Resolve them.", rendered]))
        }
        // Nor does a review, which changes nothing.
        services.pullRequestOrder.setOn(true)
        let review = CopilotSending.Fix(prompts: ("Review it.", "Review it."), action: .review, parts: [], handOff: nil)
        #expect(review.sent(asksForStage: true) == ("Review it.", "Review it."))
    }

    /// A thread's fix keeps the change suggested in it that it applies as written, for Try Again to apply it again, and
    /// none when it doesn't apply one.
    @Test func aThreadsFixKeepsTheSuggestionItApplies() async throws {
        let prs = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .demo)
        await prs.loadOnce()
        let item = try #require(prs.items.first { prs.record(for: $0.key)?.role == .author && prs.record(for: $0.key)?.details?.threads.isEmpty == false })
        let record = try #require(prs.record(for: item.key))
        let thread = try #require(record.details?.threads.first)
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        let copilot = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        let sending = CopilotSending(item: item, record: record, store: prs, copilot: copilot, session: nil)
        let suggestion = CommentSuggestion(author: Person(id: "sam", name: "Sam Rivera"), commentId: 2, code: "delay = min(delay * 2, cap)")
        #expect(sending.commentFix(thread, how: nil, suggestion: suggestion, excerpt: nil).suggestion == suggestion)
        #expect(sending.commentFix(thread, how: nil, suggestion: nil, excerpt: nil).suggestion == nil)
        #expect(sending.commentFix(nil, how: nil, suggestion: nil, excerpt: nil).suggestion == nil)
    }

    /// A comment's fix sent with Push and Reply on is a Push & Reply that fixes what it takes on first: its prompts ship what
    /// it changes, and it goes as Push & Reply goes, with no tool denied it, the branch the pull request merges into read
    /// again before it starts, and what it takes on saying it fixes it first; to one of the Copilot app's sessions, only once
    /// what it would push is checked. Without it, it's a fix, which doesn't commit, push or reply.
    @Test func aFixSentToPushAndReplyGoesAsPushAndReply() async throws {
        let prs = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .demo)
        await prs.loadOnce()
        let item = try #require(prs.items.first { prs.record(for: $0.key)?.role == .author && prs.record(for: $0.key)?.details?.threads.isEmpty == false })
        let record = try #require(prs.record(for: item.key))
        let thread = try #require(record.details?.threads.first)
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        let copilot = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        copilot.useEnvironment(["COPILOT_HOME": "/nonexistent"])
        copilot.appHomeForTests = URL(fileURLWithPath: "/nonexistent/copilot-app", isDirectory: true)
        copilot.openForTests = { _, _ in false }
        final class Sent { var requests: [CopilotLauncher.Request] = [] }
        let sent = Sent()
        copilot.launchForTests = { request, _, _ in
            sent.requests.append(request)
            throw CancellationError()
        }
        let sending = CopilotSending(item: item, record: record, store: prs, copilot: copilot, session: nil)
        let plain = sending.commentFix(thread, how: nil, suggestion: nil, excerpt: nil)
        #expect(plain.action == .fixComments)
        #expect(!plain.fixes)
        #expect(!plain.pushes)
        #expect(plain.prompts.worktree.contains("Don't commit, push or reply on the pull request"))
        let ships = sending.commentFix(thread, how: "Cap it.", suggestion: nil, excerpt: nil, ships: true)
        #expect(ships.action == .pushAndReply)
        #expect(ships.fixes)
        #expect(ships.pushes)
        #expect(ships.parts == [.thread(thread.id)])
        #expect(ships.handOff != nil)
        #expect(ships.prompts.worktree.contains("Then ship it, in this worktree:"))
        #expect(ships.prompts.session.contains("Then ship it, in your checkout:"))
        #expect(!ships.prompts.session.contains("Don't commit, push or reply"))
        let all = sending.commentFix(nil, how: nil, suggestion: nil, excerpt: nil, ships: true)
        #expect(all.action == .pushAndReply)
        #expect(all.fixes)
        #expect(all.parts == PullRequestTasks.parts(.fixComments, for: record))
        #expect(all.prompts.worktree.contains("Then ship them, in this worktree:"))

        // To a fork of one of BriefBar's tasks, with the Copilot CLI.
        #expect(await sending.fix(ships, to: .fork(task), choice: taskChoice()).outcome == .sent)
        for _ in 0..<200 where sent.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let request = try #require(sent.requests.first)
        guard case .pullRequest(_, let action) = request.subject else {
            Issue.record("Not sent for the pull request")
            return
        }
        // A Push & Reply, whose tools the Copilot CLI doesn't deny (`PullRequestAction.deniedTools`).
        #expect(action == .pushAndReply)
        #expect(request.targetNow != nil)
        #expect(request.prompt == ships.prompts.session)
        let taken = try #require(copilot.pending.first?.taken)
        #expect(taken.map(\.part) == [.thread(thread.id)])
        #expect(taken.map(\.ships) == [true])
        #expect(taken.map(\.fixes) == [true])

        // To one of the Copilot app's sessions: not while the branch the pull request merges into can't be read.
        var appSession = PullRequestSession(
            pick: .session(appChoice(app), .onItsBranch), candidates: [appChoice(app)], others: [], guess: nil, canChoose: true
        )
        appSession.delivery = .app(reach: nil, reason: nil)
        let toApp = CopilotSending(item: item, record: record, store: prs, copilot: copilot, session: appSession)
        #expect(await toApp.fix(ships, to: .session(app), choice: appChoice(app)).outcome == .notSent(
            "BriefBar couldn't read which branch the pull request merges into, so nothing went: Azure DevOps isn't on."
        ))
        #expect(settings.copilotSentPrompts.isEmpty)
    }

    /// Sent while the pull request's branches move, as its conflicts are read again, a fix or a question doesn't build on
    /// what a session answered about them as they were: it stops, saying so, and goes without it once sent again. Builds'
    /// and comments' answers go as they are.
    @Test func anAnswerAboutTheBranchesBeforeTheyMovedIsLeftOut() throws {
        let pullRequest = try #require(DemoData.records(now: Date()).first).pullRequest
        let asked = PullRequestFilesStore.Head(pullRequest)
        var retargeted = pullRequest
        retargeted.targetBranch = "release"
        retargeted.targetCommit = "t2"
        let moved = PullRequestFilesStore.Head(retargeted)
        let answer = CopilotAnswer(question: nil, answer: "Keep main's Refunded, under the new names.")
        func asking(
            _ ask: CopilotAsk = .fix, part: PullRequestPart = .conflicts, now: PullRequestFilesStore.Head?, about: PullRequestFilesStore.Head?
        ) -> CopilotAsking {
            CopilotAsking(
                ask: ask, part: part, action: .resolveConflicts, head: { now }, answeredAbout: about,
                fix: { _, _, _ in CopilotSending.Fix(prompts: ("", ""), action: .resolveConflicts, parts: [part], handOff: nil) },
                question: { _, _ in "" }
            )
        }
        let resolve = asking(now: moved, about: asked)
        let left = resolve.quoting(answer)
        #expect(left.answer == nil)
        #expect(left.isLeftOut)
        #expect(resolve.answerLeftOut == "The answer was about the branches before they moved, so it's left out. Resolve again to go without it.")
        #expect(asking(.explain, now: moved, about: asked).answerLeftOut.hasSuffix("Ask again to go without it."))
        // The same branches: it goes.
        let kept = asking(now: asked, about: asked).quoting(answer)
        #expect(kept.answer == answer)
        #expect(!kept.isLeftOut)
        // Without an answer, nothing's left out.
        #expect(!resolve.quoting(nil).isLeftOut)
        // A build's answer, which isn't about branches, goes as it is.
        let build = asking(part: .build(31), now: moved, about: nil).quoting(answer)
        #expect(build.answer == answer)
        #expect(!build.isLeftOut)
    }

    /// A comment's fix goes with Push and Reply as it is as you send it, Try Again's included, which puts back what the fix
    /// it tries again went with right before it sends that again: not as it's set by the time the fix is written, once what
    /// its prompt quotes is read, as when you change it in another composer meanwhile, for the next fix.
    @Test func aFixPushesAndRepliesAsYouSentIt() {
        let choice = PushAndReplyChoice()
        func asking(readsChoice: Bool, ships: Bool = false) -> CopilotAsking {
            var shipsNow: (@MainActor () -> Bool)?
            if readsChoice { shipsNow = { choice.ships } }
            return CopilotAsking(
                ask: .fix, part: .thread(11), action: .fixComments, ships: ships, shipsNow: shipsNow,
                fix: { _, _, ships in
                    CopilotSending.Fix(prompts: ("", ""), action: ships ? .pushAndReply : .fixComments, parts: [.thread(11)], handOff: nil, fixes: ships)
                },
                question: { _, _ in "" }
            )
        }
        choice.ships = true
        let pushes = asking(readsChoice: true).fixAsSent()
        choice.ships = false
        #expect(pushes("Keep it short", nil).fixes)
        let leaves = asking(readsChoice: true, ships: true).fixAsSent()
        choice.ships = true
        #expect(!leaves("Keep it short", nil).fixes)
        // Without a choice to read now, as the composer had it when it was made.
        #expect(asking(readsChoice: false, ships: true).fixAsSent()("", nil).fixes)
        #expect(!asking(readsChoice: false).fixAsSent()("", nil).fixes)
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
        // Its fork is there only while it leads, as Try Again has a fork of it that couldn't start lead: then it's there to
        // send to (`CopilotPartComposer.retryLead`).
        #expect(CopilotDestinations.make(pullRequest, worked: nil, ask: .fix).choice(for: .fork(task)) == nil)
        #expect(CopilotDestinations.make(pullRequest, worked: CopilotDestination.fork(task).sessionID, ask: .fix).choice(for: .fork(task))?.id == task)
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
        // For a pull request, of all its unresolved threads, whichever its details show: here, one you answered last, which
        // Active shows, and one without a status that waits on you, which it hides.
        let me = Person(id: "robin", name: "Robin Diaz"), sam = Person(id: "sam", name: "Sam Rivera")
        let pullRequest = PullRequest(
            key: PRKey("contoso", 7), title: "Cap the backoff", author: me, createdAt: Date(), projectId: "p", projectName: "Shop",
            repositoryId: "r", repositoryName: "shop-web"
        )
        let threads = [
            ReviewThread(id: 1, comments: [ReviewComment(id: 1, author: sam, text: "Cap it?", publishedAt: Date(timeIntervalSince1970: 1)),
                                           ReviewComment(id: 2, author: me, text: "Done.", publishedAt: Date(timeIntervalSince1970: 2))]),
            ReviewThread(id: 2, status: nil, comments: [ReviewComment(id: 1, author: sam, text: "And this?", publishedAt: Date(timeIntervalSince1970: 3))]),
        ]
        let record = PRRecord(
            pullRequest: pullRequest, role: .author,
            details: PRDetails(fetchedAt: Date(), fingerprint: pullRequest.fingerprint, checks: [], threads: threads, activity: []),
            me: me.id
        )
        #expect(CopilotAsk.fixAllTitle(record) == "Fix 1 Comment")
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

/// Push and Reply as a composer has it, which may change after a fix is sent.
@MainActor
private final class PushAndReplyChoice {
    var ships = false
}
