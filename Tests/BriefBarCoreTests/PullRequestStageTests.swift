import Foundation
import Testing
@testable import BriefBarCore

/// A pull request's stage: each of the plan's rules (§2.2), the user's three examples, the latest change winning, how a
/// stage you set ends, what its order says of merging it, and the words.
@Suite struct PullRequestStageTests {
    static func pr(_ number: Int) -> ItemRef { OrderPlansTests.pr(number) }
    static let cart = ItemRef.session("7c1e2a90-4b3d-4f5e-8a6b-1c2d3e4f5a6b")!
    static let backoff = ItemRef.session("2b8d4f60-9a1c-4e3b-b7d5-6f8e9a0b1c2d")!

    static func name(_ ref: ItemRef) -> String? {
        switch ref {
        case cart: "Cart"
        case backoff: "Retry backoff"
        default: nil
        }
    }

    static func session(_ activity: StageSession.Activity, at seconds: TimeInterval, _ ref: ItemRef = cart) -> StageSession {
        StageSession(ref: ref, activity: activity, since: t(seconds))
    }

    static func reading(
        _ facts: StageFacts, sessions: [StageSession] = [], marks: [StageMark] = [], order: StageOrder = .free
    ) -> StageReading? {
        StageRules.reading(facts: facts, sessions: sessions, marks: marks, order: order)
    }

    static func why(_ reading: StageReading?) -> String? {
        reading.map { StageText.why($0, name: name) }
    }

    // MARK: Each rule, in turn

    @Test func mergedComesFirstAndClosedIsntOnTheBoard() {
        let merged = Self.reading(
            StageFacts(role: .author, state: .merged, failure: "Build failed", since: t(50)),
            sessions: [Self.session(.working, at: 10)]
        )
        #expect(merged?.stage == .merged)
        #expect(merged?.since == t(50))
        #expect(Self.reading(StageFacts(role: .author, state: .closed)) == nil)
    }

