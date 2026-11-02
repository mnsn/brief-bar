import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import Testing
@testable import AzureDevOpsUI

/// A pull request's Copilot session: the one you chose, its last task's, the work item's task that opened it, or the
/// Copilot app's session that goes with it, asking when two go with it as well as each other, and never picking one whose
/// log only mentions it; how work would reach it; and what's kept of your choice.
@MainActor
@Suite struct PullRequestSessionPickTests {
    private let now = Date(timeIntervalSince1970: 1_792_317_600)
    private let fixing = "11111111-1111-4111-8111-111111111111"
    private let opener = "22222222-2222-4222-8222-222222222222"
    private let onBranch = "44444444-4444-4444-8444-444444444444"
    private let recorded = "55555555-5555-4555-8555-555555555555"
    private let linked = "66666666-6666-4666-8666-666666666666"
    private let other = "77777777-7777-4777-8777-777777777777"
    private let key = PRKey("Contoso", 4071)

    private func run(_ id: String, startedAgo: TimeInterval, workItem: Int? = nil, opened: Int? = nil) -> CopilotRun {
        CopilotRun(
            id: id, workItem: workItem.map { WorkItemReference(organization: "contoso", project: "Storefront", id: $0) },
            onPullRequest: workItem == nil
                ? PullRequestReference(organization: "contoso", project: "Storefront", repository: "shop-web", id: 4071, sourceBranch: "fix-totals")
                : nil,
            action: workItem == nil ? .fixComments : nil, options: CopilotModel.standard,
            repository: URL(fileURLWithPath: "/tmp/shop-web"), worktree: URL(fileURLWithPath: "/tmp/copilot-worktrees/shop-web/\(id)"),
            startedAt: now.addingTimeInterval(-startedAgo), process: DetachedProgram.Handle(pid: 0, startedAt: nil), ended: .finished,
            pullRequest: opened.map { URL(string: "https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/\($0)")! }
        )
    }

    private func task(_ id: String, startedAgo: TimeInterval, reason: SessionChoice.Reason = .earlierTask, busy: Bool = false) -> SessionChoice {
        let run = reason == .openedIt ? run(id, startedAgo: startedAgo, workItem: 4217, opened: 4071) : run(id, startedAgo: startedAgo)
        return SessionChoice(kind: .task(run), name: id, lastActive: run.startedAt, reasons: [reason], isBusy: busy)
    }

    private func app(_ id: String, _ reasons: [SessionChoice.Reason], active: TimeInterval, born: TimeInterval? = nil) -> SessionChoice {
        let session = AppSession(id: id, name: id, createdAt: born.map { now.addingTimeInterval($0) }, lastActive: now.addingTimeInterval(active))
        return SessionChoice(kind: .app(session), name: id, lastActive: session.lastActive, reasons: reasons)
    }

    private func chosen(_ id: String?, ago: TimeInterval) -> PullRequestSessionChoice? {
        PullRequestSessionChoice(pullRequest: key, session: id, date: now.addingTimeInterval(-ago))
    }

    // MARK: Which one

    @Test func goesToItsLastTaskThenTheOneThatOpenedItThenTheAppsSession() {
        var choices = [
            task(fixing, startedAgo: 600),
            task(opener, startedAgo: 86_400, reason: .openedIt),
            app(onBranch, [.onItsBranch], active: -60),
        ]
        #expect(PullRequestSession.pick(choices, chosen: nil) == .session(choices[0], .lastTask))
        choices.removeFirst()
        #expect(PullRequestSession.pick(choices, chosen: nil) == .session(choices[0], .openedIt))
        choices.removeFirst()
        #expect(PullRequestSession.pick(choices, chosen: nil) == .session(choices[0], .onItsBranch))
        #expect(PullRequestSession.pick([], chosen: nil) == .newSession(chosenByYou: false))
    }

    /// Copilot working in its last task's session doesn't make another its: it's busy, and says so.
    @Test func staysWithItsLastTaskWhileCopilotWorksInIt() {
        let working = task(fixing, startedAgo: 60, busy: true)
        let choices = [working, app(onBranch, [.onItsBranch], active: -10)]
        #expect(PullRequestSession.pick(choices, chosen: nil) == .session(working, .lastTask))
        let session = PullRequestSession.make(choices, chosen: nil, createdAt: nil, canChoose: true)
        #expect(session.session?.isBusy == true)
        #expect(PullRequestSession.delivery(for: working, cliProblem: nil, canOpenInApp: true) == .busy("Copilot is still working in it."))
    }

