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
        _ facts: StageFacts, sessions: [StageSession] = [], marks: [StageMark] = [], order: StageOrder = .free,
        reached: StageReach? = nil
    ) -> StageReading? {
        StageRules.reading(facts: facts, sessions: sessions, marks: marks, order: order, reached: reached)
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

    /// Before it got anywhere, and before anyone else voted on it, the session that opened it puts it in progress while it
    /// writes it; one waiting for you asks, and another writing it, and what fails, are its flags.
    @Test func aSessionAtWorkPutsItInProgressAndOneWaitingForYouAsks() {
        let failing = StageFacts(role: .author, failure: "Build failed")
        let working = Self.reading(failing, sessions: [Self.session(.working, at: 10)])
        #expect(working?.stage == .inProgress)
        #expect(Self.why(working) == "‘Cart’ is writing it · build failed")
        #expect(working?.since == t(10))

        let asking = Self.reading(
            failing, sessions: [Self.session(.working, at: 30, Self.backoff), Self.session(.waitsForYou, at: 20)]
        )
        #expect(Self.why(asking) == "‘Cart’ asks you · ‘Retry backoff’ is writing it · build failed")

        // A task BriefBar sent, which the sources don't name, has its own.
        let task = StageSession(ref: .session("9e8d7c6b-5a49-4382-a1b0-c9d8e7f6a5b4")!, activity: .working, since: t(5), name: "Copilot")
        #expect(Self.why(Self.reading(failing, sessions: [task])) == "Copilot is writing it · build failed")
        // One the sources can't name.
        let unnamed = StageSession(ref: .session("0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!, activity: .working, since: t(5))
        #expect(Self.why(Self.reading(failing, sessions: [unnamed])) == "A Copilot session is writing it · build failed")
    }

    /// On yours, a failed build or merge is said after the reason of a session or a stage you set that decides its stage,
    /// in its row's words and its tooltip, and to VoiceOver after a pause; where the failure decides, it's said once, and
    /// someone else's says none.
    @Test func aFailureIsSaidAfterTheSessionOrStageThatDecides() {
        let failing = StageFacts(role: .author, failure: "Merge conflicts")
        let asking = Self.reading(failing, sessions: [Self.session(.waitsForYou, at: 20)])
        #expect(asking?.stage == .inProgress)
        #expect(Self.why(asking) == "‘Cart’ asks you · merge conflicts")
        #expect(asking.map { StageText.why($0, name: Self.name, then: ", ") } == "‘Cart’ asks you, merge conflicts")
        #expect(asking.map { StageText.sentence($0, now: t(60), name: Self.name) }
            == "In progress: ‘Cart’ asks you · merge conflicts. Worked out by BriefBar.")

        let set = Self.reading(failing, marks: [StageMark(stage: .yourReview, at: t(100))])
        #expect(set?.stage == .yourReview)
        #expect(Self.why(set) == "Waiting for your review · merge conflicts")

        #expect(Self.why(Self.reading(failing)) == "Find a reviewer · merge conflicts")
        #expect(Self.reading(StageFacts(role: .author), sessions: [Self.session(.waitsForYou, at: 20)])?.alsoFailing == nil)
        #expect(Self.reading(StageFacts(role: .reviewer, failure: "Build failed", asksYou: "Jordan asked you"))?.alsoFailing == nil)
    }

    /// A session that starts on one of yours after you set its stage moves nothing: it's a flag on it.
    @Test func aStageYouSetStaysWhileASessionWorksOnItMarked() {
        let facts = StageFacts(role: .author, waitingFor: "Waiting on Priya")
        let set = StageMark(stage: .yourReview, at: t(100))

        let before = Self.reading(facts, sessions: [Self.session(.working, at: 50)], marks: [set])
        #expect(before?.stage == .yourReview)
        #expect(before?.mark == set)
        #expect(Self.why(before) == "Waiting for your review · ‘Cart’ is writing it")

        let after = Self.reading(facts, sessions: [Self.session(.working, at: 150)], marks: [set])
        #expect(after?.stage == .yourReview)
        #expect(after?.mark == set)
        #expect(after?.flags == [.working(Self.session(.working, at: 150))])
        let asking = Self.reading(facts, sessions: [Self.session(.waitsForYou, at: 150)], marks: [set])
        #expect(Self.why(asking) == "Waiting for your review · ‘Cart’ asks you")
        #expect(asking?.fixRank == 0)
    }

    /// What fails and what someone wants are flags, wherever it is: they never put yours in progress.
    @Test func whatFailsAndWhatsWantedAreFlagsWhereverItIs() {
        let both = StageFacts(role: .author, failure: "Merge conflicts", changesWanted: "Priya wants changes", isReady: true)
        #expect(Self.reading(both)?.stage == .canMerge)
        #expect(Self.why(Self.reading(both)) == "Complete it · merge conflicts · Priya wants changes")
        let wanted = StageFacts(role: .author, changesWanted: "Priya wants changes", othersVoted: true)
        let finished = Self.reading(wanted, sessions: [Self.session(.finished, at: 10)])
        #expect(finished?.stage == .yourReview)
        #expect(Self.why(finished) == "‘Cart’ finished · Priya wants changes")
        #expect(finished?.fixRank == 2)
        // Many who want changes say so lowercased, as what fails does.
        var many = wanted
        many.changesWanted = "Changes requested"
        #expect(Self.why(Self.reading(many, sessions: [Self.session(.finished, at: 10)])) == "‘Cart’ finished · changes requested")
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

        // Once someone else approved it, it's theirs; a vote that only wants changes leaves it yours to review.
        let approved = StageFacts(role: .author, approvedBy: "Sam", waitingFor: "Waiting on Priya", othersVoted: true)
        #expect(Self.reading(approved, sessions: [Self.session(.finished, at: 60)])?.stage == .teammateReview)
        let voted = StageFacts(role: .author, waitingFor: "Waiting on Priya", othersVoted: true)
        #expect(Self.reading(voted, sessions: [Self.session(.finished, at: 60)])?.stage == .yourReview)
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

    /// Two readings read the same whatever names the missions their words name: as they read naming none, as agents read
    /// them. Not once what they say naming none differs, nor their stage.
    @Test func readingsReadTheSameWhateverNamesTheMissionsTheyName() {
        let says = { (name: String) in StageWhy.orderHolds("\(name) puts !4102 after it: check the order") }
        var named = StageReading(stage: .waits, why: says("‘Payments’"), since: t(10))
        named.unnamedWhy = says("Another order")
        var renamed = named
        renamed.why = says("‘Checkout’")
        #expect(renamed != named && StageReading.readTheSame(renamed, named))
        #expect(StageReading.readTheSame(StageReading(stage: .waits, why: says("Another order"), since: t(10)), named))

        var otherWords = named
        otherWords.unnamedWhy = .orderHolds("Another order puts !4103 after it: check the order")
        #expect(!StageReading.readTheSame(otherWords, named))
        var otherStage = named
        otherStage.stage = .yourReview
        #expect(!StageReading.readTheSame(otherStage, named))
        #expect(StageReading.readTheSame(nil, nil) && !StageReading.readTheSame(named, nil))
    }

    /// The user's case: approved, but not ready, it's Approved, saying what's left that isn't a flag, else who approved
    /// it, else what fails or who wants changes, else that it isn't ready yet; what fails is a flag after that.
    @Test func yoursApprovedButNotReadyIsApprovedSayingWhatsLeftOrWhoApprovedIt() {
        let approved = StageFacts(role: .author, failure: "Build failed", isApproved: true, approvedBy: "Maria", othersVoted: true)
        let failed = Self.reading(approved)
        #expect(failed?.stage == .approved)
        #expect(Self.why(failed) == "Maria approved it · build failed")
        #expect(failed?.flags == [.failing("Build failed")])
        #expect(failed?.fixRank == 1)

        var left = approved
        left.failure = nil
        left.leftAfterReviews = "Build running"
        #expect(Self.why(Self.reading(left)) == "Build running")
        let alone = Self.reading(StageFacts(role: .author, failure: "Merge conflicts", isApproved: true))
        #expect(Self.why(alone) == "Merge conflicts")
        #expect(alone?.flags.isEmpty == true)
        #expect(Self.why(Self.reading(StageFacts(role: .author, isApproved: true))) == "Not ready to complete yet")
        #expect(PullRequestStage.approved.step == 3 && PullRequestStage.canMerge.step == 4)
        #expect(StageText.counts([.approved, .approved, .canMerge]) == "2 approved · 1 can merge")
    }

    /// BriefBar never moves one of yours back but where it loses what its stage stands for: its approval, back to
    /// Teammate's review; Azure DevOps' readiness while it's still approved, back to Approved. A session that writes it
    /// again, what fails or changes someone wants leave it where it got, flagged; one it can't tell is approved stays.
    @Test func yoursGoesBackOnlyAsItLosesWhatItsStageStandsFor() {
        let waiting = StageFacts(role: .author, failure: "Build expired", waitingFor: "Waiting on Priya")
        let writing = [Self.session(.working, at: 150)]
        // The user's !17775444: waiting for reviewers with an expired build stays in Teammate's review.
        #expect(Self.why(Self.reading(waiting, reached: StageReach(.teammateReview))) == "Waiting on Priya · build expired")
        let rewritten = Self.reading(waiting, sessions: writing, reached: StageReach(.teammateReview))
        #expect(rewritten?.stage == .teammateReview)
        #expect(Self.why(rewritten) == "Waiting on Priya · ‘Cart’ is writing it · build expired")
        #expect(rewritten?.fixRank == nil)
        let review = Self.reading(StageFacts(role: .author), sessions: writing, reached: StageReach(.yourReview))
        #expect(review?.stage == .yourReview)
        #expect(Self.why(review) == "Waiting for your review · ‘Cart’ is writing it")
        // Never seen further, it's the opening session's to write; so is one BriefBar first saw in Teammate's review while
        // the session was already at work, or done, as before the Copilot app said which session opened it.
        #expect(Self.reading(StageFacts(role: .author), sessions: writing)?.stage == .inProgress)
        #expect(Self.reading(StageFacts(role: .author, othersVoted: true), sessions: writing)?.stage == .teammateReview)
        let firstSeen = StageReach(.teammateReview, since: t(200), isFirst: true)
        #expect(Self.reading(waiting, sessions: writing, reached: firstSeen)?.stage == .inProgress)
        let done = Self.reading(waiting, sessions: [Self.session(.finished, at: 150)], reached: firstSeen)
        #expect(done?.stage == .yourReview)
        #expect(Self.why(done) == "‘Cart’ finished · build expired")
        // Not a session that started after, nor once something moved it there, as when its approval was lost.
        let before = StageReach(.teammateReview, since: t(100), isFirst: true)
        #expect(Self.reading(waiting, sessions: writing, reached: before)?.stage == .teammateReview)
        #expect(Self.reading(waiting, sessions: [Self.session(.finished, at: 150)], reached: before)?.stage == .teammateReview)
        let moved = StageReach(.teammateReview, since: t(200))
        #expect(Self.reading(waiting, sessions: writing, reached: moved)?.stage == .teammateReview)
        #expect(Self.reading(waiting, sessions: [Self.session(.finished, at: 150)], reached: moved)?.stage == .teammateReview)
        #expect(Self.reading(waiting, sessions: writing, reached: StageReach(.yourReview, since: t(200), isFirst: true))?.stage
            == .yourReview)

        // Its approval lost, as a push reset the votes: back to Teammate's review.
        for reached in [PullRequestStage.approved, .canMerge] {
            let lost = Self.reading(StageFacts(role: .author, waitingFor: "Waiting on Sam"), reached: StageReach(reached))
            #expect(lost?.stage == .teammateReview)
            #expect(Self.why(lost) == "Waiting on Sam")
        }
        // Not ready while still approved, as its build failed: back to Approved, flagged.
        let notReady = Self.reading(
            StageFacts(role: .author, failure: "Build failed", isApproved: true, approvedBy: "Maria"), reached: StageReach(.canMerge)
        )
        #expect(notReady?.stage == .approved)
        // Can't tell whether it's approved, as while its policies are read again: it stays where it got.
        let unknown = StageFacts(role: .author, isApproved: nil, waitingFor: "Waiting on Sam")
        #expect(Self.reading(unknown, reached: StageReach(.approved))?.stage == .approved)
        #expect(Self.reading(unknown, reached: StageReach(.canMerge))?.stage == .canMerge)
        #expect(Self.reading(unknown, reached: StageReach(.teammateReview))?.stage == .teammateReview)
        // A draft again is in progress: you moved it.
        #expect(Self.reading(StageFacts(role: .author, state: .draft, isApproved: true), reached: StageReach(.approved))?.stage == .inProgress)
    }

    /// How far it got, for BriefBar to keep: none for In progress, Can merge for Waits; once what was set ends, from that,
    /// so that one you sent to Teammate's review that someone only wants changes on stays there.
    @Test func howFarItGotComesFromWhatWasSetOnceThatEnds() {
        #expect(StageRules.reached(StageReading(stage: .waits, why: .waitsFor([Self.pr(4102)], words: "After !4102"))) == .canMerge)
        #expect(StageRules.reached(StageReading(stage: .inProgress, why: .draft)) == nil)
        #expect(StageRules.reached(StageReading(stage: .approved, why: .approvedBy("Maria"))) == .approved)
        #expect(StageRules.reached(kept: StageReach(.approved), ended: nil) == StageReach(.approved))
        #expect(StageRules.reached(kept: StageReach(.approved), ended: StageMark(stage: .inProgress, at: t(10))) == nil)

        // ‘Cart’ finished, so it got to your review; you finished yours; then Priya wants changes, which ends yours.
        let facts = StageFacts(role: .author, changesWanted: "Priya wants changes", othersVoted: true, votes: "-5")
        let yours = StageMark(stage: .teammateReview, at: t(100), votes: "")
        let counted = StageRules.counted(yours: yours, theirs: [], facts: facts, sessions: [])
        #expect(counted.yours == nil && counted.ended == yours)
        let got = StageRules.reached(kept: StageReach(.yourReview, since: t(50)), ended: counted.ended)
        #expect(got == StageReach(.teammateReview, since: t(100)))
        let reading = Self.reading(facts, sessions: [Self.session(.finished, at: 50)], reached: got)
        #expect(reading?.stage == .teammateReview)
        #expect(Self.why(reading) == "Find a reviewer · Priya wants changes")
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
        #expect(StageText.whyNotSettable(.approved) == "Azure DevOps decides: once the reviewers it requires approve")
        for stage in [PullRequestStage.approved, .canMerge, .waits, .merged] {
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
        #expect(StageText.sentence(later!, now: t(500), name: Self.name) == "Teammate's review: Waiting on Priya. ‘Cart’ set it 5m ago, after you.")

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

    /// A session's own In progress ends as it finishes, though BriefBar doesn't see it on the pull request otherwise; as
    /// it works on, or on something else, it isn't on the pull request: it doesn't put it in progress.
    @Test func aSessionsOwnInProgressEndsAsItFinishesOnItOrNot() {
        let mark = StageMark(stage: .inProgress, at: t(100), by: Self.cart, commit: "a1b2c3d")
        let facts = StageFacts(role: .author, waitingFor: "Waiting on Priya", commit: "a1b2c3d")
        func stands(_ setter: StageSession, _ mark: StageMark = mark) -> Bool {
            StageRules.stands(mark, facts: facts, sessions: [], setters: [setter.ref: setter])
        }
        #expect(stands(Self.session(.working, at: 150)))
        #expect(stands(Self.session(.finished, at: 50)))
        #expect(stands(Self.session(.stopped, at: 150)))
        #expect(!stands(Self.session(.finished, at: 150)))
        // Another session's end ends only what it set.
        #expect(stands(Self.session(.finished, at: 150, Self.backoff)))
        #expect(stands(Self.session(.finished, at: 150), StageMark(stage: .yourReview, at: t(100), by: Self.cart)))

        let finished = Self.session(.finished, at: 150)
        let ended = StageRules.reading(facts: facts, sessions: [], marks: [mark], order: .free, setters: [Self.cart: finished])
        #expect(ended?.stage == .teammateReview)
        #expect(ended?.mark == nil)
        let counted = StageRules.counted(yours: nil, theirs: [mark], facts: facts, sessions: [], setters: [Self.cart: finished])
        #expect(counted.latestEnded)

        let ready = StageMark(stage: .yourReview, at: t(100), by: Self.cart)
        let working = Self.session(.working, at: 150)
        let reading = StageRules.reading(facts: facts, sessions: [], marks: [ready], order: .free, setters: [Self.cart: working])
        #expect(reading?.stage == .yourReview)
        #expect(Self.why(reading) == "‘Cart’ says it's ready")
    }

    /// While the session that set its In progress writes it, it's no fix for you, whatever fails, as that session may be
    /// fixing it: "‘Cart’ is on it" says it, once. Once that session waits for you, it asks you, first.
    @Test func theSessionThatSetItsInProgressWritesItAndAsksYouAsAnyDoes() {
        let mark = StageMark(stage: .inProgress, at: t(100), by: Self.cart)
        let facts = StageFacts(role: .author, failure: "Build failed", isApproved: true, approvedBy: "Maria")
        // On it, or only listed, as one that set its stage without BriefBar seeing it on it otherwise.
        for onIt in [true, false] {
            func reading(_ activity: StageSession.Activity) -> StageReading? {
                let session = Self.session(activity, at: activity == .working ? 90 : 150)
                return StageRules.reading(
                    facts: facts, sessions: onIt ? [session] : [], marks: [mark], order: .free, setters: [Self.cart: session]
                )
            }
            let working = reading(.working)
            #expect(working?.stage == .inProgress)
            #expect(Self.why(working) == "‘Cart’ is on it · build failed")
            #expect(working?.writer?.ref == Self.cart)
            #expect(working?.fixRank == nil)

            let asking = reading(.waitsForYou)
            #expect(Self.why(asking) == "‘Cart’ is on it · ‘Cart’ asks you · build failed")
            #expect(asking?.fixRank == 0)
        }
    }

    /// A session's Your review that followed one of yours, keeping no votes, counts only while that one of yours is there:
    /// not on its own, as once you took yours away, nor under another of yours, which it didn't follow. A session's own,
    /// with its votes, counts as any does.
    @Test func aSessionsYourReviewThatFollowedYoursCountsOnlyWhileYoursIsThere() {
        let facts = StageFacts(role: .author, votes: "")
        let yours = StageMark(stage: .yourReview, at: t(10))
        let followed = StageMark(stage: .yourReview, at: t(20), by: Self.cart)
        #expect(followed.follows(yours))
        #expect(StageRules.counted(yours: yours, theirs: [followed], facts: facts, sessions: []).theirs == [followed])
        #expect(StageRules.counted(yours: nil, theirs: [followed], facts: facts, sessions: []).theirs.isEmpty)
        let later = StageMark(stage: .yourReview, at: t(30))
        #expect(!followed.follows(later))
        #expect(StageRules.counted(yours: later, theirs: [followed], facts: facts, sessions: []).theirs.isEmpty)
        let teammate = StageMark(stage: .teammateReview, at: t(5), votes: "")
        #expect(StageRules.counted(yours: teammate, theirs: [followed], facts: facts, sessions: []).theirs.isEmpty)
        let own = StageMark(stage: .yourReview, at: t(20), by: Self.cart, votes: "")
        #expect(!own.follows(yours))
        #expect(StageRules.counted(yours: nil, theirs: [own], facts: facts, sessions: []).theirs == [own])
    }

    /// A Your review you set outlasts sessions' In progress over it (`StageMark.outlasts`): while that stands, it
    /// shows, with yours to put back, which shows again once it ends, as its session finishes or new commits come, with
    /// the Your reviews that followed yours. Another stage a session set since replaced it, as In progress over another
    /// stage of yours does: once the latest ends, none counts; nor once the pull request merged.
    @Test func aYourReviewYouSetOutlastsASessionsInProgressOverIt() {
        let facts = StageFacts(role: .author, waitingFor: "Waiting on Priya", votes: "", commit: "a1b2c3d")
        let yours = StageMark(stage: .yourReview, at: t(100))
        let followed = StageMark(stage: .yourReview, at: t(150), by: Self.backoff)
        let onIt = StageMark(stage: .inProgress, at: t(200), by: Self.cart, commit: "a1b2c3d")
        #expect(yours.outlasts([followed, onIt]))
        #expect(!onIt.outlasts([]))

        let working = [Self.cart: Self.session(.working, at: 150)]
        let over = StageRules.reading(facts: facts, sessions: [], marks: [yours, onIt], order: .free, setters: working)
        #expect(over?.mark == onIt && over?.replaced == yours && over?.replacedOutlasts == true)

        let finished = [Self.cart: Self.session(.finished, at: 300)]
        let ended = StageRules.counted(yours: yours, theirs: [followed, onIt], facts: facts, sessions: [], setters: finished)
        #expect(ended.latestEnded && ended.yours == yours && ended.theirs == [followed])
        var pushed = facts
        pushed.commit = "e4f5a6b"
        let afterPush = StageRules.counted(yours: yours, theirs: [onIt], facts: pushed, sessions: [])
        #expect(afterPush.latestEnded && afterPush.yours == yours && afterPush.theirs.isEmpty)
        #expect(Self.reading(pushed, marks: [yours])?.isSetByYou == true)

        let teammate = StageMark(stage: .teammateReview, at: t(150), by: Self.backoff, votes: "")
        #expect(!yours.outlasts([teammate, onIt]))
        let replaced = StageRules.reading(facts: facts, sessions: [], marks: [yours, teammate, onIt], order: .free, setters: working)
        #expect(replaced?.replaced == yours && replaced?.replacedOutlasts == false)
        let gone = StageRules.counted(yours: yours, theirs: [teammate, onIt], facts: pushed, sessions: [])
        #expect(gone.latestEnded && gone.yours == nil && gone.theirs.isEmpty)
        let yourTeammates = StageMark(stage: .teammateReview, at: t(100))
        #expect(!yourTeammates.outlasts([onIt]))
        #expect(StageRules.counted(yours: yourTeammates, theirs: [onIt], facts: pushed, sessions: []).yours == nil)
        let merged = StageFacts(role: .author, state: .merged)
        #expect(StageRules.counted(yours: yours, theirs: [onIt], facts: merged, sessions: []).yours == nil)
    }

    @Test func aSetTeammatesReviewEndsAsOthersVotesChange() {
        let mark = StageMark(stage: .teammateReview, at: t(100), votes: "0", commit: "a1b2c3d")
        #expect(StageRules.stands(mark, facts: StageFacts(role: .author, votes: "0", commit: "e4f5a6b"), sessions: []))
        let approved = StageFacts(role: .author, isReady: true, othersVoted: true, votes: "10")
        #expect(!StageRules.stands(mark, facts: approved, sessions: []))
        #expect(Self.reading(approved, marks: [mark])?.stage == .canMerge)
        let wanted = StageFacts(role: .author, changesWanted: "Priya wants changes", othersVoted: true, votes: "-5")
        #expect(Self.reading(wanted, marks: [mark])?.stage == .teammateReview)
        #expect(Self.why(Self.reading(wanted, marks: [mark])) == "Find a reviewer · Priya wants changes")
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

    /// A Your review a session set ends as its votes change, as read since it was set, as Teammate's review does: it said
    /// its work was ready for you, as ‘Cart’ finished does, which gives way once someone else votes. Approved and ready to
    /// complete, it moves on to Can merge, or Waits where its order puts it after one not seen merged. On someone else's,
    /// your own vote ends it. One you set keeps no votes, and stands.
    @Test func aSessionsYourReviewEndsAsItsVotesChange() {
        let set = StageFacts(role: .author, waitingFor: "Waiting on Priya", votes: "", readAt: t(90))
        let ready = StageRules.mark(.yourReview, at: t(100), facts: set, by: Self.cart)
        #expect(ready == StageMark(stage: .yourReview, at: t(100), by: Self.cart, votes: ""))
        let yours = StageRules.mark(.yourReview, at: t(100), facts: set)
        #expect(yours == StageMark(stage: .yourReview, at: t(100)))
        #expect(StageRules.stands(ready, facts: StageFacts(role: .author, votes: "", readAt: t(120)), sessions: []))

        // Priya's approval ends it once it's read since.
        var approved = StageFacts(role: .author, isReady: true, othersVoted: true, votes: "10", readAt: t(99))
        #expect(StageRules.stands(ready, facts: approved, sessions: []))
        approved.readAt = t(120)
        #expect(!StageRules.stands(ready, facts: approved, sessions: []))
        #expect(Self.reading(approved, marks: [ready])?.stage == .canMerge)
        let waits = Self.reading(approved, marks: [ready], order: .waits([Self.pr(4102)], words: "After !4102"))
        #expect(waits?.stage == .waits)
        #expect(waits?.why == .waitsFor([Self.pr(4102)], words: "After !4102"))
        #expect(Self.reading(approved, marks: [yours])?.stage == .yourReview)
        #expect(Self.reading(approved, marks: [yours])?.mark == yours)

        let theirs = StageFacts(role: .reviewer, asksYou: "Priya asked you", votes: "0", readAt: t(90))
        let review = StageRules.mark(.yourReview, at: t(100), facts: theirs, by: Self.cart)
        #expect(review.votes == "0")
        var voted = theirs
        voted.votes = "10"
        voted.readAt = t(120)
        #expect(!StageRules.stands(review, facts: voted, sessions: []))
    }

    /// A session that read the pull request itself, just now, set its stage with what it saw: what the source read before,
    /// its votes and commit, ends nothing until it reads them again.
    @Test func votesAndCommitsCountOnlyAsReadSinceItWasSet() {
        let onIt = StageMark(stage: .inProgress, at: t(100), by: Self.cart, commit: "e4f5a6b")
        var before = StageFacts(role: .author, commit: "a1b2c3d", readAt: t(90))
        #expect(StageRules.stands(onIt, facts: before, sessions: []))
        before.readAt = t(100)
        #expect(!StageRules.stands(onIt, facts: before, sessions: []))
        // A session that finishes since ends it, however long ago the source read the pull request.
        before.readAt = t(90)
        #expect(!StageRules.stands(onIt, facts: before, sessions: [Self.session(.finished, at: 150)]))

        let reviewed = StageMark(stage: .teammateReview, at: t(100), by: Self.cart, votes: "10")
        let unread = StageFacts(role: .author, votes: "", readAt: t(99))
        #expect(StageRules.stands(reviewed, facts: unread, sessions: []))
        #expect(Self.reading(unread, marks: [reviewed])?.mark == reviewed)
        let read = StageFacts(role: .author, isReady: true, othersVoted: true, votes: "10,10", readAt: t(120))
        #expect(!StageRules.stands(reviewed, facts: read, sessions: []))
        #expect(Self.reading(read, marks: [reviewed])?.stage == .canMerge)
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
    /// not, until BriefBar sees it merge, then holds until it's retargeted: completing it first would merge it into the
    /// other's branch.
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
        #expect(StageOrder.of(Self.pr(4102), in: merged) == .holds("!4101 merged: retarget it to main"))
        let retargeted = Self.missions(
            [OrderBoardTests.ado(4101, from: "robin/rounding", state: .merged), OrderBoardTests.ado(4102, from: "robin/cart")],
            plan: [.init(ref: Self.pr(4101)), .init(ref: Self.pr(4102))]
        )
        #expect(StageOrder.of(Self.pr(4102), in: retargeted) == .free)
    }

    /// One whose order names only it waits for the pull request whose branch it targets, until BriefBar sees that one
    /// merge, then holds until it's retargeted, whether no order names that one or another order does.
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
        #expect(StageOrder.of(Self.pr(4102), in: merged) == .holds("!4101 merged: retarget it to main"))
        let retargeted = Self.missions(
            [OrderBoardTests.ado(4101, from: "robin/rounding", state: .merged), OrderBoardTests.ado(4102, from: "robin/cart")],
            plan: [.init(ref: Self.pr(4102))]
        )
        #expect(StageOrder.of(Self.pr(4102), in: retargeted) == .free)
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

    /// Where why it's in its stage names the session that set it, a session's Your review or In progress, who set it says
    /// only when, on its row and in its details, in its tooltip and to VoiceOver: "‘Cart’ says it's ready · set 5m ago".
    /// Elsewhere, who set it names the session: its words for a session's Teammate's review say who it waits on. Where a
    /// session's replaced yours, each says "after you", the tooltip and its menu's first line too.
    @Test func whoSetItDoesntNameTheSessionAgainWhereWhyItsInItsStageDoes() {
        let facts = StageFacts(role: .author, votes: "0")
        let yours = StageMark(stage: .teammateReview, at: t(100), votes: "0")
        let ready = Self.reading(facts, marks: [yours, StageMark(stage: .yourReview, at: t(200), by: Self.cart)])!
        #expect(Self.why(ready) == "‘Cart’ says it's ready" && StageText.namesWhoSetIt(ready))
        #expect(StageText.who(ready, now: t(500), name: Self.name) == "set 5m ago, after you")
        #expect(StageText.spokenWho(ready, now: t(500), name: Self.name) == "set 5 minutes ago, after you")
        #expect(StageText.sentence(ready, now: t(500), name: Self.name) == "Your review: ‘Cart’ says it's ready. Set 5m ago, after you.")

        let onIt = Self.reading(facts, marks: [StageMark(stage: .inProgress, at: t(200), by: Self.cart)])!
        #expect(Self.why(onIt) == "‘Cart’ is on it")
        #expect(StageText.who(onIt, now: t(200), name: Self.name) == "set just now")
        #expect(StageText.sentence(onIt, now: t(200), name: Self.name) == "In progress: ‘Cart’ is on it. Set just now.")

        let teammates = Self.reading(facts, marks: [StageMark(stage: .teammateReview, at: t(200), by: Self.cart, votes: "0")])!
        #expect(Self.why(teammates) == "Find a reviewer" && !StageText.namesWhoSetIt(teammates))
        #expect(StageText.who(teammates, now: t(500), name: Self.name) == "‘Cart’ set it 5m ago")
        #expect(StageText.spokenWho(teammates, now: t(500), name: Self.name) == "set by ‘Cart’ 5 minutes ago")
        #expect(StageText.sentence(teammates, now: t(500), name: Self.name) == "Teammate's review: Find a reviewer. ‘Cart’ set it 5m ago.")
        // Nor where its words are only its stage's title, as `reason` words a set stage it doesn't name a session for.
        let titled = StageReading(stage: .teammateReview, why: .set, mark: StageMark(stage: .teammateReview, at: t(200), by: Self.cart))
        #expect(Self.why(titled) == "Teammate's review")
        #expect(StageText.who(titled, now: t(500), name: Self.name) == "‘Cart’ set it 5m ago")
        // Yours names you: its words never name who set it.
        let mine = Self.reading(facts, marks: [StageMark(stage: .yourReview, at: t(200))])!
        #expect(Self.why(mine) == "Waiting for your review")
        #expect(StageText.who(mine, now: t(500), name: Self.name) == "You set it 5m ago")
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
        #expect(PullRequestStage.allCases.map(\.step) == [0, 1, 2, 3, 4, 4, 5])
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
    /// in, Put Yours Back once a session's change replaced yours, and Let BriefBar Decide for one you set, also where a
    /// session's Your review that says the same shows in its place; nothing once it merged. Someone else's that you
    /// finished reviewing is in Teammate's review: moving it there again would do nothing.
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

        // A session's later Your review that followed yours, as one that pushed says its work is ready, keeps no votes, and
        // shows in its place: Let BriefBar Decide forgets both. A session's own, with its votes, follows nothing; another
        // stage that says the same ends as yours would anyway.
        let yours = StageMark(stage: .yourReview, at: t(10))
        let followed = Self.reading(StageFacts(role: .author), marks: [yours, StageMark(stage: .yourReview, at: t(20), by: Self.cart)])!
        #expect(followed.mark?.by == Self.cart && followed.replaced == nil && followed.followed == yours)
        #expect(followed.canLetBriefBarDecide && !followed.isSetByYou)
        #expect(StageAction.offered(for: followed) == [.finishedReview, .move(.inProgress), .move(.teammateReview), .letBriefBarDecide])
        let own = Self.reading(StageFacts(role: .author), marks: [yours, StageMark(stage: .yourReview, at: t(20), by: Self.cart, votes: "")])!
        #expect(own.mark?.by == Self.cart && own.followed == nil && !own.canLetBriefBarDecide)
        let same = Self.reading(
            StageFacts(role: .author),
            marks: [StageMark(stage: .teammateReview, at: t(10)), StageMark(stage: .teammateReview, at: t(20), by: Self.cart)]
        )!
        #expect(same.followed == nil && !same.canLetBriefBarDecide)
        #expect(StageAction.offered(for: same) == [.move(.inProgress), .move(.yourReview)])
        let onIt = Self.reading(
            StageFacts(role: .author),
            marks: [StageMark(stage: .inProgress, at: t(10)), StageMark(stage: .inProgress, at: t(20), by: Self.cart)]
        )!
        #expect(onIt.followed == nil && !onIt.canLetBriefBarDecide)
        #expect(StageAction.offered(for: onIt) == [.move(.yourReview), .move(.teammateReview)])
        let alone = Self.reading(StageFacts(role: .author), marks: [StageMark(stage: .yourReview, at: t(20), by: Self.cart)])!
        #expect(alone.followed == nil && !alone.canLetBriefBarDecide)

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