    @Test func aSessionAtWorkPutsItInProgressAndOneWaitingForYouAsks() {
        let failing = StageFacts(role: .author, failure: "Build failed")
        let working = Self.reading(failing, sessions: [Self.session(.working, at: 10)])
        #expect(working?.stage == .inProgress)
        #expect(Self.why(working) == "‘Cart’ is writing it")
        #expect(working?.since == t(10))

        let asking = Self.reading(
            failing, sessions: [Self.session(.working, at: 30, Self.backoff), Self.session(.waitsForYou, at: 20)]
        )
        #expect(Self.why(asking) == "‘Cart’ asks you")

        // A task BriefBar sent, which the sources don't name, has its own.
        let task = StageSession(ref: .session("9e8d7c6b-5a49-4382-a1b0-c9d8e7f6a5b4")!, activity: .working, since: t(5), name: "Copilot")
        #expect(Self.why(Self.reading(failing, sessions: [task])) == "Copilot is writing it")
        // One the sources can't name.
        let unnamed = StageSession(ref: .session("0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!, activity: .working, since: t(5))
        #expect(Self.why(Self.reading(failing, sessions: [unnamed])) == "A Copilot session is writing it")
    }

    @Test func aStageYouSetShowsUntilASessionStartsAfterIt() {
        let facts = StageFacts(role: .author, waitingFor: "Waiting on Priya")
        let set = StageMark(stage: .yourReview, at: t(100))

        let before = Self.reading(facts, sessions: [Self.session(.working, at: 50)], marks: [set])
        #expect(before?.stage == .yourReview)
        #expect(before?.mark == set)
        #expect(Self.why(before) == "Waiting for your review")

        let after = Self.reading(facts, sessions: [Self.session(.working, at: 150)], marks: [set])
        #expect(after?.stage == .inProgress)
        #expect(after?.mark == nil)

        // Once it's no longer at work, what you set shows again.
        #expect(Self.reading(facts, sessions: [Self.session(.waitsForYou, at: 150)], marks: [set])?.stage == .inProgress)
        // A session whose start BriefBar doesn't know leaves it.
        let unknown = StageSession(ref: Self.cart, activity: .working, since: nil)
        #expect(Self.reading(facts, sessions: [unknown], marks: [set])?.stage == .yourReview)
    }

    @Test func whatFailsThenWhatsWantedPutYoursInProgress() {
        let both = StageFacts(role: .author, failure: "Merge conflicts", changesWanted: "Priya wants changes", isReady: true)
        #expect(Self.reading(both)?.stage == .inProgress)
        #expect(Self.why(Self.reading(both)) == "Merge conflicts")
        let wanted = StageFacts(role: .author, changesWanted: "Priya wants changes", othersVoted: true)
        #expect(Self.why(Self.reading(wanted, sessions: [Self.session(.finished, at: 10)])) == "Priya wants changes")
    }

    @Test func someoneElsesWaitsForYourReviewWhileTheyAskYou() {
        let asked = Self.reading(StageFacts(role: .reviewer, asksYou: "Sam asked you", since: t(20)))
        #expect(asked?.stage == .yourReview)
        #expect(Self.why(asked) == "Sam asked you")
        #expect(asked?.since == t(20))
        #expect(Self.why(Self.reading(StageFacts(role: .sentToYou, asksYou: "Priya sent it in Teams"))) == "Priya sent it in Teams")
        // Not a draft, nor one you approved, nor one sent to you that no longer needs you.
        #expect(Self.reading(StageFacts(role: .reviewer, state: .draft, asksYou: "Sam asked you")) == nil)
        #expect(Self.reading(StageFacts(role: .reviewer)) == nil)
        #expect(Self.reading(StageFacts(role: .sentToYou)) == nil)
        // One you asked for changes waits for its author.
        let changes = Self.reading(StageFacts(role: .reviewer, youWantChanges: "Waiting for Sam's changes"))
        #expect(changes?.stage == .inProgress)
        #expect(Self.why(changes) == "Waiting for Sam's changes")
    }

    @Test func yoursIsYourReviewOnceItsSessionFinishedAndNobodyElseVoted() {
        let finished = Self.reading(
            StageFacts(role: .author, state: .draft, waitingFor: "Waiting on Priya"),
            sessions: [Self.session(.finished, at: 40, Self.backoff), Self.session(.finished, at: 60), Self.session(.stopped, at: 90)]
        )
        #expect(finished?.stage == .yourReview)
        #expect(Self.why(finished) == "‘Cart’ finished")
        #expect(finished?.since == t(60))

        // Once someone else voted, it's theirs: a draft is still in progress, else it waits for them.
        let voted = StageFacts(role: .author, waitingFor: "Waiting on Priya", othersVoted: true)
        #expect(Self.reading(voted, sessions: [Self.session(.finished, at: 60)])?.stage == .teammateReview)
        // A session that stopped before it was done doesn't make it yours to review.
        #expect(Self.reading(StageFacts(role: .author), sessions: [Self.session(.stopped, at: 60)])?.stage == .teammateReview)
    }

    @Test func aDraftOfYoursIsInProgress() {
        let draft = Self.reading(StageFacts(role: .author, state: .draft))
        #expect(draft?.stage == .inProgress)
        #expect(Self.why(draft) == "Draft")
    }

    @Test func readyItCanMergeUnlessItsOrderHoldsIt() {
        let ready = StageFacts(role: .author, isReady: true, othersVoted: true)
        #expect(Self.reading(ready)?.stage == .canMerge)
        #expect(Self.why(Self.reading(ready)) == "Complete it")
        var auto = ready
        auto.autoComplete = true
        #expect(Self.why(Self.reading(auto)) == "Completing automatically")

        let waits = Self.reading(ready, order: .waits([Self.pr(4102)], words: "After !4102 · stacked"))
        #expect(waits?.stage == .waits)
        #expect(waits?.why == .waitsFor([Self.pr(4102)], words: "After !4102 · stacked"))
        #expect(Self.why(waits) == "After !4102 · stacked")

        let holds = Self.reading(ready, order: .holds("!4102 was closed without merging: check the order"))
        #expect(holds?.stage == .waits)
        #expect(Self.why(holds) == "!4102 was closed without merging: check the order")
    }

    @Test func yoursWithItsReviewsDoneButNotReadyIsInProgressWithWhatsLeft() {
        let left = Self.reading(StageFacts(role: .author, leftAfterReviews: "Build running", othersVoted: true))
        #expect(left?.stage == .inProgress)
        #expect(Self.why(left) == "Build running")
    }

    @Test func otherwiseYoursWaitsForATeammate() {
        let nobody = Self.reading(StageFacts(role: .author))
        #expect(nobody?.stage == .teammateReview)
        #expect(nobody?.why == .findReviewer)
        #expect(Self.why(nobody) == "Find a reviewer")
        #expect(Self.why(Self.reading(StageFacts(role: .author, waitingFor: "1 of 2 approvals"))) == "1 of 2 approvals")
    }

    /// The user's own example: A waits, B's session finished so you review it, and C needs someone to review it.
    @Test func theUsersThreePullRequests() {
        let a = Self.reading(
            StageFacts(role: .author, isReady: true, othersVoted: true), order: .waits([Self.pr(4102)], words: "After !4102")
        )
        let b = Self.reading(StageFacts(role: .author), sessions: [Self.session(.finished, at: 10)])
        let c = Self.reading(StageFacts(role: .author))
        #expect([a?.stage, b?.stage, c?.stage] == [.waits, .yourReview, .teammateReview])
        #expect([Self.why(a), Self.why(b), Self.why(c)] == ["After !4102", "‘Cart’ finished", "Find a reviewer"])
    }

    // MARK: What you or a session set

    @Test func onlyThreeStagesCanBeSetAndNoneEndsAsCanMerge() {
        #expect(PullRequestStage.settable == [.inProgress, .yourReview, .teammateReview])
        let facts = StageFacts(role: .author, isReady: true)
        for stage in [PullRequestStage.canMerge, .waits, .merged] {
            #expect(!StageRules.stands(StageMark(stage: stage, at: t(10)), facts: facts, sessions: []))
            #expect(Self.reading(facts, marks: [StageMark(stage: stage, at: t(10))])?.mark == nil)
        }
    }

    @Test func theLatestChangeWinsAndSaysWhoWithYoursToPutBack() {
        let facts = StageFacts(role: .author, waitingFor: "Waiting on Priya", votes: "0,10")
        let yours = StageMark(stage: .yourReview, at: t(100), votes: "0,10")
        let cart = StageMark(stage: .teammateReview, at: t(200), by: Self.cart, votes: "0,10")

        let later = Self.reading(facts, marks: [yours, cart])
        #expect(later?.stage == .teammateReview)
        #expect(later?.mark == cart)
        #expect(later?.replaced == yours)
        #expect(Self.why(later) == "Waiting on Priya")
        #expect(StageText.who(later!, now: t(500), name: Self.name) == "‘Cart’ set it 5m ago, after you")

        // Put Yours Back makes yours the latest again.
        let back = StageMark(stage: .yourReview, at: t(300), votes: "0,10")
        let yoursAgain = Self.reading(facts, marks: [yours, cart, back].filter { $0 != yours })
        #expect(yoursAgain?.stage == .yourReview)
        #expect(yoursAgain?.replaced == nil)
        #expect(StageText.who(yoursAgain!, now: t(7_500), name: Self.name) == "You set it 2h ago")

        // A session's change to the same stage replaces nothing to put back.
        let same = StageMark(stage: .yourReview, at: t(200), by: Self.cart)
        #expect(Self.reading(facts, marks: [yours, same])?.replaced == nil)

        // What a session set says so.
        let ready = StageMark(stage: .yourReview, at: t(200), by: Self.cart)
        #expect(Self.why(Self.reading(facts, marks: [ready])) == "‘Cart’ says it's ready")
        let onIt = StageMark(stage: .inProgress, at: t(200), by: Self.cart)
        #expect(Self.why(Self.reading(facts, marks: [onIt])) == "‘Cart’ is on it")
        #expect(Self.why(Self.reading(facts, marks: [StageMark(stage: .inProgress, at: t(200))])) == "You sent it back")
    }

    @Test func aSetInProgressEndsAsASessionFinishesOrNewCommitsCome() {
        let mark = StageMark(stage: .inProgress, at: t(100), commit: "a1b2c3d")
        let facts = StageFacts(role: .author, commit: "a1b2c3d")
        #expect(StageRules.stands(mark, facts: facts, sessions: [Self.session(.finished, at: 50)]))
        #expect(!StageRules.stands(mark, facts: facts, sessions: [Self.session(.finished, at: 150)]))
        var pushed = facts
        pushed.commit = "e4f5a6b"
        #expect(!StageRules.stands(mark, facts: pushed, sessions: []))
        // When either commit isn't known, it can't tell: it stands.
        pushed.commit = nil
        #expect(StageRules.stands(mark, facts: pushed, sessions: []))

        // Once it ends, BriefBar works the stage out again: the session finished, so it's your turn.
        let finished = Self.reading(facts, sessions: [Self.session(.finished, at: 150)], marks: [mark])
        #expect(finished?.stage == .yourReview)
        #expect(Self.why(finished) == "‘Cart’ finished")
    }

    @Test func aSetTeammatesReviewEndsAsOthersVotesChange() {
        let mark = StageMark(stage: .teammateReview, at: t(100), votes: "0", commit: "a1b2c3d")
        #expect(StageRules.stands(mark, facts: StageFacts(role: .author, votes: "0", commit: "e4f5a6b"), sessions: []))
        let approved = StageFacts(role: .author, isReady: true, othersVoted: true, votes: "10")
        #expect(!StageRules.stands(mark, facts: approved, sessions: []))
        #expect(Self.reading(approved, marks: [mark])?.stage == .canMerge)
        let wanted = StageFacts(role: .author, changesWanted: "Priya wants changes", othersVoted: true, votes: "-5")
        #expect(Self.reading(wanted, marks: [mark])?.stage == .inProgress)
    }

    /// On someone else's, its votes are your own (`StageFacts.votes`): voting ends it, as new commits do.
    @Test func finishedReviewingSomeoneElsesTakesItOffYourBoardUntilYouVoteOrNewCommitsCome() {
        let mark = StageMark(stage: .teammateReview, at: t(100), votes: "0", commit: "a1b2c3d")
        let facts = StageFacts(role: .reviewer, asksYou: "Sam asked you", votes: "0", commit: "a1b2c3d")
        let finished = Self.reading(facts, marks: [mark])
        #expect(finished?.stage == .teammateReview)
        #expect(finished?.isOnBoard == false)
        #expect(finished?.why == .finishedReview)

        var pushed = facts
        pushed.commit = "e4f5a6b"
        #expect(!StageRules.stands(mark, facts: pushed, sessions: []))
        #expect(Self.reading(pushed, marks: [mark])?.stage == .yourReview)

        let waiting = StageFacts(role: .reviewer, youWantChanges: "Waiting for Sam's changes", votes: "-5", commit: "a1b2c3d")
        #expect(!StageRules.stands(mark, facts: waiting, sessions: []))
        #expect(Self.why(Self.reading(waiting, marks: [mark])) == "Waiting for Sam's changes")
        #expect(Self.reading(StageFacts(role: .reviewer, votes: "10", commit: "a1b2c3d"), marks: [mark]) == nil)
    }

    @Test func aSetYourReviewStandsUntilItsChanged() {
        let mark = StageMark(stage: .yourReview, at: t(100), votes: "0", commit: "a1b2c3d")
        let moved = StageFacts(role: .author, othersVoted: true, votes: "10", commit: "e4f5a6b")
        #expect(StageRules.stands(mark, facts: moved, sessions: [Self.session(.finished, at: 500)]))
    }

    @Test func onceTheLatestEndsAnOlderOneDoesntComeBack() {
        let yours = StageMark(stage: .yourReview, at: t(100))
        let cart = StageMark(stage: .inProgress, at: t(200), by: Self.cart, commit: "a1b2c3d")
        let pushed = StageFacts(role: .author, waitingFor: "Waiting on Priya", commit: "e4f5a6b")
        let reading = Self.reading(pushed, marks: [yours, cart])
        #expect(reading?.mark == nil)
        #expect(reading?.stage == .teammateReview)
    }

    // MARK: The order

    static let planID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    static func missions(_ pullRequests: [OrderPullRequest], plan entries: [OrderPlan.Entry] = [], evidence: OrderEvidence = OrderEvidence())
        -> [OrderMission] {
        let orders = entries.isEmpty ? DeclaredOrders()
            : DeclaredOrders(plans: [OrderPlan(id: planID, createdAt: t(0), updatedAt: t(0), entries: entries)])
        return OrderBoard.missions(facts: OrderFacts(pullRequests: pullRequests), orders: orders, evidence: evidence, now: t(1_000))
    }

    @Test func itsOrderSaysWhetherItWaitsAndForWhat() {
        let missions = Self.missions(
            [OrderBoardTests.ado(4101, from: "robin/rounding"), OrderBoardTests.ado(4102, from: "robin/cart"),
             OrderBoardTests.ado(4103, from: "robin/coupons")],
            plan: [.init(ref: Self.pr(4101)), .init(ref: Self.pr(4102), after: [Self.pr(4101)]), .init(ref: Self.pr(4103))]
        )
        #expect(StageOrder.of(Self.pr(4101), in: missions) == .free)
        #expect(StageOrder.of(Self.pr(4102), in: missions) == .waits([Self.pr(4101)], words: "After !4101"))
        #expect(StageOrder.of(Self.pr(4103), in: missions) == .free)
        #expect(StageOrder.of(Self.pr(4999), in: missions) == .free)
    }

    @Test func aStackedBranchHoldsItAndItsCapsuleSaysSo() {
        let missions = Self.missions([
            OrderBoardTests.ado(4101, from: "robin/rounding"), OrderBoardTests.ado(4102, from: "robin/cart", into: "robin/rounding"),
        ])
        #expect(StageOrder.of(Self.pr(4102), in: missions) == .waits([Self.pr(4101)], words: "After !4101 · stacked"))
        // Once BriefBar saw it merge, it's free.
        let merged = Self.missions([
            OrderBoardTests.ado(4101, from: "robin/rounding", state: .merged),
            OrderBoardTests.ado(4102, from: "robin/cart", into: "main"),
        ], plan: [.init(ref: Self.pr(4101)), .init(ref: Self.pr(4102), after: [Self.pr(4101)])])
        #expect(StageOrder.of(Self.pr(4102), in: merged) == .free)
    }

    @Test func oneStackedOnAnOrdersPullRequestWaitsForIt() {
        let missions = Self.missions(
            [OrderBoardTests.ado(4101, from: "robin/rounding"), OrderBoardTests.ado(4105, from: "robin/tests", into: "robin/rounding")],
            plan: [.init(ref: Self.pr(4101))]
        )
        #expect(missions.first?.attached.map(\.ref) == [Self.pr(4105)])
        #expect(StageOrder.of(Self.pr(4105), in: missions) == .waits([Self.pr(4101)], words: "After !4101 · stacked"))
    }

    /// An order that puts nothing before one stacked on another of its own still waits for that one, ready to complete or
    /// not, until BriefBar sees it merge: completing it first would merge it into the other's branch.
    @Test func oneStackedOnAnotherOfItsOrderWaitsForItWhateverTheOrderSays() throws {
        let pullRequests = [
            OrderBoardTests.ado(4101, from: "robin/rounding"), OrderBoardTests.ado(4102, from: "robin/cart", into: "robin/rounding"),
        ]
        let missions = Self.missions(pullRequests, plan: [.init(ref: Self.pr(4101)), .init(ref: Self.pr(4102))])
        let step = try #require(missions.first?.steps.first { $0.ref == Self.pr(4102) })
        #expect(step.notes.contains(.orderDisagrees(Self.pr(4101), .branch)))
        #expect(StageOrder.of(Self.pr(4102), in: missions) == .waits([Self.pr(4101)], words: "After !4101 · stacked"))
        let order = StageOrder.of(Self.pr(4102), in: missions)
        #expect(Self.reading(StageFacts(role: .author, isReady: true), order: order)?.stage == .waits)

        let merged = Self.missions(
            [OrderBoardTests.ado(4101, from: "robin/rounding", state: .merged), pullRequests[1]],
            plan: [.init(ref: Self.pr(4101)), .init(ref: Self.pr(4102))]
        )
        #expect(StageOrder.of(Self.pr(4102), in: merged) == .free)
    }

    /// One whose order names only it waits for the pull request whose branch it targets, until BriefBar sees that one
    /// merge, whether no order names that one or another order does.
    @Test func oneStackedOnAPullRequestItsOrderDoesntNameWaitsForIt() throws {
        let parent = OrderBoardTests.ado(4101, from: "robin/rounding")
        let child = OrderBoardTests.ado(4102, from: "robin/cart", into: "robin/rounding")
        let alone = Self.missions([parent, child], plan: [.init(ref: Self.pr(4102))])
        let step = try #require(alone.lazy.flatMap(\.steps).first { $0.ref == Self.pr(4102) })
        #expect(step.notes.contains(.showsAgainst(Self.pr(4101))))
        #expect(StageOrder.of(Self.pr(4102), in: alone) == .waits([Self.pr(4101)], words: "After !4101 · stacked"))
        #expect(Self.reading(StageFacts(role: .author, isReady: true), order: StageOrder.of(Self.pr(4102), in: alone))?.stage == .waits)

        let otherID = UUID(uuidString: "99999999-2222-4333-8444-555555555555")!
        let orders = DeclaredOrders(plans: [
            OrderPlan(id: Self.planID, createdAt: t(0), updatedAt: t(0), entries: [.init(ref: Self.pr(4102))]),
            OrderPlan(id: otherID, createdAt: t(0), updatedAt: t(0), entries: [.init(ref: Self.pr(4101))]),
        ])
        let twoOrders = OrderBoard.missions(
            facts: OrderFacts(pullRequests: [parent, child]), orders: orders, evidence: OrderEvidence(), now: t(1_000)
        )
        #expect(StageOrder.of(Self.pr(4102), in: twoOrders) == .waits([Self.pr(4101)], words: "After !4101 · stacked"))

        let merged = Self.missions([OrderBoardTests.ado(4101, from: "robin/rounding", state: .merged), child], plan: [.init(ref: Self.pr(4102))])
        #expect(StageOrder.of(Self.pr(4102), in: merged) == .free)
    }

    @Test func anOrderToCheckHoldsIt() {
        let missions = Self.missions(
            [OrderBoardTests.ado(4101, from: "robin/rounding", state: .closed), OrderBoardTests.ado(4102, from: "robin/cart")],
            plan: [.init(ref: Self.pr(4101)), .init(ref: Self.pr(4102), after: [Self.pr(4101)])]
        )
        #expect(StageOrder.of(Self.pr(4102), in: missions) == .holds("!4101 was closed without merging: check the order"))
    }

    // MARK: Words

    @Test func itsSentenceAndWhoSetItAsVoiceOverSaysThem() {
        let worked = Self.reading(StageFacts(role: .author), sessions: [Self.session(.finished, at: 10)])!
        #expect(StageText.sentence(worked, now: t(100), name: Self.name) == "Your review: ‘Cart’ finished. Worked out by BriefBar.")
        #expect(StageText.who(worked, now: t(100), name: Self.name) == nil)
        #expect(StageText.spokenWho(worked, now: t(100), name: Self.name) == "worked out by BriefBar")

        let set = Self.reading(StageFacts(role: .author), marks: [StageMark(stage: .teammateReview, at: t(10))])!
        #expect(StageText.sentence(set, now: t(7_210), name: Self.name) == "Teammate's review: Find a reviewer. You set it 2h ago.")
        #expect(StageText.spokenWho(set, now: t(7_210), name: Self.name) == "set by you 2 hours ago")
        #expect(StageText.putBack(StageMark(stage: .teammateReview, at: t(10)), now: t(7_210)) == "Put Yours Back: Teammate's review, 2h ago")
        #expect(StageText.moved(Self.pr(4093), to: .teammateReview) == "Moved !4093 to Teammate's review")
        #expect(StageText.moved(Self.pr(4093), to: nil) == "Let BriefBar decide !4093's stage")
    }

    @Test func votesAreKeptAsTheVotesAloneInOrder() {
        #expect(StageFacts.digest(votes: [10, -5, 0, 10]) == "-5,0,10,10")
        #expect(StageFacts.digest(votes: []) == "")
    }

    @Test func theKeyboardMovesBetweenTheStagesYouCanSet() {
        #expect(PullRequestStage.inProgress.nextSettable == .yourReview)
        #expect(PullRequestStage.yourReview.nextSettable == .teammateReview)
        #expect(PullRequestStage.teammateReview.nextSettable == nil)
        #expect(PullRequestStage.inProgress.previousSettable == nil)
        #expect(PullRequestStage.teammateReview.previousSettable == .yourReview)
        #expect(PullRequestStage.canMerge.nextSettable == nil)
        #expect(PullRequestStage.allCases.map(\.step) == [0, 1, 2, 3, 3, 4])
    }

    /// A mission's progress bar counts its pull requests in each stage, in the stages' order.
    @Test func theProgressBarCountsEachStage() {
        #expect(StageText.counts([]) == nil)
        #expect(StageText.counts([.merged, .waits, .inProgress, .yourReview, .inProgress]) ==
            "2 in progress · 1 for your review · 1 waits for another PR · 1 merged")
        #expect(StageText.counts([.teammateReview, .canMerge, .waits, .waits]) ==
            "1 for a teammate's review · 1 can merge · 2 wait for other PRs")
    }

