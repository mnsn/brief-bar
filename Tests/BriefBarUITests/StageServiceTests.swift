import BriefBarCore
import BriefBarUI
import Foundation
import SwiftUI
import Testing

/// The time, as a test moves it on.
@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_792_000_000)

    func advance(days: Double = 0, seconds: TimeInterval = 0) {
        now = now.addingTimeInterval(days * 86_400 + seconds)
    }
}

/// Pull Request Order's stages, as the app keeps them: from what Azure DevOps and the Copilot app tell, with what you set,
/// for each account, Undo, Let BriefBar Decide, what ends a stage you set, and what's forgotten when.
@MainActor
@Suite struct StageServiceTests {
    private static let repository = "contoso/7d3f9a12/shop-web"
    private static let account = "robin@contoso.com"
    private static let cart = ItemRef.session("7c1e2a90-4b3d-4f5e-8a6b-1c2d3e4f5a6b")!

    private static func ref(_ number: Int) -> ItemRef {
        .pullRequest(organization: "contoso", number: number)
    }

    private static func ado(_ number: Int, from source: String = "robin/work", state: PullRequestState = .open) -> OrderPullRequest {
        OrderPullRequest(
            ref: ref(number), repository: repository, sourceBranch: source + "-\(number)", targetBranch: "main", author: "robin",
            state: state, createdAt: Date(timeIntervalSince1970: 1_791_000_000 + Double(number))
        )
    }