    @Test func goesToTheSessionYouChoseUnlessATaskStartedSince() {
        let choices = [task(fixing, startedAgo: 3_600), app(onBranch, [.onItsBranch], active: -60), app(other, [], active: -7_200)]
        // Chosen after its last task: the one you chose, wherever it's from.
        #expect(PullRequestSession.pick(choices, chosen: chosen(other, ago: 600)) == .session(choices[2], .chosenByYou))
        #expect(PullRequestSession.pick(choices, chosen: chosen(nil, ago: 600)) == .newSession(chosenByYou: true))
        // A task started since: its last task's.
        #expect(PullRequestSession.pick(choices, chosen: chosen(other, ago: 7_200)) == .session(choices[0], .lastTask))
        // One that's gone leaves it to the rest.
        let gone = chosen("88888888-8888-4888-8888-888888888888", ago: 60)
        #expect(PullRequestSession.pick(choices, chosen: gone) == .session(choices[0], .lastTask))
        // Without tasks, whenever you chose.
        #expect(PullRequestSession.pick(Array(choices.dropFirst()), chosen: chosen(other, ago: 99_999)) == .session(choices[2], .chosenByYou))
    }

    /// One the app records with it, that you linked or that's on its branch is its, unless another goes with it as well,
    /// whichever is more recently active: then BriefBar asks which. One with every reason another has and more goes first.
    @Test func asksWhichWhenTwoGoWithItAsWellAsEachOther() {
        let branch = app(onBranch, [.onItsBranch], active: -3_600)
        let record = app(recorded, [.recordedByCopilot], active: -60)
        let both = app(linked, [.recordedByCopilot, .onItsBranch], active: -9_999)
        #expect(PullRequestSession.pick([branch, record], chosen: nil) == .ask([record, branch]))
        // Every reason the other has, and more.
        #expect(PullRequestSession.pick([branch, both], chosen: nil) == .session(both, .recordedByCopilot))
        #expect(PullRequestSession.pick([branch, record, both], chosen: nil) == .session(both, .recordedByCopilot))
        // Two on its branch.
        let second = app(other, [.onItsBranch], active: -10)
        #expect(PullRequestSession.pick([branch, second], chosen: nil) == .ask([second, branch]))
        // Once you chose, that one.
        #expect(PullRequestSession.pick([branch, second], chosen: chosen(onBranch, ago: 60)) == .session(branch, .chosenByYou))
        // Linked only through something else, or mentioning it, isn't enough.
        #expect(PullRequestSession.pick([app(other, [.linked], active: 0), app(recorded, [.mentionsIt], active: 0)], chosen: nil)
            == .newSession(chosenByYou: false))
    }

    /// A session whose log only mentions it is a guess: offered, never picked, the oldest that was there before it was
    /// created.
    @Test func neverPicksOneThatOnlyMentionsIt() {
        let created = now.addingTimeInterval(-86_400)
        let older = app(recorded, [.mentionsIt], active: -500, born: -172_800)
        let oldest = app(other, [.mentionsIt], active: -400, born: -200_000)
        let after = app(linked, [.mentionsIt], active: -2, born: -3_600)
        let choices = [after, older, oldest, app(onBranch, [], active: -1)]
        let session = PullRequestSession.make(choices, chosen: nil, createdAt: created, canChoose: true)
        #expect(session.pick == .newSession(chosenByYou: false))
        #expect(session.guess?.id == other)
        // Without when it was created, there's no telling.
        #expect(PullRequestSession.make(choices, chosen: nil, createdAt: nil, canChoose: true).guess == nil)
        // Not once something goes with it.
        let branch = app(onBranch, [.onItsBranch], active: -1)
        #expect(PullRequestSession.make(choices.dropLast() + [branch], chosen: nil, createdAt: created, canChoose: true).guess == nil)
    }

    @Test func listsWhatGoesWithItThenTheAppsOtherSessions() {
        let choices = [task(fixing, startedAgo: 60), app(onBranch, [.onItsBranch], active: -10)]
            + (0..<40).map { app(String(format: "aaaaaaaa-aaaa-4aaa-8aaa-%012d", $0), [], active: TimeInterval(-$0 * 60)) }
        let session = PullRequestSession.make(choices, chosen: nil, createdAt: nil, canChoose: true)
        #expect(session.candidates.map(\.id) == [fixing, onBranch])
        #expect(session.others.count == PullRequestSession.otherLimit)
        // The one you chose shows with them, wherever it's from.
        let picked = String(format: "aaaaaaaa-aaaa-4aaa-8aaa-%012d", 39)
        let chosenOne = PullRequestSession.make(choices, chosen: chosen(picked, ago: 1), createdAt: nil, canChoose: true)
        #expect(chosenOne.candidates.map(\.id) == [fixing, onBranch, picked])
        #expect(!chosenOne.others.contains { $0.id == picked })
    }

    // MARK: How work gets there

    @Test func goesWithTheCLIWhenItsFreeElseInTheCopilotApp() {
        let session = app(onBranch, [.onItsBranch], active: 0)
        #expect(PullRequestSession.delivery(for: session, cliProblem: nil, canOpenInApp: true) == .cli)
        let open = "The Copilot app has it open: Copilot can go on with it only there, where its history is."
        #expect(PullRequestSession.delivery(for: session, cliProblem: open, canOpenInApp: true) == .app(reason: open))
        #expect(PullRequestSession.delivery(for: session, cliProblem: open, canOpenInApp: false) == .unavailable(open))
        var shared = session
        shared.isFolderBusy = true
        #expect(PullRequestSession.delivery(for: shared, cliProblem: nil, canOpenInApp: true)
            == .busy("Copilot is working in its checkout for another task BriefBar sent."))
    }

    @Test func callsTasksByWhatTheyreFor() {
        #expect(PullRequestSession.name(of: task(fixing, startedAgo: 1)) == "Fix Comments")
        #expect(PullRequestSession.name(of: task(opener, startedAgo: 1, reason: .openedIt)) == "Work Item 4217")
        #expect(PullRequestSession.name(of: app(onBranch, [], active: 0)) == onBranch)
    }

    // MARK: The Send to Copilot window

    /// The window goes where you chose for the pull request, too, unless a task started on it since; a new session if you
    /// chose that; and one that's busy is never where it goes.
    @Test func theWindowGoesToTheSessionYouChose() {
        let pullRequest = TaskPullRequest(
            organization: "Contoso", project: "Storefront", repository: "shop-web", id: 4071, title: "Fix totals",
            url: URL(string: "https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/4071")!,
            sourceBranch: "fix-totals", targetBranch: "main"
        )
        let subject = TaskSubject.pullRequest(pullRequest, .fixComments)
        let last = task(fixing, startedAgo: 3_600)
        let choices = [last, app(onBranch, [.onItsBranch], active: -60), app(other, [], active: -7_200)]
        func suggested(_ chosen: PullRequestSessionChoice?) -> String? {
            CopilotTasksStore.suggestedChoice(choices, for: subject, continuable: last.run, createdAt: nil, chosen: chosen)?.id
        }
        #expect(suggested(nil) == fixing)
        #expect(suggested(chosen(other, ago: 60)) == other)
        #expect(suggested(chosen(nil, ago: 60)) == nil)
        #expect(suggested(chosen(other, ago: 7_200)) == fixing)
        var busy = choices
        busy[2].isBusy = true
        #expect(CopilotTasksStore.suggestedChoice(busy, for: subject, continuable: last.run, createdAt: nil, chosen: chosen(other, ago: 60))?.id == fixing)
    }

    // MARK: What's kept

    /// Your choice is kept by references only, the latest for each pull request, for as long as a link you make; what
    /// another program wrote there that isn't a pull request's and a session's is left out.
    @Test func keepsYourChoiceAsReferencesOnly() throws {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults, now: now)
        settings.choose(session: onBranch, for: key, at: now.addingTimeInterval(-60))
        settings.choose(session: other, for: key, at: now)
        settings.choose(session: nil, for: PRKey("contoso", 4088), at: now)
        #expect(settings.chosenSession(for: PRKey("CONTOSO", 4071))?.session == ItemRef.session(other))
        #expect(settings.chosenSession(for: PRKey("contoso", 4088))?.session == nil)
        #expect(settings.chosenSession(for: PRKey("contoso", 4088)) != nil)

        let data = try #require(defaults.data(forKey: SettingsKey.copilotPullRequestSessions))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(other) && !text.contains(onBranch))
        #expect(!text.contains("Fix totals"))
        #expect(AppSettings(defaults: defaults, now: now).copilotPullRequestSessions == settings.copilotPullRequestSessions)
        // Half a year on, it's forgotten, as a link you made is.
        #expect(AppSettings(defaults: defaults, now: now.addingTimeInterval(PullRequestSessionChoice.lifetime + 60)).copilotPullRequestSessions.isEmpty)

        settings.forgetChosenSession(for: key)
        #expect(settings.chosenSession(for: key) == nil)
        settings.forgetCopilotRuns()
        #expect(settings.copilotPullRequestSessions.isEmpty)
        #expect(defaults.data(forKey: SettingsKey.copilotPullRequestSessions) == nil)
    }

    @Test func leavesOutWhatIsntAPullRequestsSession() throws {
        let defaults = MemoryDefaults()
        let date = now.timeIntervalSinceReferenceDate
        let json = """
            [{"pullRequest":"pullRequest/contoso/4071","session":"session//\(onBranch)","date":\(date)},
             {"pullRequest":"workItem/contoso/4071","session":"session//\(onBranch)","date":\(date)},
             {"pullRequest":"pullRequest/contoso/4088","session":"pullRequest/contoso/1","date":\(date)},
             {"pullRequest":"pullRequest/contoso/4089","session":"session//../../etc","date":\(date)},
             {"pullRequest":"pullRequest/contoso/4090","date":\(date)},
             {"pullRequest":"pullRequest/contoso/4091","session":"session//\(other)","date":\(date + 86_400)},
             "junk", 42]
            """
        defaults.set(Data(json.utf8), forKey: SettingsKey.copilotPullRequestSessions)
        let kept = PullRequestSessionChoice.load(from: defaults, now: now)
        #expect(kept.map(\.pullRequest) == [.pullRequest(organization: "contoso", number: 4071), .pullRequest(organization: "contoso", number: 4090)])
        #expect(kept.first?.session == ItemRef.session(onBranch))
        #expect(kept.last?.session == nil)
        #expect(PullRequestSessionChoice(pullRequest: key, session: "not a session", date: now) == nil)
    }
}