    /// When it happened is said only where it's when what the stage says happened: not a pull request's last change.
    @Test func itSaysWhenOnlyForWhatHappenedThen() {
        let finished = Self.reading(StageFacts(role: .author), sessions: [Self.session(.finished, at: 10)])!
        #expect(finished.why.saysWhen && finished.since == t(10))
        let waiting = Self.reading(StageFacts(role: .author, waitingFor: "Waiting on Sam", since: t(20)))!
        #expect(!waiting.why.saysWhen)
        #expect(StageWhy.merged.saysWhen && !StageWhy.findReviewer.saysWhen && !StageWhy.set.saysWhen)
    }

    /// VoiceOver offers, on a row or a card, Finished My Review in Your review, each stage you can set but the one it's
    /// in, Put Yours Back once a session's change replaced yours, and Let BriefBar Decide for one you set; nothing once it
    /// merged. Someone else's that you finished reviewing is in Teammate's review: moving it there again would do nothing.
    @Test func voiceOverOffersWhatCanBeDoneToItsStage() {
        let finished = Self.reading(StageFacts(role: .author), sessions: [Self.session(.finished, at: 10)])!
        #expect(StageAction.offered(for: finished).map(\.title) ==
            ["Finished My Review", "Move to In Progress", "Move to Teammate's Review"])