    private static func defaults(on: Bool = true) -> MemoryDefaults {
        let defaults = MemoryDefaults()
        if on { defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey) }
        return defaults
    }

    private static func service(_ defaults: MemoryDefaults, clock: Clock = Clock()) -> PullRequestOrder {
        PullRequestOrder(defaults: defaults, isDemo: false, now: { clock.now })
    }

    /// What Azure DevOps tells: these pull requests, each with its facts, as it lists them, or, `listed` false, before it
    /// has read its lists since BriefBar started, as offline.
    private static func tell(
        _ order: PullRequestOrder, _ facts: [Int: StageFacts], states: [Int: PullRequestState] = [:], account: String? = account,
        listed: Bool = true
    ) {
        order.publish(
            .azureDevOps, pullRequests: facts.keys.sorted().map { ado($0, state: states[$0] ?? .open) },
            stages: Dictionary(uniqueKeysWithValues: facts.map { (ref($0.key), $0.value) }), account: account, listed: listed
        )
    }

    /// What the Copilot app tells: one session, on these pull requests, in this state since then, and what it does or how
    /// it ended, when the source says.
    private static func tellSession(
        _ order: PullRequestOrder, on numbers: [Int], state: ItemState?, since: Date, activity: StageSession.Activity? = nil
    ) {
        order.publish(
            .copilot, sessions: [OrderSession(ref: cart, pullRequests: numbers.map(ref))],
            items: [LinkedItem(ref: cart, label: "Cart", title: "Cart", symbol: "bolt.fill", color: .blue, state: state, date: since)],
            sessionActivities: activity.map { [cart: $0] } ?? [:]
        )
    }

    private static func why(_ order: PullRequestOrder, _ number: Int) -> String? {
        order.stage(of: ref(number)).map { StageText.why($0, name: order.name(of:)) }
    }

    @Test func itWorksStagesOutOnlyWhileOn() {
        let defaults = Self.defaults(on: false)
        let order = Self.service(defaults)
        Self.tell(order, [4093: StageFacts(role: .author)])
        #expect(order.stages.isEmpty)

        order.setOn(true)
        Self.tell(order, [4093: StageFacts(role: .author), 4094: StageFacts(role: .reviewer)])
        #expect(order.stages.keys.sorted() == [Self.ref(4093)])
        #expect(Self.why(order, 4093) == "Find a reviewer")

        order.setOn(false)
        #expect(order.stages.isEmpty)
    }

    @Test func aStageYouSetIsKeptForTheAccountAndUndoPutsBackWhatItReplaced() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4093: StageFacts(role: .author, votes: "0", commit: "a1b2c3d")])

        #expect(order.setStage(.yourReview, of: Self.ref(4093)) == .done)
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)
        #expect(order.stage(of: Self.ref(4093))?.isSetByYou == true)
        #expect(order.lastStageChange?.words == "Moved !4093 to Your review")
        let kept = StageMarks.load(from: defaults)
        #expect(kept.mark(of: Self.ref(4093), for: Self.account)?.stage == .yourReview)
        #expect(kept.mark(of: Self.ref(4093), for: Self.account)?.commit == nil)
        #expect(order.setStage(.yourReview, of: Self.ref(4093)) == .unchanged)

        #expect(order.finishedReview(Self.ref(4093)) == .done)
        #expect(order.stage(of: Self.ref(4093))?.stage == .teammateReview)
        order.undo()
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)
        #expect(order.lastStageChange == nil)

        order.letBriefBarDecide(Self.ref(4093))
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)
        #expect(order.lastStageChange?.words == "Let BriefBar decide !4093's stage")
        #expect(StageMarks.load(from: defaults).isEmpty)
        order.undo()
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)
        order.dismissLastChange()
        #expect(order.lastStageChange == nil)
    }

    @Test func onlyTheThreeStagesCanBeSetAndOnlyWhereTheSourceTellsStages() {
        let order = Self.service(Self.defaults())
        Self.tell(order, [4093: StageFacts(role: .author, isReady: true)])
        #expect(order.setStage(.canMerge, of: Self.ref(4093)) == .refused("Azure DevOps decides: once it's approved and its checks pass"))
        #expect(order.setStage(.waits, of: Self.ref(4093)) == .refused("Its order decides"))
        #expect(order.setStage(.merged, of: Self.ref(4093)) == .refused("It merges in Azure DevOps"))
        #expect(order.setStage(.yourReview, of: Self.ref(4999)) == .refused("BriefBar doesn't list that pull request now"))
        #expect(order.stage(of: Self.ref(4093))?.stage == .canMerge)

        let off = Self.service(Self.defaults(on: false))
        #expect(off.setStage(.yourReview, of: Self.ref(4093)) ==
            .refused("Pull Request Order is off: turn it on in Settings › Pull Requests"))
    }

    /// Let BriefBar Decide says whether it changed anything, so VoiceOver hears a change only when there was one.
    @Test func letBriefBarDecideChangesNothingWhereYouSetNone() {
        let order = Self.service(Self.defaults())
        Self.tell(order, [4093: StageFacts(role: .author)])
        #expect(order.letBriefBarDecide(Self.ref(4093)) == .unchanged)
        #expect(order.lastStageChange == nil)
        order.setStage(.yourReview, of: Self.ref(4093))
        #expect(order.letBriefBarDecide(Self.ref(4093)) == .done)
        #expect(order.letBriefBarDecide(Self.ref(4093)) == .unchanged)
        #expect(order.letBriefBarDecide(Self.ref(4999)) == .unchanged)
    }

    @Test func eachAccountHasItsOwnStages() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4093: StageFacts(role: .author)])
        order.setStage(.inProgress, of: Self.ref(4093))

        Self.tell(order, [4093: StageFacts(role: .author)], account: "robin@fabrikam.com")
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)
        Self.tell(order, [4093: StageFacts(role: .author)])
        #expect(order.stage(of: Self.ref(4093))?.stage == .inProgress)
    }

    @Test func oneOnlySentToYouKeepsItsStageInMemoryUntilItsListed() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4120: StageFacts(role: .sentToYou, asksYou: "Priya sent it in Teams")])
        #expect(order.setStage(.inProgress, of: Self.ref(4120)) == .done)
        #expect(order.stage(of: Self.ref(4120))?.stage == .inProgress)
        #expect(defaults.object(forKey: StageMarks.defaultsKey) == nil)
        #expect(order.keepsStages)

        // Asked to review it now, it's kept with the account.
        Self.tell(order, [4120: StageFacts(role: .reviewer, asksYou: "Priya asked you")])
        #expect(order.stage(of: Self.ref(4120))?.stage == .inProgress)
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4120), for: Self.account)?.stage == .inProgress)
    }

    @Test func beforeBriefBarKnowsTheAccountItsInMemory() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4093: StageFacts(role: .author)], account: nil)
        order.setStage(.yourReview, of: Self.ref(4093))
        #expect(defaults.object(forKey: StageMarks.defaultsKey) == nil)
        Self.tell(order, [4093: StageFacts(role: .author)])
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4093), for: Self.account)?.stage == .yourReview)
    }

    @Test func aSetInProgressGoesOnceNewCommitsComeAndAnyGoesAsItMerges() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4093: StageFacts(role: .author, commit: "a1b2c3d"), 4094: StageFacts(role: .author)])
        order.setStage(.inProgress, of: Self.ref(4093))
        order.setStage(.yourReview, of: Self.ref(4094))

        Self.tell(order, [4093: StageFacts(role: .author, commit: "e4f5a6b"), 4094: StageFacts(role: .author)])
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4093), for: Self.account) == nil)

        Self.tell(order, [4093: StageFacts(role: .author), 4094: StageFacts(role: .author, state: .merged)], states: [4094: .merged])
        #expect(order.stage(of: Self.ref(4094))?.stage == .merged)
        #expect(StageMarks.load(from: defaults).isEmpty)
    }

    /// How far each of your pull requests got is kept for its account, from Your review on, so that BriefBar never moves one
    /// back on its own: approved, it stays in Approved as its build fails, marked, and so once BriefBar starts again, before
    /// it reads its details; it goes back to your teammates only as it loses its approval, as when a push resets the votes.
    /// Merged, or with Forget Stages…, it's forgotten.
    @Test func howFarYoursGotIsKeptAndOnlyLosingItsApprovalMovesItBack() {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        func reached(_ number: Int) -> PullRequestStage? {
            StagesReached.load(from: defaults).reach(of: Self.ref(number), for: Self.account, at: clock.now)?.stage
        }
        let approved = StageFacts(role: .author, isApproved: true, approvedBy: "Maria", othersVoted: true, votes: "10")
        Self.tell(order, [4093: approved])
        #expect(order.stage(of: Self.ref(4093))?.stage == .approved)
        #expect(Self.why(order, 4093) == "Maria approved it")
        #expect(reached(4093) == .approved)

        var failing = approved
        failing.failure = "Build failed"
        Self.tell(order, [4093: failing])
        #expect(order.stage(of: Self.ref(4093))?.stage == .approved)
        #expect(Self.why(order, 4093) == "Maria approved it · build failed")
        let again = Self.service(defaults, clock: clock)
        var unread = failing
        unread.isApproved = nil
        Self.tell(again, [4093: unread])
        #expect(again.stage(of: Self.ref(4093))?.stage == .approved)

        // A push reset its votes.
        Self.tell(again, [4093: StageFacts(role: .author, failure: "Build failed", waitingFor: "Waiting on Maria")])
        #expect(again.stage(of: Self.ref(4093))?.stage == .teammateReview)
        #expect(Self.why(again, 4093) == "Waiting on Maria · build failed")
        #expect(reached(4093) == .teammateReview)

        Self.tell(again, [4093: StageFacts(role: .author, state: .merged)], states: [4093: .merged])
        #expect(StagesReached.load(from: defaults).isEmpty)

        Self.tell(again, [4094: approved])
        #expect(reached(4094) == .approved)
        // Forget Stages… forgets it; how far one Azure DevOps lists now got forms again at once, from what it says.
        Self.tell(again, [4095: approved])
        #expect(reached(4094) == .approved)
        again.forgetStages()
        #expect(reached(4094) == nil)
        #expect(reached(4095) == .approved)
    }

    /// Once a stage you set ends, BriefBar goes on from there, not from how far it had got before: one you finished
    /// reviewing that a teammate then wants changes on stays with your teammates, marked, rather than go back to your
    /// review as the session that wrote it had it.
    @Test func onceAStageYouSetEndsItGoesOnFromThere() {
        let clock = Clock()
        let order = Self.service(Self.defaults(), clock: clock)
        Self.tell(order, [4093: StageFacts(role: .author, waitingFor: "Waiting on Maria")])
        Self.tellSession(order, on: [4093], state: .running, since: clock.now)
        clock.advance(seconds: 600)
        Self.tellSession(order, on: [4093], state: .done, since: clock.now)
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)

        #expect(order.finishedReview(Self.ref(4093)) == .done)
        Self.tell(order, [4093: StageFacts(
            role: .author, changesWanted: "Maria wants changes", waitingFor: "Waiting on Maria", othersVoted: true, votes: "-5"
        )])
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)
        #expect(order.stage(of: Self.ref(4093))?.stage == .teammateReview)
        #expect(Self.why(order, 4093) == "Waiting on Maria · Maria wants changes")
    }

    /// Azure DevOps can list a pull request before the Copilot app tells which session opened it: told within minutes, it's
    /// that session's, as if BriefBar had known it first. Told later, or where BriefBar knew of the session as it first kept
    /// the pull request, it's no such thing: one that loses its approval stays with your teammates.
    @Test func whereBriefBarFirstSawOneIsItsSessionsOnlyBeforeItKnewOfThemAndForMinutes() {
        let clock = Clock()
        let waiting = StageFacts(role: .author, waitingFor: "Waiting on Maria")
        let raced = Self.service(Self.defaults(), clock: clock)
        Self.tell(raced, [4093: waiting])
        #expect(raced.stage(of: Self.ref(4093))?.stage == .teammateReview)
        clock.advance(seconds: 60)
        Self.tellSession(raced, on: [4093], state: .running, since: clock.now - 120)
        #expect(raced.stage(of: Self.ref(4093))?.stage == .inProgress)
        #expect(Self.why(raced, 4093) == "‘Cart’ is writing it")

        let late = Self.service(Self.defaults(), clock: clock)
        Self.tell(late, [4093: waiting])
        clock.advance(seconds: 660)
        Self.tellSession(late, on: [4093], state: .done, since: clock.now - 900)
        #expect(late.stage(of: Self.ref(4093))?.stage == .teammateReview)

        let known = Self.service(Self.defaults(), clock: clock)
        Self.tellSession(known, on: [4093], state: .done, since: clock.now - 3_600)
        Self.tell(known, [4093: StageFacts(
            role: .author, isApproved: false, approvedBy: "Maria", waitingFor: "1 of 2 approvals", othersVoted: true, votes: "10"
        )])
        #expect(known.stage(of: Self.ref(4093))?.stage == .teammateReview)
        // A push reset the votes, minutes later.
        clock.advance(seconds: 120)
        Self.tell(known, [4093: waiting])
        #expect(known.stage(of: Self.ref(4093))?.stage == .teammateReview)
        #expect(Self.why(known, 4093) == "Waiting on Maria")
    }

    @Test func aSessionAtWorkThenDoneMovesItAsTheCopilotAppTellsIt() {
        let clock = Clock()
        let order = Self.service(Self.defaults(), clock: clock)
        Self.tell(order, [4093: StageFacts(role: .author)])
        Self.tellSession(order, on: [4093], state: .running, since: clock.now)
        #expect(order.stage(of: Self.ref(4093))?.stage == .inProgress)
        #expect(Self.why(order, 4093) == "‘Cart’ is writing it")

        clock.advance(seconds: 600)
        Self.tellSession(order, on: [4093], state: .done, since: clock.now)
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)
        #expect(Self.why(order, 4093) == "‘Cart’ finished")

        // Your Finished My Review stands over it; the session at work on it again only marks it.
        order.finishedReview(Self.ref(4093))
        #expect(order.stage(of: Self.ref(4093))?.stage == .teammateReview)
        clock.advance(seconds: 60)
        Self.tellSession(order, on: [4093], state: .needsYou, since: clock.now)
        #expect(order.stage(of: Self.ref(4093))?.stage == .teammateReview)
        #expect(Self.why(order, 4093) == "Find a reviewer · ‘Cart’ asks you")
    }

    /// VoiceOver hears a failed build after the session that decides its stage, after a pause: in its row, its pill and
    /// its details, in Up Next, and in its mission's chip.
    @Test func voiceOverHearsAFailureAfterTheSessionThatDecides() throws {
        let clock = Clock()
        let order = Self.service(Self.defaults(), clock: clock)
        Self.tell(order, [4093: StageFacts(role: .author, failure: "Build failed")])
        Self.tellSession(order, on: [4093], state: .needsYou, since: clock.now)
        let reading = try #require(order.stage(of: Self.ref(4093)))
        #expect(StageWords.spokenWhy(reading, order: order, now: clock.now) == "Cart asks you, build failed, worked out by BriefBar")
        let board = order.board(kinds: [.pullRequest])
        let slot = try #require(board.upNext.slots.first { $0.card.ref == Self.ref(4093) })
        #expect(slot.kind == .fix)
        #expect(UpNextView.spoken(slot, mission: "Not in a mission", order: order) == "Cart asks you, build failed, Not in a mission")
        let lane = try #require(board.lanes.first { $0.cards.contains { $0.ref == Self.ref(4093) } })
        let step = try #require(lane.nextSteps.first { $0.ref == Self.ref(4093) })
        #expect(step.kind == .answer)
        #expect(MissionNextStepsLine.spoken(step, in: lane, order: order) == "Cart asks you, build failed")
    }

    /// What a mission waits for says a failed build after the session at work on it, and VoiceOver hears it after a pause.
    @Test func whatAMissionWaitsForSaysAFailureAfterTheSessionAtWork() throws {
        let clock = Clock()
        let order = Self.service(Self.defaults(), clock: clock)
        Self.tell(order, [4093: StageFacts(role: .author, failure: "Build failed")])
        Self.tellSession(order, on: [4093], state: .running, since: clock.now)
        let board = order.board(kinds: [.pullRequest])
        let lane = try #require(board.lanes.first { $0.cards.contains { $0.ref == Self.ref(4093) } })
        #expect(lane.nextSteps.isEmpty)
        #expect(lane.waiting(name: order.name(of:)) == "‘Cart’ is writing it · build failed (!4093)")
        #expect(MissionNextStepsLine.spokenWaiting(lane, order: order) == "Cart is writing it, build failed (!4093)")
    }

    /// A stage you set keeps of what it was set over only what would end it: In progress, the commit; Your review,
    /// nothing; Teammate's review, the votes, and on someone else's the commit too. So your own vote on someone else's is
    /// kept only once you finished reviewing it.
    @Test func aStageYouSetKeepsOnlyWhatWouldEndIt() throws {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [
            4093: StageFacts(role: .author, votes: "10", commit: "c4093"),
            4110: StageFacts(role: .reviewer, votes: "-5", commit: "c4110"),
        ])
        /// What BriefBar's preferences keep with its stage: its votes and its commit.
        func kept(_ number: Int) throws -> [String?] {
            let mark = try #require(StageMarks.load(from: defaults).mark(of: Self.ref(number), for: Self.account))
            return [mark.votes, mark.commit]
        }
        #expect(order.setStage(.inProgress, of: Self.ref(4110)) == .done)
        #expect(try kept(4110) == [nil, "c4110"])
        #expect(order.setStage(.yourReview, of: Self.ref(4110)) == .done)
        #expect(try kept(4110) == [nil, nil])
        #expect(order.finishedReview(Self.ref(4110)) == .done)
        #expect(try kept(4110) == ["-5", "c4110"])
        #expect(order.setStage(.inProgress, of: Self.ref(4093)) == .done)
        #expect(try kept(4093) == [nil, "c4093"])
        #expect(order.setStage(.yourReview, of: Self.ref(4093)) == .done)
        #expect(try kept(4093) == [nil, nil])
        #expect(order.finishedReview(Self.ref(4093)) == .done)
        #expect(try kept(4093) == ["10", nil])
    }

    /// A task BriefBar sent that you went on with in the Copilot app does what the app says since: at work again after
    /// it finished, it's writing it, in Your review still, where it got. A pre-review stays a review, so someone else's
    /// stays yours to review.
    @Test func aTaskYouWentOnWithInTheCopilotAppDoesWhatTheAppSays() {
        let clock = Clock()
        let order = Self.service(Self.defaults(), clock: clock)
        let task = StageSession(ref: Self.cart, activity: .finished, since: clock.now, name: "Copilot")
        Self.tell(order, [4093: StageFacts(role: .author, sessions: [task])])
        #expect(Self.why(order, 4093) == "Copilot finished")

        clock.advance(seconds: 300)
        Self.tellSession(order, on: [4093], state: .running, since: clock.now, activity: .working)
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)
        #expect(Self.why(order, 4093) == "Waiting for your review · Copilot is writing it")

        let review = StageSession(ref: Self.cart, activity: .finished, since: clock.now, name: "Copilot", isReview: true)
        Self.tell(order, [4110: StageFacts(role: .reviewer, asksYou: "Jordan asked you", sessions: [review])])
        clock.advance(seconds: 300)
        Self.tellSession(order, on: [4110], state: .running, since: clock.now, activity: .working)
        #expect(order.stage(of: Self.ref(4110))?.stage == .yourReview)
        #expect(Self.why(order, 4110) == "Copilot is pre-reviewing it")
    }

    /// Choosing the stage it's in, in its menu, sets it as yours, so one BriefBar decided stays there until you change it:
    /// someone else's you're asked to review stays yours to review once you've voted.
    @Test func choosingTheStageItsInInItsMenuMakesItYours() throws {
        let order = Self.service(Self.defaults())
        Self.tell(order, [4110: StageFacts(role: .reviewer, asksYou: "Jordan asked you", votes: "0")])
        let reading = try #require(order.stage(of: Self.ref(4110)))
        #expect(reading.stage == .yourReview)
        #expect(!reading.isSetByYou)
        let checked = StageMenuItems.choice(.yourReview, of: Self.ref(4110), reading: reading, order: order)
        #expect(checked.wrappedValue)
        checked.wrappedValue = false
        #expect(order.stage(of: Self.ref(4110))?.isSetByYou == true)

        Self.tell(order, [4110: StageFacts(role: .reviewer, votes: "10")])
        #expect(order.stage(of: Self.ref(4110))?.stage == .yourReview)
    }

    @Test func readyItWaitsForWhatItsOrderPutsFirstUntilBriefBarSeesItMerge() throws {
        let defaults = Self.defaults()
        var orders = DeclaredOrders()
        try orders.apply(
            OrderRequest(entries: [
                .init(link: "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/4101"),
                .init(link: "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/4102", after: ["4101"]),
            ]),
            now: Date(timeIntervalSince1970: 1_791_900_000)
        )
        orders.save(to: defaults)
        let order = Self.service(defaults)
        let ready = StageFacts(role: .author, isReady: true, othersVoted: true)
        Self.tell(order, [4101: StageFacts(role: .author), 4102: ready])
        #expect(order.stage(of: Self.ref(4102))?.stage == .waits)
        #expect(Self.why(order, 4102) == "After !4101")

        Self.tell(order, [4101: StageFacts(role: .author, state: .merged), 4102: ready], states: [4101: .merged])
        #expect(order.stage(of: Self.ref(4102))?.stage == .canMerge)
    }

    @Test func turningAzureDevOpsOffForgetsItsStagesEvenWhileOrderIsOff() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4093: StageFacts(role: .author)])
        order.setStage(.yourReview, of: Self.ref(4093))
        order.setOn(false)
        #expect(defaults.object(forKey: StageMarks.defaultsKey) != nil)

        order.forget(.github)
        #expect(defaults.object(forKey: StageMarks.defaultsKey) != nil)
        order.forget(.azureDevOps)
        #expect(defaults.object(forKey: StageMarks.defaultsKey) == nil)
    }

    @Test func offKeepsThemAndForgetStagesForgetsThem() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4093: StageFacts(role: .author)])
        order.setStage(.yourReview, of: Self.ref(4093))
        order.setOn(false)
        #expect(order.keepsStages)
        order.setOn(true)
        Self.tell(order, [4093: StageFacts(role: .author)])
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)

        order.forgetStages()
        #expect(!order.keepsStages)
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)
    }

    /// Turning Pull Request Order off keeps the stages you set in memory too, unused; once it's on again, another
    /// account still forgets them, as signing in with another while it was off does.
    @Test func offKeepsThoseInMemoryTooUntilAnotherAccountSignsIn() {
        let order = Self.service(Self.defaults())
        Self.tell(order, [4113: StageFacts(role: .sentToYou)])
        #expect(order.setStage(.yourReview, of: Self.ref(4113)) == .done)
        order.setOn(false)
        #expect(order.keepsStages)
        order.setOn(true)
        Self.tell(order, [4113: StageFacts(role: .sentToYou)])
        #expect(order.stage(of: Self.ref(4113))?.isSetByYou == true)

        order.setOn(false)
        order.setOn(true)
        Self.tell(order, [4113: StageFacts(role: .sentToYou)], account: "robin@fabrikam.com")
        #expect(order.stage(of: Self.ref(4113))?.isSetByYou != true)
        #expect(!order.keepsStages)
    }

    @Test func oneNoListHasHadFor30DaysGoes() {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        Self.tell(order, [4093: StageFacts(role: .author), 4094: StageFacts(role: .author)])
        order.setStage(.yourReview, of: Self.ref(4093))
        order.setStage(.yourReview, of: Self.ref(4094))

        // Listed now and then, 4094 stays; no longer listed, 4093 goes after 30 days.
        for _ in 0..<31 {
            clock.advance(days: 1)
            Self.tell(order, [4094: StageFacts(role: .author)])
            order.timePassed()
        }
        let kept = StageMarks.load(from: defaults)
        #expect(kept.mark(of: Self.ref(4093), for: Self.account) == nil)
        #expect(kept.mark(of: Self.ref(4094), for: Self.account) != nil)
    }

    /// One kept in memory, sent to you in a chat, goes too once no list has had it for 30 days, rather than coming back
    /// when it's sent to you again; one a list still has stays.
    @Test func oneInMemoryNoListHasHadFor30DaysGoesToo() {
        let clock = Clock()
        let order = Self.service(Self.defaults(), clock: clock)
        Self.tell(order, [4113: StageFacts(role: .sentToYou), 4114: StageFacts(role: .sentToYou)])
        order.setStage(.yourReview, of: Self.ref(4113))
        order.setStage(.yourReview, of: Self.ref(4114))

        for _ in 0..<31 {
            clock.advance(days: 1)
            Self.tell(order, [4114: StageFacts(role: .sentToYou)])
            order.timePassed()
        }
        Self.tell(order, [4113: StageFacts(role: .sentToYou), 4114: StageFacts(role: .sentToYou)])
        #expect(order.stage(of: Self.ref(4113))?.isSetByYou != true)
        #expect(order.stage(of: Self.ref(4114))?.isSetByYou == true)
        #expect(order.keptStagesCount == 1)
    }

    /// Back after five weeks, the stages you set wait until Azure DevOps has listed what it shows, as when the Azure CLI
    /// wants you to sign in again: the clock can look first, and no list could note yet that it has them. Once the lists are
    /// read, one they have stays, and one they don't goes at the clock's next look.
    @Test func aMonthAwayForgetsNoStageYouSetBeforeTheListsAreRead() {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        Self.tell(order, [4093: StageFacts(role: .author), 4094: StageFacts(role: .author)])
        order.setStage(.yourReview, of: Self.ref(4093))
        order.setStage(.yourReview, of: Self.ref(4094))

        clock.advance(days: 35)
        let again = Self.service(defaults, clock: clock)
        Self.tell(again, [:], listed: false)
        clock.advance(days: 1)
        again.timePassed()
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4093), for: Self.account) != nil)
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4094), for: Self.account) != nil)

        Self.tell(again, [4094: StageFacts(role: .author)])
        again.timePassed()
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4093), for: Self.account) == nil)
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4094), for: Self.account) != nil)
        #expect(again.stage(of: Self.ref(4094))?.isSetByYou == true)
    }

    /// So does one kept in memory, sent to you in a chat, once Pull Request Order was off for a month, as it was till
    /// Azure DevOps lists what it shows again.
    @Test func aMonthOffForgetsNoStageInMemoryBeforeTheListsAreRead() {
        let clock = Clock()
        let order = Self.service(Self.defaults(), clock: clock)
        Self.tell(order, [4113: StageFacts(role: .sentToYou), 4114: StageFacts(role: .sentToYou)])
        order.setStage(.yourReview, of: Self.ref(4113))
        order.setStage(.yourReview, of: Self.ref(4114))

        order.setOn(false)
        clock.advance(days: 35)
        order.setOn(true)
        Self.tell(order, [:], listed: false)
        order.timePassed()
        #expect(order.keptStagesCount == 2)

        Self.tell(order, [4114: StageFacts(role: .sentToYou)])
        order.timePassed()
        #expect(order.keptStagesCount == 1)
        #expect(order.stage(of: Self.ref(4114))?.isSetByYou == true)
    }

    /// A stage you set keeps when a list last had its pull request as it moves between memory and the preferences,
    /// either way, so it still goes 30 days after that.
    @Test func movingBetweenMemoryAndThePreferencesKeepsWhenAListLastHadIt() {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        Self.tell(order, [4113: StageFacts(role: .watching)])
        order.setStage(.yourReview, of: Self.ref(4113))
        Self.tell(order, [4093: StageFacts(role: .author)], account: nil)
        order.setStage(.yourReview, of: Self.ref(4093))

        // 20 days on, no list has either: BriefBar knows the account of one, and the other was only sent to you.
        clock.advance(days: 20)
        Self.tell(order, [
            4093: StageFacts(role: .author, isListed: false), 4113: StageFacts(role: .sentToYou, isListed: false),
        ])
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4093), for: Self.account) != nil)
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4113), for: Self.account) == nil)
        #expect(order.keptStagesCount == 2)

        clock.advance(days: 11)
        order.timePassed()
        #expect(order.keptStagesCount == 0)
    }

    /// Missions draw each pull request in its stage's color, and one BriefBar saw merge in Merged's where its source tells
    /// stages, listed or not; GitHub's, which tells none, as they were.
    @Test func theGraphTakesStagesColorsAndMergedsWhereTheSourceTellsStages() {
        let order = Self.service(Self.defaults())
        let merged = OrderStep(ref: Self.ref(4074), status: .merged, standing: .merged)
        let onGitHub = OrderStep(ref: .gitHubPullRequest(repository: "contoso/shop-web", number: 412), status: .merged, standing: .merged)
        #expect(order.drawnStage(of: merged) == nil)

        Self.tell(order, [4093: StageFacts(role: .author)])
        #expect(order.drawnStage(of: OrderStep(ref: Self.ref(4093), status: .open, standing: .next)) == .teammateReview)
        #expect(order.drawnStage(of: merged) == .merged)
        #expect(order.drawnStage(of: onGitHub) == nil)
        #expect(order.drawnStage(of: OrderStep(ref: Self.ref(4120), status: .open, standing: .anyTime)) == nil)

        order.setOn(false)
        #expect(order.drawnStage(of: merged) == nil)
    }

    /// One you watch keeps the stage you set in the preferences, as what you've seen of it is kept; one only sent to you
    /// keeps it in memory.
    @Test func oneYouWatchKeepsItsStageInThePreferences() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4113: StageFacts(role: .watching), 4114: StageFacts(role: .sentToYou)])

        #expect(order.setStage(.yourReview, of: Self.ref(4113)) == .done)
        #expect(order.setStage(.yourReview, of: Self.ref(4114)) == .done)
        let kept = StageMarks.load(from: defaults)
        #expect(kept.mark(of: Self.ref(4113), for: Self.account)?.stage == .yourReview)
        #expect(kept.mark(of: Self.ref(4114), for: Self.account) == nil)
        #expect(order.stage(of: Self.ref(4114))?.stage == .yourReview)
    }

    /// The demo sets its stages as you would have, once their pull requests are listed, holding as they are now; never
    /// outside the demo, and not over one you set.
    @Test func theDemoSetsItsStagesOnceTheirPullRequestsAreListed() {
        let clock = Clock()
        let demo = PullRequestOrder(defaults: Self.defaults(), isDemo: true, now: { clock.now })
        let earlier = clock.now.addingTimeInterval(-2 * 3_600)
        let stages = [Self.ref(4105): StageMark(stage: .teammateReview, at: earlier), Self.ref(4106): StageMark(stage: .yourReview, at: earlier)]
        demo.tellDemo(stages: stages)
        #expect(demo.stages.isEmpty)

        Self.tell(demo, [4105: StageFacts(role: .author, votes: "0", commit: "c4105"), 4106: StageFacts(role: .author)])
        demo.setStage(.inProgress, of: Self.ref(4106))
        demo.tellDemo(stages: stages)
        let reading = demo.stage(of: Self.ref(4105))
        #expect(reading?.stage == .teammateReview && reading?.why == .findReviewer)
        #expect(reading?.mark?.at == earlier && reading?.mark?.votes == "0" && reading?.mark?.commit == nil)
        #expect(demo.stage(of: Self.ref(4106))?.stage == .inProgress)

        let real = Self.service(Self.defaults())
        Self.tell(real, [4105: StageFacts(role: .author)])
        real.tellDemo(stages: stages)
        #expect(real.stage(of: Self.ref(4105))?.mark == nil)
    }

    // MARK: From Copilot's review

    /// A draft keeps nothing of how far it got, even one in Your review as the session that wrote it finished: once it's a
    /// draft again, what was kept goes; published, where it goes starts again from what Azure DevOps and Copilot say.
    @Test func aDraftKeepsNothingOfHowFarItGot() {
        let clock = Clock()
        let defaults = Self.defaults()
        let order = Self.service(defaults, clock: clock)
        func reached() -> PullRequestStage? {
            StagesReached.load(from: defaults).reach(of: Self.ref(4093), for: Self.account, at: clock.now)?.stage
        }
        Self.tell(order, [4093: StageFacts(role: .author)])
        clock.advance(seconds: 60)
        Self.tellSession(order, on: [4093], state: nil, since: clock.now, activity: .finished)
        #expect(order.stage(of: Self.ref(4093))?.stage == .teammateReview)
        #expect(reached() == .teammateReview)

        Self.tell(order, [4093: StageFacts(role: .author, state: .draft)], states: [4093: .draft])
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)
        #expect(reached() == nil)

        Self.tell(order, [4093: StageFacts(role: .author)])
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)
        #expect(reached() == .yourReview)
    }

    /// Where BriefBar first saw one stops being that once a stage set on it ends, as that moved it: a session the Copilot
    /// app tells of next, done before BriefBar first saw it, doesn't take it from your teammates back to your review.
    @Test func aStageSetThatEndedMovedItFromWhereBriefBarFirstSawIt() {
        let clock = Clock()
        let order = Self.service(Self.defaults(), clock: clock)
        let first = clock.now
        Self.tell(order, [4093: StageFacts(role: .author, waitingFor: "Waiting on Maria")])
        #expect(order.setStage(.yourReview, of: Self.ref(4093)) == .done)
        #expect(order.finishedReview(Self.ref(4093)) == .done)
        clock.advance(seconds: 60)
        Self.tell(order, [4093: StageFacts(
            role: .author, changesWanted: "Maria wants changes", waitingFor: "Waiting on Maria", othersVoted: true, votes: "-5"
        )])
        #expect(order.stage(of: Self.ref(4093))?.mark == nil)
        #expect(order.stage(of: Self.ref(4093))?.stage == .teammateReview)

        clock.advance(seconds: 60)
        Self.tellSession(order, on: [4093], state: .done, since: first - 120)
        #expect(order.stage(of: Self.ref(4093))?.stage == .teammateReview)
        #expect(Self.why(order, 4093) == "Waiting on Maria · Maria wants changes")
    }

    /// Your review's time is when it got there, as its stage said then, not when BriefBar noted it: one whose session
    /// finished long before BriefBar heard of it keeps how long it has waited for your review once that session writes
    /// it again, and so its place in Your review's order.
    @Test func yourReviewWaitsFromWhenItGotThereNotFromWhenBriefBarNotedIt() {
        let clock = Clock()
        let order = Self.service(Self.defaults(), clock: clock)
        let finished = clock.now - 7_200
        Self.tell(order, [4093: StageFacts(role: .author, waitingFor: "Waiting on Maria")])
        clock.advance(seconds: 60)
        Self.tellSession(order, on: [4093], state: .done, since: finished)
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)
        #expect(order.stage(of: Self.ref(4093))?.since == finished)

        clock.advance(seconds: 60)
        Self.tellSession(order, on: [4093], state: .running, since: clock.now)
        #expect(order.stage(of: Self.ref(4093))?.stage == .yourReview)
        #expect(Self.why(order, 4093) == "Waiting for your review · ‘Cart’ is writing it")
        #expect(order.stage(of: Self.ref(4093))?.since == finished)
    }

    /// Forget Stages… is there for how far yours got while Pull Request Order is off, when nothing else forgets it: while
    /// it's on, BriefBar keeps that again at once, or forgets it on its own after 30 days.
    @Test func forgetStagesIsThereForHowFarYoursGotWhileOrderIsOff() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4093: StageFacts(role: .author)])
        #expect(defaults.object(forKey: StagesReached.defaultsKey) != nil)
        #expect(!order.keepsStages)

        order.setOn(false)
        #expect(order.keepsStages)
        order.forgetStages()
        #expect(defaults.object(forKey: StagesReached.defaultsKey) == nil)
        #expect(!order.keepsStages)

        order.setOn(true)
        Self.tell(order, [4093: StageFacts(role: .author)])
        #expect(defaults.object(forKey: StagesReached.defaultsKey) != nil)
        #expect(!order.keepsStages)
    }

    /// A session that ended, then went idle, counts as finished only when its source says its last turn finished: one that
    /// was interrupted or failed, or whose end BriefBar can't tell, says nothing of its pull request, and ends no In progress
    /// you set.
    @Test func anIdleSessionCountsAsFinishedOnlyWhenItsSourceSaysSo() {
        let clock = Clock()
        let order = Self.service(Self.defaults(), clock: clock)
        Self.tell(order, [4093: StageFacts(role: .author)])
        Self.tellSession(order, on: [4093], state: nil, since: clock.now, activity: .stopped)
        #expect(Self.why(order, 4093) == "Find a reviewer")
        Self.tellSession(order, on: [4093], state: nil, since: clock.now)
        #expect(Self.why(order, 4093) == "Find a reviewer")
        Self.tellSession(order, on: [4093], state: nil, since: clock.now, activity: .finished)
        #expect(Self.why(order, 4093) == "‘Cart’ finished")

        // A set In progress ends only once a session finishes after it.
        clock.advance(seconds: 60)
        order.setStage(.inProgress, of: Self.ref(4093))
        clock.advance(seconds: 60)
        Self.tellSession(order, on: [4093], state: nil, since: clock.now, activity: .stopped)
        #expect(order.stage(of: Self.ref(4093))?.isSetByYou == true)
        Self.tellSession(order, on: [4093], state: nil, since: clock.now, activity: .finished)
        #expect(order.stage(of: Self.ref(4093))?.isSetByYou == false)
    }

    /// The stages you set that BriefBar keeps in memory, and Undo, are the account's that set them: once another account
    /// signs in, they go, rather than show or be saved as that account's. Before BriefBar knew any account, they stay, and
    /// are saved with the first it learns.
    @Test func anotherAccountForgetsTheStagesInMemoryAndUndo() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4113: StageFacts(role: .sentToYou), 4093: StageFacts(role: .author)])
        #expect(order.setStage(.yourReview, of: Self.ref(4113)) == .done)
        #expect(order.lastStageChange?.ref == Self.ref(4113))

        Self.tell(order, [4113: StageFacts(role: .sentToYou), 4093: StageFacts(role: .author)], account: "robin@fabrikam.com")
        #expect(order.stage(of: Self.ref(4113))?.mark == nil)
        #expect(order.lastStageChange == nil)
        Self.tell(order, [4113: StageFacts(role: .sentToYou), 4093: StageFacts(role: .author)])
        #expect(order.stage(of: Self.ref(4113))?.mark == nil)

        // Signed out between them is the same as another.
        #expect(order.setStage(.yourReview, of: Self.ref(4113)) == .done)
        Self.tell(order, [4113: StageFacts(role: .sentToYou)], account: nil)
        Self.tell(order, [4113: StageFacts(role: .sentToYou)], account: "robin@fabrikam.com")
        #expect(order.stage(of: Self.ref(4113))?.mark == nil)

        // Undo of a stage saved with one account doesn't touch another's.
        Self.tell(order, [4093: StageFacts(role: .author)])
        order.setStage(.inProgress, of: Self.ref(4093))
        Self.tell(order, [4093: StageFacts(role: .author)], account: "robin@fabrikam.com")
        order.setStage(.yourReview, of: Self.ref(4093))
        Self.tell(order, [4093: StageFacts(role: .author)])
        #expect(order.lastStageChange == nil)
        order.undo()
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4093), for: "robin@fabrikam.com")?.stage == .yourReview)
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4093), for: Self.account)?.stage == .inProgress)
    }

    /// Once you stop watching one that was also sent to you in a chat, the stage you set stays, in memory, and leaves the
    /// preferences, as what you've seen of it does.
    @Test func oneYouStopWatchingKeepsItsStageInMemoryOnly() {
        let defaults = Self.defaults()
        let order = Self.service(defaults)
        Self.tell(order, [4113: StageFacts(role: .watching)])
        order.setStage(.yourReview, of: Self.ref(4113))
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4113), for: Self.account) != nil)

        Self.tell(order, [4113: StageFacts(role: .sentToYou)])
        #expect(order.stage(of: Self.ref(4113))?.stage == .yourReview)
        #expect(order.stage(of: Self.ref(4113))?.isSetByYou == true)
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4113), for: Self.account) == nil)

        // Watched again, it's kept again.
        Self.tell(order, [4113: StageFacts(role: .watching)])
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4113), for: Self.account)?.stage == .yourReview)
    }

    /// The most an account keeps counts those in memory too, so that one kept there is kept with the account once you
    /// watch it; one you set already can still change.
    @Test func theMostAnAccountKeepsCountsThoseInMemory() {
        let clock = Clock()
        let defaults = Self.defaults()
        var full = StageMarks()
        for number in 1..<StageMarks.mostPerAccount {
            _ = full.set(StageMark(stage: .yourReview, at: clock.now), of: Self.ref(number), for: Self.account, at: clock.now)
        }
        full.save(to: defaults)
        let order = Self.service(defaults, clock: clock)
        Self.tell(order, [4093: StageFacts(role: .author), 4113: StageFacts(role: .sentToYou), 4114: StageFacts(role: .sentToYou)])
        #expect(order.setStage(.yourReview, of: Self.ref(4113)) == .done)

        // That's the most: a new one is refused, in memory or with the account.
        let refused = StageChange.Outcome.refused(
            "BriefBar keeps up to \(StageMarks.mostPerAccount) stages you set. Let BriefBar decide one you no longer need first."
        )
        #expect(order.setStage(.yourReview, of: Self.ref(4114)) == refused)
        #expect(order.setStage(.inProgress, of: Self.ref(4093)) == refused)
        #expect(order.setStage(.inProgress, of: Self.ref(4113)) == .done)

        // Watched now, it's kept with the account.
        Self.tell(order, [4093: StageFacts(role: .author), 4113: StageFacts(role: .watching), 4114: StageFacts(role: .sentToYou)])
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4113), for: Self.account)?.stage == .inProgress)
        #expect(order.keptStagesCount == StageMarks.mostPerAccount)
    }

    /// One you set before BriefBar knew the account, which keeps the most by then, waits in memory, where you can still
    /// change it, and is kept with the account once it has room. Undo of what made that room puts back what it forgot,
    /// which waits in memory in turn.
    @Test func oneSetBeforeBriefBarKnewAFullAccountWaitsInMemoryForRoom() {
        let clock = Clock()
        let defaults = Self.defaults()
        var full = StageMarks()
        for number in 1...StageMarks.mostPerAccount {
            _ = full.set(StageMark(stage: .yourReview, at: clock.now), of: Self.ref(number), for: Self.account, at: clock.now)
        }
        full.save(to: defaults)
        let order = Self.service(defaults, clock: clock)
        Self.tell(order, [1: StageFacts(role: .author), 4093: StageFacts(role: .author)], account: nil)
        #expect(order.setStage(.yourReview, of: Self.ref(4093)) == .done)
        Self.tell(order, [1: StageFacts(role: .author), 4093: StageFacts(role: .author)])
        #expect(order.stage(of: Self.ref(4093))?.isSetByYou == true)
        #expect(order.setStage(.inProgress, of: Self.ref(4093)) == .done)
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4093), for: Self.account) == nil)

        order.letBriefBarDecide(Self.ref(1))
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(4093), for: Self.account)?.stage == .inProgress)

        order.undo()
        #expect(order.stage(of: Self.ref(1))?.stage == .yourReview)
        #expect(order.stage(of: Self.ref(1))?.isSetByYou == true)
        #expect(StageMarks.load(from: defaults).mark(of: Self.ref(1), for: Self.account) == nil)
    }

    /// A merged or closed pull request's stage doesn't change: nothing is kept, and Undo has nothing to undo.
    @Test func aMergedOrClosedOnesStageCantBeSet() {
        let order = Self.service(Self.defaults())
        Self.tell(order, [4085: StageFacts(role: .author, state: .merged), 4086: StageFacts(role: .author, state: .closed)])
        #expect(order.setStage(.yourReview, of: Self.ref(4085)) == .refused("It merged: its stage doesn't change now"))
        #expect(order.setStage(.inProgress, of: Self.ref(4086)) == .refused("It's closed: its stage doesn't change now"))
        #expect(order.lastStageChange == nil)
        #expect(order.stage(of: Self.ref(4085))?.stage == .merged)
        #expect(!order.offersStageMenu(for: Self.ref(4085)))
        #expect(!order.offersStageMenu(for: Self.ref(4086)))
    }

    /// Once your change leaves someone else's without a stage, Undo stays, and its row's Stage menu with it, so you can undo
    /// it where you did it: say you set In progress on one you help with, then approved it in Azure DevOps, so it asks
    /// nothing of you, and let BriefBar decide.
    @Test func undoStaysOnceYourChangeLeavesItWithoutAStage() {
        let order = Self.service(Self.defaults())
        Self.tell(order, [4110: StageFacts(role: .reviewer, asksYou: "Jordan asked you", votes: "0")])
        order.setStage(.inProgress, of: Self.ref(4110))
        // Your vote ends no In progress you set.
        Self.tell(order, [4110: StageFacts(role: .reviewer, votes: "10")])
        #expect(order.stage(of: Self.ref(4110))?.isSetByYou == true)
        #expect(order.letBriefBarDecide(Self.ref(4110)) == .done)
        #expect(order.stage(of: Self.ref(4110)) == nil)
        #expect(order.offersStageMenu(for: Self.ref(4110)))
        #expect(StageAction.offered(for: order.stage(of: Self.ref(4110)), canUndo: order.lastStageChange?.ref == Self.ref(4110)) == [.undo])

        order.undo()
        #expect(order.stage(of: Self.ref(4110))?.stage == .inProgress)
        #expect(order.offersStageMenu(for: Self.ref(4110)))
        order.dismissLastChange()
        Self.tell(order, [4111: StageFacts(role: .reviewer)])
        #expect(!order.offersStageMenu(for: Self.ref(4111)))
    }

    /// One its source still reads but no list has, such as one sent to you in a chat once you answered it, shows no stage,
    /// on the Board or Up Next either, and can't be set; what you set on it stays, and still ends as it moves on.
    @Test func oneNoListHasShowsNoStageButWhatYouSetStillEnds() {
        let order = Self.service(Self.defaults())
        Self.tell(order, [4113: StageFacts(role: .sentToYou, asksYou: "Dana sent it in Teams", commit: "c1")])
        order.setStage(.inProgress, of: Self.ref(4113))
        #expect(order.board(kinds: [.pullRequest]).refs == [Self.ref(4113)])

        Self.tell(order, [4113: StageFacts(role: .sentToYou, commit: "c1", isListed: false)])
        #expect(order.stage(of: Self.ref(4113)) == nil)
        #expect(order.board(kinds: [.pullRequest]).refs.isEmpty)
        #expect(order.setStage(.yourReview, of: Self.ref(4113)) == .refused("BriefBar doesn't list that pull request now"))
        Self.tell(order, [4113: StageFacts(role: .sentToYou, asksYou: "Dana sent it in Teams", commit: "c1")])
        #expect(order.stage(of: Self.ref(4113))?.isSetByYou == true)

        // New commits while no list had it end it all the same.
        Self.tell(order, [4113: StageFacts(role: .sentToYou, commit: "c1", isListed: false)])
        Self.tell(order, [4113: StageFacts(role: .sentToYou, commit: "c2", isListed: false)])
        Self.tell(order, [4113: StageFacts(role: .sentToYou, asksYou: "Dana sent it in Teams", commit: "c2")])
        #expect(order.stage(of: Self.ref(4113))?.isSetByYou == false)
    }
}