        let set = Self.reading(StageFacts(role: .author), marks: [StageMark(stage: .teammateReview, at: t(10))])!
        #expect(StageAction.offered(for: set) == [.move(.inProgress), .move(.yourReview), .letBriefBarDecide])

        let replaced = Self.reading(
            StageFacts(role: .author),
            marks: [StageMark(stage: .teammateReview, at: t(10)), StageMark(stage: .inProgress, at: t(20), by: Self.cart)]
        )!
        #expect(StageAction.offered(for: replaced) == [.move(.yourReview), .move(.teammateReview), .putYoursBack])

        let reviewed = Self.reading(
            StageFacts(role: .reviewer, asksYou: "Sam asked you", commit: "c1"), marks: [StageMark(stage: .teammateReview, at: t(10), commit: "c1")]
        )!
        #expect(!reviewed.isOnBoard)
        #expect(StageAction.offered(for: reviewed) == [.move(.inProgress), .move(.yourReview), .letBriefBarDecide])

        let ready = Self.reading(StageFacts(role: .author, isReady: true))!
        #expect(StageAction.offered(for: ready).map(\.title) == ["Move to In Progress", "Move to Your Review", "Move to Teammate's Review"])
        #expect(StageAction.offered(for: Self.reading(StageFacts(role: .author, state: .merged))!).isEmpty)

        // Someone else's asks for its own reviews: Finished My Review, never Move to Teammate's Review, where yours has both.
        let asked = Self.reading(StageFacts(role: .reviewer, asksYou: "Sam asked you", author: "Sam"))!
        #expect(StageAction.offered(for: asked, isYours: false) == [.finishedReview, .move(.inProgress)])
        let changes = Self.reading(StageFacts(role: .reviewer, youWantChanges: "Waiting for Sam's changes", author: "Sam"))!
        #expect(changes.stage == .inProgress)
        #expect(StageAction.offered(for: changes, isYours: false) == [.move(.yourReview)])
        #expect(StageAction.offered(for: asked, canUndo: true, isYours: false) == [.finishedReview, .move(.inProgress), .undo])
        #expect(StageText.whyNotTeammateReview(author: "Sam") == "It's Sam's: they ask for its reviews")
        #expect(StageText.whyNotTeammateReview(author: nil) == "It's someone else's: they ask for its reviews")
    }

    /// After a change, VoiceOver hears where it is now and where Undo is; after Undo, where it is again.
    @Test func voiceOverHearsWhatBecameOfIt() {
        let set = Self.reading(StageFacts(role: .author), marks: [StageMark(stage: .teammateReview, at: t(10))])!
        #expect(StageText.changed(Self.pr(4093), to: set) == "!4093 is in Teammate's review now. Undo is in its stage's menu.")
        let reviewed = Self.reading(
            StageFacts(role: .reviewer, asksYou: "Sam asked you"), marks: [StageMark(stage: .teammateReview, at: t(10))]
        )!
        #expect(StageText.changed(Self.pr(4110), to: reviewed) == "!4110 is off your board now. Undo is in its stage's menu.")
        // On the Board, a card that left it leaves its Undo at the top of its lane; one still there has it in its menu.
        #expect(StageText.changed(Self.pr(4110), to: reviewed, undo: .lane) == "!4110 is off your board now. Undo is at the top of its lane.")
        #expect(StageText.changed(Self.pr(4110), to: nil, undo: .lane) == "!4110 is off your board now. Undo is at the top of its lane.")
        #expect(StageText.changed(Self.pr(4093), to: set, undo: .lane) == "!4093 is in Teammate's review now. Undo is in its stage's menu.")
        let asked = Self.reading(StageFacts(role: .reviewer, asksYou: "Sam asked you"))!
        #expect(StageText.undone(Self.pr(4110), to: asked) == "Undone: !4110 is in Your review again")
        #expect(StageText.undone(Self.pr(4110), to: nil) == "Undone")
    }

    /// Of the sessions at work on it, the one that started latest says why; of two that started together, the earliest
    /// reference, whichever order the sources list them in.
    @Test func theSessionThatStartedLatestSaysWhyWhateverTheOrder() {
        let other = ItemRef.session("0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!
        let older = StageSession(ref: other, activity: .working, since: t(10))
        let newer = Self.session(.working, at: 20)
        #expect(StageRules.latest([older, newer])?.ref == Self.cart)
        #expect(StageRules.latest([newer, older])?.ref == Self.cart)
        let together = [Self.session(.working, at: 20), StageSession(ref: other, activity: .working, since: t(20))]
        let first = min(Self.cart, other)
        #expect(StageRules.latest(together)?.ref == first)
        #expect(StageRules.latest(together.reversed())?.ref == first)
        let unknown = StageSession(ref: other, activity: .working, since: nil)
        #expect(StageRules.latest([unknown, Self.session(.working, at: 1)])?.ref == Self.cart)
        #expect(StageRules.latest([]) == nil)
    }

    /// Undo comes last among VoiceOver's actions while your last change was to it, even once it has no stage left.
    @Test func undoIsOfferedEvenWithNoStageLeft() {
        let set = Self.reading(StageFacts(role: .author), marks: [StageMark(stage: .teammateReview, at: t(10))])!
        #expect(StageAction.offered(for: set, canUndo: true) == StageAction.offered(for: set) + [.undo])
        #expect(StageAction.offered(for: set, canUndo: false) == StageAction.offered(for: set))
        #expect(StageAction.offered(for: nil, canUndo: true) == [.undo])
        #expect(StageAction.offered(for: nil, canUndo: false).isEmpty)
        #expect(StageAction.undo.title == "Undo")
        #expect(StageText.changed(Self.pr(4110), to: nil) == "!4110 is off your board now. Undo is in its stage's menu.")
    }

    /// Copilot's pre-review of someone else's keeps it yours to review while it runs, saying so. No session puts someone
    /// else's in progress, and a review's end ends no In progress you set. On yours, a review neither puts it in progress
    /// nor counts as finished.
    @Test func aPreReviewKeepsSomeoneElsesYoursToReview() {
        let review = StageSession(ref: Self.cart, activity: .working, since: t(10), name: "Copilot", isReview: true)
        let asked = StageFacts(role: .reviewer, asksYou: "Priya asked you")
        let running = Self.reading(asked, sessions: [review])
        #expect(running?.stage == .yourReview)
        #expect(Self.why(running) == "Copilot is pre-reviewing it")
        #expect(running?.why.saysWhen == true && running?.since == t(10))
        var done = review
        done.activity = .finished
        done.since = t(20)
        #expect(Self.why(Self.reading(asked, sessions: [done])) == "Priya asked you")

        // A session writing someone else's, or asking you something about it, doesn't put it in progress.
        #expect(Self.why(Self.reading(asked, sessions: [Self.session(.working, at: 10)])) == "Priya asked you")
        #expect(Self.why(Self.reading(asked, sessions: [Self.session(.waitsForYou, at: 10)])) == "Priya asked you")
        #expect(Self.reading(StageFacts(role: .reviewer), sessions: [Self.session(.working, at: 10)]) == nil)

        // A review's end ends no In progress you set; while it runs, after you set it, it shows.
        let mark = StageMark(stage: .inProgress, at: t(5))
        #expect(StageRules.stands(mark, facts: asked, sessions: [done]))
        #expect(Self.reading(asked, sessions: [done], marks: [mark])?.stage == .inProgress)
        #expect(Self.reading(asked, sessions: [review], marks: [mark])?.stage == .yourReview)

        // On yours, a review neither puts it in progress nor counts as finished.
        let yours = StageFacts(role: .author)
        #expect(Self.reading(yours, sessions: [review])?.stage == .teammateReview)
        #expect(Self.reading(yours, sessions: [done])?.stage == .teammateReview)
    }
}
