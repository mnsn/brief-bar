import Foundation
import Testing
@testable import BriefBarCore

/// Your changes to missions (`OrderChanges`), over what BriefBar sees and what sessions tell it.
@Suite struct OrderChangesTests {
    private let planID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let otherID = UUID(uuidString: "22222222-3333-4444-8555-666666666666")!
    static let session = ItemRef.session("6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b")!

    static func pr(_ number: Int) -> ItemRef { OrderPlansTests.pr(number) }

    /// An Azure DevOps pull request on a branch of its own, into main unless said.
    static func ado(_ number: Int, into target: String = "main", state: PullRequestState = .open) -> OrderPullRequest {
        OrderBoardTests.ado(number, from: "users/robin/part-\(number)", into: target, state: state)
    }

    static func facts(_ numbers: [Int], sessions: [OrderSession] = []) -> OrderFacts {
        OrderFacts(pullRequests: numbers.map { ado($0) }, sessions: sessions)
    }

    /// An order of these pull requests, each after the ones given, told by the session.
    func tell(_ entries: [(Int, [Int])], replacing orders: DeclaredOrders = DeclaredOrders(), id: UUID? = nil, at seconds: Double = 0)
        throws -> DeclaredOrders {
        var orders = orders
        let id = id ?? planID
        let request = OrderRequest(
            plan: orders.plan(id).map { _ in id.uuidString }, revision: orders.plan(id)?.revision, session: Self.session.id,
            entries: entries.map { number, after in .init(link: OrderPlansTests.link(number), after: after.map(String.init)) }
        )
        try orders.apply(request, now: t(seconds), newID: id)
        return orders
    }

    static func missions(_ facts: OrderFacts, _ orders: DeclaredOrders, _ changes: OrderChanges, evidence: OrderEvidence = OrderEvidence())
        -> [OrderMission] {
        OrderBoard.missions(facts: facts, orders: orders, evidence: evidence, changes: changes, now: t(3_600))
    }

    static func mission(_ key: MissionKey, in missions: [OrderMission]) throws -> OrderMission {
        try #require(missions.first { $0.key == key })
    }

    static func step(_ number: Int, in mission: OrderMission) throws -> OrderStep {
        try #require((mission.steps + mission.attached).first { $0.ref == pr(number) })
    }

    // MARK: Set as Next

    @Test func setAsNextMakesItFirstAndWhatWaitedForNothingWaitsForIt() throws {
        var orders = try tell([(4101, []), (4102, [4101]), (4103, [4102])])
        let facts = Self.facts([4101, 4102, 4103])
        var changes = OrderChanges()
        try changes.apply(.setNext(Self.pr(4103), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))

        var mission = try Self.mission(.plan(planID), in: Self.missions(facts, orders, changes))
        #expect(OrderBoardTests.summary(mission.steps) == ["1 !4103 Next to merge", "2 !4101 Merge after !4103", "3 !4102 Merge after !4101"])
        let next = try Self.step(4103, in: mission)
        #expect(next.isYours && next.isChangedByYou && next.notes == [.yourNext(t(60))])
        #expect(OrderText.note(next.notes[0], of: next.ref, names: OrderNames(now: t(3_660))) == "You set it as next to merge · 1h")
        let first = try Self.step(4101, in: mission)
        #expect(first.isYours && !first.isChangedByYou)
        #expect(first.prerequisites == [OrderPrerequisite(ref: Self.pr(4103), origins: [.yourNext], status: .open)])
        #expect(first.notes.map { OrderText.note($0, of: first.ref) } == ["You set !4103 as next to merge"])
        #expect(!(try Self.step(4102, in: mission)).isYours)
        #expect(mission.changedByYou == 1)
        #expect(OrderText.kind(of: mission) == "changed by you")
        #expect(OrderText.told(mission) { $0 == Self.session ? "Fix the payments bugs" : nil }
            == "Told by ‘Fix the payments bugs’ · you changed 1 of its pull requests")

        // As the mission changes: one the session adds later, that waits for nothing, waits for it too.
        orders = try tell([(4101, []), (4102, [4101]), (4103, [4102]), (4104, [])], replacing: orders, at: 120)
        mission = try Self.mission(.plan(planID), in: Self.missions(Self.facts([4101, 4102, 4103, 4104]), orders, changes))
        #expect(try Self.step(4104, in: mission).prerequisites.map(\.ref) == [Self.pr(4103)])
        #expect(try Self.step(4103, in: mission).standing == .next)

        // One for each mission: setting another takes it away.
        let missions = Self.missions(Self.facts([4101, 4102, 4103, 4104]), orders, changes)
        let touched = try changes.apply(.setNext(Self.pr(4104), in: .plan(planID), true), missions: missions, orders: orders, now: t(180))
        #expect(Set(touched.keys) == [Self.pr(4103), Self.pr(4104)])
        #expect(changes[Self.pr(4103)] == nil && changes[Self.pr(4104)]?.isFirst == true)
    }

    @Test func setAsNextIsRefusedForOneStackedOnAPullRequestThatHasntMerged() throws {
        let orders = try tell([(4101, []), (4102, [4101])])
        let facts = OrderFacts(pullRequests: [Self.ado(4101), OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/part-4101")])
        var changes = OrderChanges()
        let missions = Self.missions(facts, orders, changes)
        let choices = MissionChoices.of(Self.pr(4102), missions: missions, changes: changes, orders: orders)
        #expect(choices.next == .stacked(on: Self.pr(4101)))
        #expect(choices.prerequisites == [MissionChoices.Prerequisite(ref: Self.pr(4101), state: .stacked)])
        #expect(throws: OrderChangeError.stacked(on: Self.pr(4101))) {
            try changes.apply(.setNext(Self.pr(4102), in: .plan(planID), true), missions: missions, orders: orders, now: t(60))
        }
        #expect(throws: OrderChangeError.stacked(on: Self.pr(4101))) {
            try changes.apply(.mergeAfter(Self.pr(4102), Self.pr(4101), in: .plan(planID), false), missions: missions, orders: orders)
        }
        // Nor can the one under it go after it.
        #expect(MissionChoices.of(Self.pr(4101), missions: missions, changes: changes, orders: orders).prerequisites
            == [MissionChoices.Prerequisite(ref: Self.pr(4102), state: .waitsForIt)])
        #expect(throws: OrderChangeError.waitsForIt(Self.pr(4102))) {
            try changes.apply(.mergeAfter(Self.pr(4101), Self.pr(4102), in: .plan(planID), true), missions: missions, orders: orders)
        }
        #expect(OrderChangeError.stacked(on: Self.pr(4101)).description
            == "Stacked on !4101: it can't merge before it unless you retarget it.")
        #expect(changes.isEmpty)
    }

    // MARK: The latest change wins

    @Test func aSessionTellingItsOrderAgainKeepsYourChangeAndOneThatChangesItsPlaceWins() throws {
        var orders = try tell([(4101, []), (4102, [4101]), (4103, [4102])])
        let facts = Self.facts([4101, 4102, 4103])
        var changes = OrderChanges()
        try changes.apply(.setNext(Self.pr(4103), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))
        let change = try #require(changes[Self.pr(4103)])
        #expect(change.replaced == OrderPlace(orders: [planID: [Self.pr(4102)]]))

        // Told again, the same, in another sequence, or with other review advice: what it says of 4103 didn't change.
        orders = try tell([(4101, []), (4102, [4101]), (4103, [4102])], replacing: orders, at: 100)
        #expect(change.holds(in: orders))
        orders = try tell([(4103, [4102]), (4102, [4101]), (4101, [])], replacing: orders, at: 110)
        #expect(change.holds(in: orders))
        let request = OrderRequest(
            plan: planID.uuidString, revision: orders.plan(planID)?.revision, session: Self.session.id,
            entries: [.init(link: OrderPlansTests.link(4101)), .init(link: OrderPlansTests.link(4102), after: ["4101"]),
                      .init(link: OrderPlansTests.link(4103), after: ["4102"], review: .after(["4102"], reason: "same_code"))]
        )
        try orders.apply(request, now: t(115))
        #expect(change.holds(in: orders))
        #expect(try Self.mission(.plan(planID), in: Self.missions(facts, orders, changes)).steps.first?.ref == Self.pr(4103))

        // A revision that changes what 4103 merges after changed its place after you did: it shows instead, and says so.
        orders = try tell([(4101, []), (4102, [4101]), (4103, [4101])], replacing: orders, at: 120)
        #expect(!change.holds(in: orders))
        var missions = Self.missions(facts, orders, changes)
        var step = try Self.step(4103, in: Self.mission(.plan(planID), in: missions))
        #expect(step.standing == .waiting(open: [Self.pr(4101)], unknown: []))
        #expect(!step.isYours)
        let names = OrderNames(name: { $0 == Self.session ? "Fix the payments bugs" : nil }, now: t(420))
        #expect(step.notes.map { OrderText.note($0, of: step.ref, names: names) }
            == ["‘Fix the payments bugs’ put it after !4101 · 5m, after you'd set it as next"])
        #expect(MissionChoices.of(Self.pr(4103), missions: missions, changes: changes, orders: orders).canPutBack)

        // Put Yours Back: yours holds again, over the place the order gives it now, until it changes that again.
        try changes.apply(.putBack(Self.pr(4103)), missions: missions, orders: orders, now: t(500))
        #expect(changes[Self.pr(4103)]?.replaced == OrderPlace(orders: [planID: [Self.pr(4101)]]))
        missions = Self.missions(facts, orders, changes)
        step = try Self.step(4103, in: Self.mission(.plan(planID), in: missions))
        #expect(step.standing == .next && step.isYours)

        // Another order naming it too goes against nothing of yours: it's still next in this one.
        let alsoNamed = try tell([(4103, [])], replacing: orders, id: otherID, at: 550)
        #expect(changes[Self.pr(4103)]?.holds(in: alsoNamed) == true)
        #expect(try Self.mission(.plan(planID), in: Self.missions(facts, alsoNamed, changes)).steps.first?.ref == Self.pr(4103))

        // A session that takes it out of the order you set it as next in goes against yours.
        orders = try tell([(4101, []), (4102, [4101])], replacing: orders, at: 600)
        #expect(changes[Self.pr(4103)]?.overridden(in: orders)
            == OrderOverride(by: Self.session, at: t(600), now: .out, yours: .next))
        // Forgetting an order is no change of its place.
        var forgotten = orders
        forgotten.forget(planID)
        #expect(changes[Self.pr(4103)]?.holds(in: forgotten) == true)
    }

    @Test func oneThatOnlyTookAwayWhatTheOrderNoLongerSaysChangesNothingAndSaysNothing() throws {
        var orders = try tell([(4101, []), (4102, [4101])])
        let facts = Self.facts([4101, 4102])
        var changes = OrderChanges()
        try changes.apply(
            .mergeAfter(Self.pr(4102), Self.pr(4101), in: .plan(planID), false), missions: Self.missions(facts, orders, changes),
            orders: orders, now: t(60)
        )
        #expect(changes[Self.pr(4102)]?.notAfter == [Self.pr(4101)])
        var step = try Self.step(4102, in: Self.mission(.plan(planID), in: Self.missions(facts, orders, changes)))
        #expect(step.standing == .anyTime && step.isYours)
        #expect(step.notes.map { OrderText.note($0, of: step.ref) } == ["Its order puts it after !4101; you took that away"])

        orders = try tell([(4101, []), (4102, [])], replacing: orders, at: 120)
        // The order took away what you did: that agrees with yours, which holds, changing nothing and saying nothing.
        #expect(changes[Self.pr(4102)]?.holds(in: orders) == true)
        #expect(changes[Self.pr(4102)]?.overridden(in: orders) == nil)
        step = try Self.step(4102, in: Self.mission(.plan(planID), in: Self.missions(facts, orders, changes)))
        #expect(step.notes.isEmpty && !step.isYours && !step.isChangedByYou)
        #expect(!MissionChoices.of(Self.pr(4102), missions: Self.missions(facts, orders, changes), changes: changes, orders: orders).canPutBack)

        // Once BriefBar saw that, putting it after 4101 again goes against yours: it shows, and says so.
        let noted = changes.noteOverrides(in: orders, now: t(120))
        #expect(noted && changes[Self.pr(4102)]?.replaced == OrderPlace(orders: [planID: []]))
        orders = try tell([(4101, []), (4102, [4101])], replacing: orders, at: 180)
        #expect(changes[Self.pr(4102)]?.overridden(in: orders)
            == OrderOverride(by: Self.session, at: t(180), now: .after([Self.pr(4101)]), yours: .tookAway([Self.pr(4101)])))
    }

    // MARK: Merge After

    @Test func mergeAfterChecksYoursAndUnchecksTheOrders() throws {
        let orders = try tell([(4101, []), (4102, [4101]), (4103, [4101])])
        let facts = Self.facts([4101, 4102, 4103])
        var changes = OrderChanges()
        try changes.apply(.mergeAfter(Self.pr(4102), Self.pr(4103), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))
        var missions = Self.missions(facts, orders, changes)
        var mission = try Self.mission(.plan(planID), in: missions)
        #expect(OrderBoardTests.summary(mission.steps) == ["1 !4101 Next to merge", "2 !4103 Merge after !4101", "3 !4102 Merge after !4103"])
        let step = try Self.step(4102, in: mission)
        #expect(step.prerequisites.map(\.origins) == [[.declared(revision: 1)], [.yours]])
        #expect(step.notes == [.yourAfter([Self.pr(4103)], t(60))])
        #expect(OrderText.origin(.yours, earlier: Self.pr(4103), later: step.ref) == "You put it after !4103")
        // 4103 can't go after 4102 now: 4102 waits for it, by your change.
        #expect(MissionChoices.of(Self.pr(4103), missions: missions, changes: changes, orders: orders).prerequisites == [
            MissionChoices.Prerequisite(ref: Self.pr(4101), state: .checked),
            MissionChoices.Prerequisite(ref: Self.pr(4102), state: .waitsForIt),
        ])

        try changes.apply(.mergeAfter(Self.pr(4102), Self.pr(4101), in: .plan(planID), false), missions: missions, orders: orders, now: t(70))
        #expect(changes[Self.pr(4102)]?.after == [Self.pr(4103)] && changes[Self.pr(4102)]?.notAfter == [Self.pr(4101)])
        try changes.apply(.mergeAfter(Self.pr(4102), Self.pr(4103), in: .plan(planID), false), missions: missions, orders: orders, now: t(80))
        missions = Self.missions(facts, orders, changes)
        mission = try Self.mission(.plan(planID), in: missions)
        #expect(try Self.step(4102, in: mission).standing == .anyTime)

        // Merge After on the one you set as next takes that away.
        try changes.apply(.setNext(Self.pr(4103), in: .plan(planID), true), missions: missions, orders: orders, now: t(90))
        missions = Self.missions(facts, orders, changes)
        try changes.apply(.mergeAfter(Self.pr(4103), Self.pr(4102), in: .plan(planID), true), missions: missions, orders: orders, now: t(95))
        #expect(changes[Self.pr(4103)]?.isFirst == false && changes[Self.pr(4103)]?.after == [Self.pr(4102)])
    }

    @Test func anOrdersLineThatGoesRoundWithYoursIsSetAside() throws {
        let orders = try tell([(4101, []), (4102, [4101])])
        let facts = Self.facts([4101, 4102])
        var changes = OrderChanges()
        try changes.apply(.mergeAfter(Self.pr(4101), Self.pr(4102), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))
        // Yours put 4101 after 4102: the order's 4102 after 4101 goes round with it, and is set aside.
        let mission = try Self.mission(.plan(planID), in: Self.missions(facts, orders, changes))
        #expect(OrderBoardTests.summary(mission.steps) == ["1 !4102 Next to merge", "2 !4101 Merge after !4102"])
        #expect(mission.cycles.isEmpty)
        let names = OrderNames(name: { $0 == Self.session ? "Fix the payments bugs" : nil })
        #expect(try Self.step(4102, in: mission).notes.map { OrderText.note($0, of: Self.pr(4102), names: names) }
            == ["‘Fix the payments bugs’ puts it after !4101; you put !4101 after it"])
    }

    @Test func aStackedBranchThatAppearsLaterWinsOverYours() throws {
        let orders = try tell([(4101, []), (4102, [])])
        var changes = OrderChanges()
        let before = Self.facts([4101, 4102])
        try changes.apply(.mergeAfter(Self.pr(4101), Self.pr(4102), in: .plan(planID), true), missions: Self.missions(before, orders, changes), orders: orders, now: t(60))
        // Then 4102 is retargeted to 4101's branch: it's stacked on it.
        let after = OrderFacts(pullRequests: [Self.ado(4101), Self.ado(4102, into: "users/robin/part-4101")])
        let mission = try Self.mission(.plan(planID), in: Self.missions(after, orders, changes))
        #expect(OrderBoardTests.summary(mission.steps) == ["1 !4101 Next to merge", "2 !4102 Merge after !4101"])
        let step = try Self.step(4101, in: mission)
        #expect(step.notes == [.yoursDoesntHold(Self.pr(4102), stacked: true)])
        #expect(OrderText.note(step.notes[0], of: step.ref) == "!4102 is stacked on it now, so your ‘after !4102’ doesn't hold")
    }

    // MARK: Move to Mission

    @Test func aPullRequestYouMoveShowsOnlyWhereYouPutItWithNoOrderKnownUntilYouSay() throws {
        let orders = try tell([(4101, []), (4102, [4101])])
        let opener = ItemRef.session("7a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9")!
        let facts = Self.facts([4101, 4102, 4110, 4111], sessions: [
            OrderSession(ref: opener, pullRequests: [Self.pr(4110), Self.pr(4111)]),
        ])
        var changes = OrderChanges()
        var missions = Self.missions(facts, orders, changes)
        #expect(Set(missions.map(\.key)) == [.plan(planID), .family(opener)])

        try changes.apply(.move([Self.pr(4102)], to: .into(.family(opener)), from: .plan(planID)), missions: missions, orders: orders, now: t(60))
        missions = Self.missions(facts, orders, changes)
        let order = try Self.mission(.plan(planID), in: missions)
        #expect(OrderBoardTests.summary(order.steps) == ["– !4101 Any time"])
        var family = try Self.mission(.family(opener), in: missions)
        // Without an order, by when each was opened, as a session's pull requests are.
        #expect(family.steps.map(\.ref) == [Self.pr(4102), Self.pr(4110), Self.pr(4111)])
        #expect(family.steps.allSatisfy { $0.standing == .unordered })
        #expect(OrderText.kind(of: family) == "changed by you")
        let moved = try Self.step(4102, in: family)
        let names = OrderNames(title: { $0 == .plan(planID) ? "Fix the payments bugs" : nil })
        #expect(moved.notes.map { OrderText.note($0, of: moved.ref, names: names) } == ["You moved it here from ‘Fix the payments bugs’"])
        // By Status gives its row a quiet ✎ that says so, and shows its mission.
        #expect(moved.isYours && OrderBoard.step(for: Self.pr(4102), in: missions)?.mission.key == .family(opener))
        #expect(OrderBoard.step(for: Self.pr(4110), in: missions) == nil)

        // Merge After orders it among them; the rest still have no order known.
        try changes.apply(.mergeAfter(Self.pr(4102), Self.pr(4110), in: .family(opener), true), missions: missions, orders: orders, now: t(70))
        missions = Self.missions(facts, orders, changes)
        family = try Self.mission(.family(opener), in: missions)
        #expect(OrderBoardTests.summary(family.steps) == ["1 !4110 Next to merge", "2 !4102 Merge after !4110", "– !4111 "])
        #expect(family.hasOrder)

        // New Mission, and Not in a Mission.
        let mine = UUID(uuidString: "33333333-4444-4555-8666-777777777777")!
        try changes.apply(.move([Self.pr(4111)], to: .into(.mine(mine)), from: nil), missions: missions, orders: orders, now: t(80))
        try changes.apply(.move([Self.pr(4101)], to: .outside, from: nil), missions: missions, orders: orders, now: t(90))
        missions = Self.missions(facts, orders, changes)
        let yours = try Self.mission(.mine(mine), in: missions)
        #expect(yours.kind == .mine && yours.steps.map(\.ref) == [Self.pr(4111)] && OrderText.kind(of: yours) == "Your mission")
        #expect(OrderText.title(of: yours) { $0 == Self.pr(4111) ? "Log the coupon rounding" : nil } == "Log the coupon rounding")
        #expect(!missions.contains { $0.contains(Self.pr(4101)) })
        #expect(MissionChoices.of(Self.pr(4101), missions: missions, changes: changes, orders: orders).mission == nil)
        // The order you moved all of out of shows no more.
        #expect(!missions.contains { $0.key == .plan(planID) })
        #expect(OrderFocus.kept(.mine(mine), in: orders, changes: changes) == .mine(mine))
        #expect(OrderFocus.kept(.mine(mine), in: orders) == nil)
    }

    @Test func thoseYouPutInAnOrderThatsGoneStayTogetherAsAMissionOfYours() throws {
        var orders = try tell([(4101, []), (4102, [])])
        orders = try tell([(4103, [])], replacing: orders, id: otherID, at: 10)
        let facts = Self.facts([4101, 4102, 4103])
        var changes = OrderChanges()
        try changes.apply(
            .move([Self.pr(4101), Self.pr(4102)], to: .into(.plan(otherID)), from: .plan(planID)),
            missions: Self.missions(facts, orders, changes), orders: orders, now: t(60)
        )
        var missions = Self.missions(facts, orders, changes)
        #expect(try Self.mission(.plan(otherID), in: missions).steps.map(\.ref) == [Self.pr(4103), Self.pr(4101), Self.pr(4102)])

        orders.forget(otherID)
        missions = Self.missions(facts, orders, changes)
        let yours = try Self.mission(.plan(otherID), in: missions)
        #expect(yours.kind == .mine && yours.steps.map(\.ref) == [Self.pr(4101), Self.pr(4102)])
        #expect(yours.steps.allSatisfy { $0.notes == [.placementGone(.plan(otherID))] })
        #expect(OrderText.note(.placementGone(.plan(otherID)), of: Self.pr(4101)) == "Its order is gone: you'd put it here")
    }

    @Test func aChainIsNamedByOneOfItsPullRequestsAndGoesOnByAnotherAsItEnds() throws {
        let chain = [
            OrderBoardTests.ado(4101, from: "users/robin/a"), OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a"),
            OrderBoardTests.ado(4103, from: "users/robin/c", into: "users/robin/b"),
        ]
        var facts = OrderFacts(pullRequests: chain + [Self.ado(4110)])
        var changes = OrderChanges()
        var missions = Self.missions(facts, DeclaredOrders(), changes)
        try changes.apply(.move([Self.pr(4110)], to: .into(.chain(Self.pr(4101))), from: nil), missions: missions, orders: DeclaredOrders(), now: t(60))
        missions = Self.missions(facts, DeclaredOrders(), changes)
        #expect(try Self.mission(.chain(Self.pr(4101)), in: missions).steps.map(\.ref).last == Self.pr(4110))

        // 4101 merged, and Done lists it a day: the chain goes on by the next of its own.
        var merged = chain
        merged[0].state = .merged
        facts = OrderFacts(pullRequests: merged + [Self.ado(4110)])
        missions = Self.missions(facts, DeclaredOrders(), changes)
        let moved = changes.moveAnchors(in: missions)
        #expect(moved == [Self.pr(4101): Self.pr(4102)])
        #expect(changes[Self.pr(4110)]?.placement == .into(.chain(Self.pr(4102))))
        // Once no list has 4101, the chain is still where you put it.
        facts = OrderFacts(pullRequests: Array(chain.dropFirst()) + [Self.ado(4110)])
        missions = Self.missions(facts, DeclaredOrders(), changes)
        #expect(try Self.mission(.chain(Self.pr(4102)), in: missions).steps.map(\.ref) == [Self.pr(4102), Self.pr(4103), Self.pr(4110)])
    }

    // MARK: Undo

    @Test func undoPutsBackExactlyWhatAChangeTouched() throws {
        let orders = try tell([(4101, []), (4102, [4101]), (4103, [4101])])
        let facts = Self.facts([4101, 4102, 4103])
        var changes = OrderChanges()
        try changes.apply(.setNext(Self.pr(4102), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))
        let before = changes
        let touched = try changes.apply(.setNext(Self.pr(4103), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(70))
        #expect(touched == [Self.pr(4102): before[Self.pr(4102)], Self.pr(4103): OrderChange?.none])
        changes.restore(touched)
        #expect(changes == before)

        // Undo Your Changes to This Mission: its pull requests', those you put in it, and those you moved out of it.
        let missions = Self.missions(facts, orders, changes)
        try changes.apply(.move([Self.pr(4103)], to: .outside, from: .plan(planID)), missions: missions, orders: orders, now: t(80))
        #expect(changes.count == 2)
        try changes.apply(.undoMission(.plan(planID)), missions: Self.missions(facts, orders, changes), orders: orders, now: t(90))
        #expect(changes.isEmpty)
        #expect(OrderText.did(.setNext(Self.pr(4102), in: .plan(planID), true)) == "You set !4102 as next to merge")
        #expect(OrderText.did(.move([Self.pr(4111)], to: .into(.mine(UUID())), from: nil), newMission: true) == "You made a mission of !4111")
        #expect(OrderText.spoken("You set !4102 as next to merge", undo: "in its mission")
            == "You set 4102 as next to merge. Undo is in its mission.")
    }

    // MARK: Keeping them

    @Test func theyreSavedAsReferencesCodesAndDatesAndReadBackWithoutWhatCantBeRead() throws {
        let defaults = MemorySettings()
        let changes = OrderChanges([
            OrderChange(ref: Self.pr(4103), first: .plan(planID), changedAt: t(60), replaced: OrderPlace(orders: [planID: [Self.pr(4102)]])),
            OrderChange(ref: Self.pr(4104), after: [Self.pr(4101)], notAfter: [Self.pr(4102)], placement: .into(.chain(Self.pr(4101))),
                        from: .plan(planID), changedAt: t(70)),
            OrderChange(ref: Self.pr(4105), placement: .outside, changedAt: t(80)),
        ])
        changes.save(to: defaults)
        #expect(OrderChanges.load(from: defaults) == changes)
        let text = try #require(defaults.data(forKey: OrderChanges.defaultsKey).flatMap { String(data: $0, encoding: .utf8) })
        #expect(text.contains("\"placed\":\"chain/pullRequest/contoso/4101\"") && text.contains("\"placed\":\"none\""))
        #expect(!text.contains("title"))

        // What another program wrote that can't be read is left out, and the rest kept.
        let odd = """
            [{"pullRequest":"pullRequest/contoso/4106","first":"\(MissionKey.plan(planID))","changedAt":0,
              "after":["nonsense","pullRequest/contoso/4106"]},
             {"pullRequest":"session//abc","first":"\(MissionKey.plan(planID))","changedAt":0},
             {"pullRequest":"pullRequest/contoso/4107","changedAt":0},
             {"pullRequest":"pullRequest/contoso/4108","first":true,"changedAt":0},
             {"first":true}]
            """
        defaults.set(Data(odd.utf8), forKey: OrderChanges.defaultsKey)
        #expect(OrderChanges.load(from: defaults).all.map(\.ref) == [Self.pr(4106)])
        #expect(OrderChanges.load(from: defaults)[Self.pr(4106)]?.after == [])
        #expect(OrderChanges.load(from: defaults)[Self.pr(4106)]?.first == .plan(planID))
        OrderChanges().save(to: defaults)
        #expect(defaults.object(forKey: OrderChanges.defaultsKey) == nil)
    }

    @Test func theFiveHundredAndFirstIsRefusedAndNoneIsDroppedToMakeRoom() throws {
        var changes = OrderChanges((1...OrderChanges.mostChanges).map { OrderChange(ref: Self.pr($0), placement: .outside, changedAt: t(0)) })
        #expect(throws: OrderChangeError.full) {
            try changes.set(OrderChange(ref: Self.pr(9_999), placement: .outside, changedAt: t(1)))
        }
        #expect(changes.count == OrderChanges.mostChanges)
        // Changing one it keeps is no new one.
        try changes.set(OrderChange(ref: Self.pr(1), first: .plan(planID), changedAt: t(2)))
        #expect(changes[Self.pr(1)]?.isFirst == true)
        #expect(OrderChangeError.full.description == "BriefBar keeps 500 of your changes: undo some first.")
    }

    @Test func oneGoesTwoWeeksAfterBriefBarSawItsPullRequestsEndAndNeverBefore() throws {
        var changes = OrderChanges([
            OrderChange(ref: Self.pr(4101), after: [Self.pr(4102)], changedAt: t(0)),
            OrderChange(ref: Self.pr(4103), first: .plan(planID), changedAt: t(0)),
        ])
        var evidence = OrderEvidence()
        evidence.observe(OrderObservation(ref: Self.pr(4101), state: .merged, witness: .list), at: t(100))
        evidence.observe(OrderObservation(ref: Self.pr(4103), state: .closed, witness: .list), at: t(100))
        let later = t(100 + OrderChanges.finishedFor + 1)
        // 4102 is open, or BriefBar can't see it: the change about it stays.
        var removed = changes.removeFinished(evidence: evidence, now: later)
        #expect(removed == [Self.pr(4103)])
        evidence.observe(OrderObservation(ref: Self.pr(4102), state: .merged, witness: .list), at: t(200))
        removed = changes.removeFinished(evidence: evidence, now: later)
        #expect(removed.isEmpty)
        removed = changes.removeFinished(evidence: evidence, now: t(200 + OrderChanges.finishedFor + 1))
        #expect(removed == [Self.pr(4101)])
        #expect(changes.isEmpty)
    }

    @Test func turningASourceOffForgetsItsPullRequestsAndItsMissions() throws {
        let stackKey = MissionKey.stack(repository: "octo/storefront", number: 41)
        var changes = OrderChanges([
            OrderChange(ref: Self.pr(4101), after: [OrderBoardTests.gh(212), Self.pr(4102)], placement: .into(stackKey), changedAt: t(0)),
            OrderChange(ref: OrderBoardTests.gh(213), first: .plan(planID), changedAt: t(0)),
            OrderChange(ref: Self.pr(4103), placement: .into(.family(Self.session)), from: .family(Self.session), changedAt: t(0)),
            OrderChange(ref: Self.pr(4104), placement: .into(.family(Self.session)), changedAt: t(0)),
        ])
        var forgot = changes.forget([.gitHubPullRequest])
        #expect(forgot)
        #expect(changes[OrderBoardTests.gh(213)] == nil)
        #expect(changes[Self.pr(4101)] == OrderChange(ref: Self.pr(4101), after: [Self.pr(4102)], changedAt: t(0)))
        forgot = changes.forget([.session])
        #expect(forgot)
        #expect(changes[Self.pr(4103)] == nil && changes[Self.pr(4104)] == nil)
        forgot = changes.forget([.workItem])
        #expect(!forgot)
    }

    /// `order.plans` keeps its format: an older `--mcp` that saves every order as it knows them, which a session kept through
    /// BriefBar's updates, changes nothing of what your changes kept of them.
    @Test func ordersSavedAgainAsAnOlderMCPSavesThemChangeNothingOfYours() throws {
        let orders = try tell([(4101, []), (4102, [4101])])
        let change = OrderChange(ref: Self.pr(4102), notAfter: [Self.pr(4101)], changedAt: t(60), replaced: OrderPlace(of: Self.pr(4102), in: orders))
        let defaults = MemorySettings()
        orders.save(to: defaults)
        let data = try #require(defaults.data(forKey: DeclaredOrders.defaultsKey))
        // The fields an older `--mcp` knows, and saves again, and none it would drop.
        let plans = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for plan in plans {
            #expect(Set(plan.keys).isSubset(of: ["id", "revision", "createdAt", "updatedAt", "declaredBy", "entries"]), "\(plan.keys)")
            for entry in try #require(plan["entries"] as? [[String: Any]]) {
                #expect(Set(entry.keys).isSubset(of: ["pullRequest", "after", "review"]), "\(entry.keys)")
            }
        }
        #expect(change.holds(in: DeclaredOrders.load(from: defaults)))
    }

    @Test func forgetAllOrdersForgetsYourChangesToo() {
        let defaults = MemorySettings()
        OrderChanges([OrderChange(ref: Self.pr(4101), first: .plan(planID), changedAt: t(0))]).save(to: defaults)
        DeclaredOrders.forgetAll(in: defaults)
        #expect(defaults.object(forKey: OrderChanges.defaultsKey) == nil)
        #expect(MissionKey("mine/33333333-4444-4555-8666-777777777777") == .mine(UUID(uuidString: "33333333-4444-4555-8666-777777777777")!))
        #expect(OrderPlacement("none") == .outside && OrderPlacement("plan/nonsense") == nil)
    }

    // MARK: As reviewed

    /// An order that changes a place and then changes it back made the latest change: yours stays overtaken until you put it
    /// back. Telling it again unchanged notes nothing.
    @Test func anOrderThatChangesAPlaceBackDoesntBringYoursBack() throws {
        var orders = try tell([(4101, []), (4102, [4101]), (4103, [4102])])
        let facts = Self.facts([4101, 4102, 4103])
        var changes = OrderChanges()
        try changes.apply(.setNext(Self.pr(4103), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))
        orders = try tell([(4101, []), (4102, [4101]), (4103, [4102])], replacing: orders, at: 70)
        var noted = changes.noteOverrides(in: orders, now: t(70))
        #expect(!noted)

        orders = try tell([(4101, []), (4102, [4101]), (4103, [4101])], replacing: orders, at: 80)
        noted = changes.noteOverrides(in: orders, now: t(80))
        #expect(noted && changes[Self.pr(4103)]?.overridden == OrderChange.Overridden(by: planID, at: t(80)))
        orders = try tell([(4101, []), (4102, [4101]), (4103, [4102])], replacing: orders, at: 90)
        #expect(changes[Self.pr(4103)]?.holds(in: orders) == false)
        let missions = Self.missions(facts, orders, changes)
        let step = try Self.step(4103, in: Self.mission(.plan(planID), in: missions))
        #expect(step.standing == .waiting(open: [Self.pr(4102)], unknown: []))
        #expect(step.notes == [.orderChangedIt(OrderOverride(by: Self.session, at: t(80), now: .after([Self.pr(4102)]), yours: .next))])

        try changes.apply(.putBack(Self.pr(4103)), missions: missions, orders: orders, now: t(100))
        #expect(changes[Self.pr(4103)]?.overridden == nil && changes[Self.pr(4103)]?.holds(in: orders) == true)
        let saved = MemorySettings()
        changes.save(to: saved)
        var overridden = changes
        overridden.noteOverrides(in: try tell([(4103, [])], replacing: orders, at: 110), now: t(110))
        overridden.save(to: saved)
        #expect(OrderChanges.load(from: saved) == overridden)
    }

    /// Set as Next is for the mission you set it in: a pull request in two orders is next only in the one you chose, and
    /// another set as next in the other stays so.
    @Test func setAsNextIsForTheMissionYouSetItIn() throws {
        var orders = try tell([(4300, []), (4301, [4300])])
        orders = try tell([(4201, []), (4300, [4201])], replacing: orders, id: otherID, at: 10)
        let facts = Self.facts([4201, 4300, 4301])
        var changes = OrderChanges()
        try changes.apply(.setNext(Self.pr(4201), in: .plan(otherID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))
        try changes.apply(.setNext(Self.pr(4300), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(70))

        let missions = Self.missions(facts, orders, changes)
        let other = try Self.mission(.plan(otherID), in: missions)
        #expect(OrderBoardTests.summary(other.steps) == ["1 !4201 Next to merge", "2 !4300 Merge after !4201"])
        let mine = try Self.mission(.plan(planID), in: missions)
        #expect(OrderBoardTests.summary(mine.steps) == ["1 !4300 Next to merge", "2 !4301 Merge after !4300"])
        #expect(MissionChoices.of(Self.pr(4201), in: .plan(otherID), missions: missions, changes: changes, orders: orders).next == .isSet)
        #expect(MissionChoices.of(Self.pr(4300), in: .plan(otherID), missions: missions, changes: changes, orders: orders).next == .offered)
        #expect(MissionChoices.of(Self.pr(4300), in: .plan(planID), missions: missions, changes: changes, orders: orders).next == .isSet)
    }

    /// Unchecking a line you'd checked back takes the order's line away again.
    @Test func uncheckingAgainTakesTheOrdersLineAwayAgain() throws {
        let orders = try tell([(4101, []), (4102, [4101])])
        let facts = Self.facts([4101, 4102])
        var changes = OrderChanges()
        for on in [false, true, false] {
            try changes.apply(
                .mergeAfter(Self.pr(4102), Self.pr(4101), in: .plan(planID), on), missions: Self.missions(facts, orders, changes),
                orders: orders, now: t(60)
            )
        }
        #expect(changes[Self.pr(4102)]?.after == [] && changes[Self.pr(4102)]?.notAfter == [Self.pr(4101)])
        let missions = Self.missions(facts, orders, changes)
        #expect(try Self.step(4102, in: Self.mission(.plan(planID), in: missions)).standing == .anyTime)
        #expect(MissionChoices.of(Self.pr(4102), missions: missions, changes: changes, orders: orders).prerequisites
            == [MissionChoices.Prerequisite(ref: Self.pr(4101), state: .unchecked)])
    }

    /// A chain goes on by one of its own pull requests, never one you put in it, and stays while one of its own is left.
    @Test func aChainYouPutPullRequestsInGoesOnByOneOfItsOwn() throws {
        let chain = [OrderBoardTests.ado(4101, from: "users/robin/a"), OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a")]
        var facts = OrderFacts(pullRequests: chain + [Self.ado(4110)])
        var changes = OrderChanges()
        var missions = Self.missions(facts, DeclaredOrders(), changes)
        try changes.apply(.move([Self.pr(4110)], to: .into(.chain(Self.pr(4101))), from: nil), missions: missions, orders: DeclaredOrders(), now: t(60))
        missions = Self.missions(facts, DeclaredOrders(), changes)
        try changes.apply(.setNext(Self.pr(4110), in: .chain(Self.pr(4101)), true), missions: missions, orders: DeclaredOrders(), now: t(70))

        var merged = chain
        merged[0].state = .merged
        facts = OrderFacts(pullRequests: merged + [Self.ado(4110)])
        missions = Self.missions(facts, DeclaredOrders(), changes)
        #expect(missions.first { $0.contains(Self.pr(4110)) }?.steps.first?.ref == Self.pr(4101))
        let moved = changes.moveAnchors(in: missions)
        #expect(moved == [Self.pr(4101): Self.pr(4102)])
        #expect(changes[Self.pr(4110)]?.placement == .into(.chain(Self.pr(4102))) && changes[Self.pr(4110)]?.first == .chain(Self.pr(4102)))

        // Once no list has 4101, 4102 alone is still that chain, with what you put in it.
        facts = OrderFacts(pullRequests: [chain[1], Self.ado(4110)])
        missions = Self.missions(facts, DeclaredOrders(), changes)
        let mission = try Self.mission(.chain(Self.pr(4102)), in: missions)
        #expect(mission.kind == .stack && Set(mission.steps.map(\.ref)) == [Self.pr(4102), Self.pr(4110)])
        #expect(try Self.step(4110, in: mission).standing == .next)
    }

    /// Moving the pull request a chain is named by out of it names the chain by another of its own, in the same change.
    @Test func movingTheOneAChainIsNamedByOutNamesItByAnother() throws {
        let facts = OrderFacts(pullRequests: [
            OrderBoardTests.ado(4101, from: "users/robin/a"), OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a"),
            OrderBoardTests.ado(4103, from: "users/robin/c", into: "users/robin/b"), Self.ado(4110),
        ])
        var changes = OrderChanges()
        var missions = Self.missions(facts, DeclaredOrders(), changes)
        try changes.apply(.move([Self.pr(4110)], to: .into(.chain(Self.pr(4101))), from: nil), missions: missions, orders: DeclaredOrders(), now: t(60))
        missions = Self.missions(facts, DeclaredOrders(), changes)
        let before = changes
        let touched = try changes.apply(.move([Self.pr(4101)], to: .outside, from: nil), missions: missions, orders: DeclaredOrders(), now: t(70))

        #expect(changes[Self.pr(4110)]?.placement == .into(.chain(Self.pr(4102))))
        missions = Self.missions(facts, DeclaredOrders(), changes)
        #expect(try Self.mission(.chain(Self.pr(4102)), in: missions).steps.map(\.ref) == [Self.pr(4102), Self.pr(4103), Self.pr(4110)])
        changes.restore(touched)
        #expect(changes == before)
    }

    /// One stacked on a pull request its order doesn't name waits for it all the same, and can't be set as next; nor can
    /// one stacked with the order that its order doesn't name, while what it's stacked on hasn't merged.
    @Test func aPullRequestStackedOnOneItsOrderDoesntNameWaitsForIt() throws {
        let orders = try tell([(4102, []), (4103, [])])
        let facts = OrderFacts(pullRequests: [
            OrderBoardTests.ado(4101, from: "users/robin/a"), OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a"),
            Self.ado(4103), OrderBoardTests.ado(4105, from: "users/robin/e", into: "users/robin/part-4103"),
        ])
        var changes = OrderChanges()
        let missions = Self.missions(facts, orders, changes)
        let mission = try Self.mission(.plan(planID), in: missions)
        #expect(Set(mission.attached.map(\.ref)) == [Self.pr(4101), Self.pr(4105)])
        let step = try Self.step(4102, in: mission)
        #expect(step.standing == .waiting(open: [Self.pr(4101)], unknown: []) && OrderText.capsule(step) == "After !4101 · stacked")
        #expect(MissionChoices.of(Self.pr(4102), missions: missions, changes: changes, orders: orders).next == .stacked(on: Self.pr(4101)))
        let attached = try Self.step(4105, in: mission)
        #expect(attached.prerequisites == [OrderPrerequisite(ref: Self.pr(4103), origins: [.branch], status: .open)])
        #expect(MissionChoices.of(Self.pr(4105), missions: missions, changes: changes, orders: orders).next == .stacked(on: Self.pr(4103)))
        #expect(throws: OrderChangeError.stacked(on: Self.pr(4103))) {
            try changes.apply(.setNext(Self.pr(4105), in: .plan(planID), true), missions: missions, orders: orders)
        }
        #expect(changes.isEmpty)
    }

    /// The one you set as next is next to merge, though nothing else in its mission waits for it.
    @Test func theOneYouSetAsNextAloneIsNextToMerge() throws {
        let mine = MissionKey.mine(UUID(uuidString: "44444444-5555-4666-8777-888888888888")!)
        let facts = Self.facts([4111])
        var changes = OrderChanges()
        try changes.apply(.move([Self.pr(4111)], to: .into(mine), from: nil), missions: Self.missions(facts, DeclaredOrders(), changes), orders: DeclaredOrders(), now: t(60))
        var step = try Self.step(4111, in: Self.mission(mine, in: Self.missions(facts, DeclaredOrders(), changes)))
        #expect(step.standing == .unordered && step.number == nil)
        try changes.apply(.setNext(Self.pr(4111), in: mine, true), missions: Self.missions(facts, DeclaredOrders(), changes), orders: DeclaredOrders(), now: t(70))
        step = try Self.step(4111, in: Self.mission(mine, in: Self.missions(facts, DeclaredOrders(), changes)))
        #expect(step.standing == .next && step.number == 1)
    }

    /// One stacked on a pull request that closed without merging can't be set as next, and one set as next before doesn't
    /// hold: nothing waits for it.
    @Test func oneStackedOnAPullRequestThatClosedIsntNext() throws {
        let orders = try tell([(4101, []), (4102, []), (4103, [])])
        let facts = OrderFacts(pullRequests: [
            OrderBoardTests.ado(4101, from: "users/robin/a", state: .closed), OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a"),
            Self.ado(4103),
        ])
        var fresh = OrderChanges()
        let before = Self.missions(facts, orders, fresh)
        #expect(MissionChoices.of(Self.pr(4102), missions: before, changes: fresh, orders: orders).next == .stacked(on: Self.pr(4101)))
        #expect(throws: OrderChangeError.stacked(on: Self.pr(4101))) {
            try fresh.apply(.setNext(Self.pr(4102), in: .plan(planID), true), missions: before, orders: orders)
        }

        let changes = OrderChanges([
            OrderChange(ref: Self.pr(4102), first: .plan(planID), changedAt: t(60), replaced: OrderPlace(of: Self.pr(4102), in: orders)),
        ])
        let mission = try Self.mission(.plan(planID), in: Self.missions(facts, orders, changes))
        let next = try Self.step(4102, in: mission)
        #expect(next.standing == .prerequisiteClosed(Self.pr(4101)) && next.notes.contains(.nextDoesntHold(Self.pr(4101), retarget: false)))
        #expect(try Self.step(4103, in: mission).standing == .anyTime)
    }

    /// Merge After lists the pull requests stacked with the mission's that its order doesn't name, and what it merges after
    /// in another mission, there to take away.
    @Test func mergeAfterListsWhatItMergesAfterWhereverItIs() throws {
        var orders = try tell([(4102, []), (4103, [])])
        var facts = OrderFacts(pullRequests: [
            OrderBoardTests.ado(4101, from: "users/robin/a"), OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a"),
            Self.ado(4103),
        ])
        var changes = OrderChanges()
        var missions = Self.missions(facts, orders, changes)
        #expect(MissionChoices.of(Self.pr(4102), missions: missions, changes: changes, orders: orders).prerequisites == [
            MissionChoices.Prerequisite(ref: Self.pr(4103), state: .unchecked), MissionChoices.Prerequisite(ref: Self.pr(4101), state: .stacked),
        ])

        orders = try tell([(4101, []), (4102, []), (4103, [])])
        facts = Self.facts([4101, 4102, 4103])
        missions = Self.missions(facts, orders, changes)
        try changes.apply(.mergeAfter(Self.pr(4101), Self.pr(4102), in: .plan(planID), true), missions: missions, orders: orders, now: t(60))
        let mine = MissionKey.mine(UUID(uuidString: "44444444-5555-4666-8777-888888888888")!)
        try changes.apply(.move([Self.pr(4102)], to: .into(mine), from: .plan(planID)), missions: Self.missions(facts, orders, changes), orders: orders, now: t(70))
        missions = Self.missions(facts, orders, changes)
        #expect(try Self.step(4101, in: Self.mission(.plan(planID), in: missions)).standing == .waiting(open: [Self.pr(4102)], unknown: []))
        #expect(MissionChoices.of(Self.pr(4101), missions: missions, changes: changes, orders: orders).prerequisites == [
            MissionChoices.Prerequisite(ref: Self.pr(4103), state: .unchecked), MissionChoices.Prerequisite(ref: Self.pr(4102), state: .checked),
        ])
        try changes.apply(.mergeAfter(Self.pr(4101), Self.pr(4102), in: .plan(planID), false), missions: missions, orders: orders, now: t(80))
        #expect(changes[Self.pr(4101)] == nil)
        #expect(try Self.step(4101, in: Self.mission(.plan(planID), in: Self.missions(facts, orders, changes))).prerequisites.isEmpty)
    }

    /// One stacked on a pull request of another order waits for it, as one stacked within its own order does, and can't be
    /// set as next while that one's open.
    @Test func oneStackedOnAPullRequestOfAnotherOrderWaitsForIt() throws {
        var orders = try tell([(4101, [])])
        orders = try tell([(4102, []), (4103, [])], replacing: orders, id: otherID, at: 10)
        let facts = OrderFacts(pullRequests: [
            OrderBoardTests.ado(4101, from: "users/robin/a"), OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a"),
            Self.ado(4103),
        ])
        var changes = OrderChanges()
        let missions = Self.missions(facts, orders, changes)
        let step = try Self.step(4102, in: Self.mission(.plan(otherID), in: missions))
        #expect(step.standing == .waiting(open: [Self.pr(4101)], unknown: []) && OrderText.capsule(step) == "After !4101 · stacked")
        let choices = MissionChoices.of(Self.pr(4102), missions: missions, changes: changes, orders: orders)
        #expect(choices.next == .stacked(on: Self.pr(4101)))
        #expect(choices.prerequisites.last == MissionChoices.Prerequisite(ref: Self.pr(4101), state: .stacked))
        #expect(throws: OrderChangeError.stacked(on: Self.pr(4101))) {
            try changes.apply(.setNext(Self.pr(4102), in: .plan(otherID), true), missions: missions, orders: orders)
        }
        #expect(try Self.step(4103, in: Self.mission(.plan(otherID), in: missions)).standing == .anyTime)
        let names = OrderNames(title: { [planID] key in key == .plan(planID) ? "Cart" : nil })
        #expect(OrderText.elsewhere(step, in: try Self.mission(.plan(otherID), in: missions), missions: missions, names: names)
            == "After !4101 · stacked, in ‘Cart’")
    }

    /// One whose stacked pull request merged, while it still targets that one's branch, is retargeted before it can be set
    /// as next: one its order names, as its standing says, and one it doesn't, by its branch.
    @Test func oneThatStillTargetsAMergedBranchIsRetargetedBeforeItsNext() throws {
        let orders = try tell([(4101, []), (4102, []), (4103, [])])
        let facts = OrderFacts(pullRequests: [
            OrderBoardTests.ado(4101, from: "users/robin/a", state: .merged), OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a"),
            Self.ado(4103, state: .merged), OrderBoardTests.ado(4105, from: "users/robin/e", into: "users/robin/part-4103"),
        ])
        var changes = OrderChanges()
        let missions = Self.missions(facts, orders, changes)
        let mission = try Self.mission(.plan(planID), in: missions)
        #expect(try Self.step(4102, in: mission).standing == .retarget(after: Self.pr(4101), to: "main"))
        #expect(MissionChoices.of(Self.pr(4102), missions: missions, changes: changes, orders: orders).next
            == .retarget(after: Self.pr(4101), to: "main"))
        #expect(throws: OrderChangeError.retarget(after: Self.pr(4101), to: "main")) {
            try changes.apply(.setNext(Self.pr(4102), in: .plan(planID), true), missions: missions, orders: orders)
        }
        #expect(OrderChangeError.retarget(after: Self.pr(4101), to: "main").description == "!4101 merged: retarget it to main first.")
        #expect(mission.attached.map(\.ref) == [Self.pr(4105)])
        #expect(MissionChoices.of(Self.pr(4105), missions: missions, changes: changes, orders: orders).next
            == .retarget(after: Self.pr(4103), to: nil))
        #expect(changes.isEmpty)

        // One set as next before stays set, but doesn't hold until you retarget it: nothing waits for it.
        let more = try tell([(4101, []), (4102, []), (4104, [])])
        let moreFacts = OrderFacts(pullRequests: [
            OrderBoardTests.ado(4101, from: "users/robin/a", state: .merged), OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a"),
            Self.ado(4104),
        ])
        let saved = OrderChanges([
            OrderChange(ref: Self.pr(4102), first: .plan(planID), changedAt: t(60), replaced: OrderPlace(of: Self.pr(4102), in: more)),
        ])
        let withNext = Self.missions(moreFacts, more, saved)
        let next = try Self.step(4102, in: Self.mission(.plan(planID), in: withNext))
        #expect(next.standing == .retarget(after: Self.pr(4101), to: "main"))
        #expect(next.notes.contains(.nextDoesntHold(Self.pr(4101), retarget: true)))
        #expect(OrderText.note(.nextDoesntHold(Self.pr(4101), retarget: true), of: Self.pr(4102))
            == "!4101 merged: your ‘next to merge’ holds once you retarget it")
        #expect(MissionChoices.of(Self.pr(4102), missions: withNext, changes: saved, orders: more).next == .isSet)
        #expect(try Self.step(4104, in: Self.mission(.plan(planID), in: withNext)).standing == .anyTime)
    }

    /// An order's line that goes round with stacked branches through another mission is set aside, as within one; yours is
    /// refused, the menu saying why.
    @Test func anOrdersLineAgainstStackedBranchesThroughAnotherMissionIsSetAside() throws {
        var orders = try tell([(4101, [4103]), (4103, [])])
        orders = try tell([(4102, [])], replacing: orders, id: otherID, at: 10)
        let facts = OrderFacts(pullRequests: [
            OrderBoardTests.ado(4101, from: "users/robin/a"), OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a"),
            OrderBoardTests.ado(4103, from: "users/robin/c", into: "users/robin/b"),
        ])
        var changes = OrderChanges()
        let missions = Self.missions(facts, orders, changes)
        let mission = try Self.mission(.plan(planID), in: missions)
        let first = try Self.step(4101, in: mission)
        #expect(first.prerequisites.isEmpty && first.notes.contains(.setAside(Self.pr(4103), by: Self.session, through: .stacked)))
        #expect(try Self.step(4103, in: mission).standing == .waiting(open: [Self.pr(4102)], unknown: []))
        #expect(try Self.step(4102, in: Self.mission(.plan(otherID), in: missions)).standing == .waiting(open: [Self.pr(4101)], unknown: []))
        #expect(MissionChoices.of(Self.pr(4101), missions: missions, changes: changes, orders: orders).prerequisites
            == [MissionChoices.Prerequisite(ref: Self.pr(4103), state: .waitsForIt)])
        #expect(throws: OrderChangeError.waitsForIt(Self.pr(4103))) {
            try changes.apply(.mergeAfter(Self.pr(4101), Self.pr(4103), in: .plan(planID), true), missions: missions, orders: orders)
        }
    }

    /// Moving the middle one of a stacked chain out of every mission doesn't let you put the chain's first after its last:
    /// BriefBar still sees them stacked through it.
    @Test func aChainStillCountsThroughOneYouMovedOutOfEveryMission() throws {
        let orders = try tell([(4101, []), (4103, [])])
        let facts = OrderFacts(pullRequests: [
            OrderBoardTests.ado(4101, from: "users/robin/a"), OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a"),
            OrderBoardTests.ado(4103, from: "users/robin/c", into: "users/robin/b"),
        ])
        var changes = OrderChanges()
        try changes.apply(.move([Self.pr(4102)], to: .outside, from: nil), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))
        let missions = Self.missions(facts, orders, changes)
        #expect(OrderBoard.mission(of: Self.pr(4102), in: missions) == nil)
        let stacked = OrderBoard.stacked(facts)
        #expect(MissionChoices.of(Self.pr(4101), missions: missions, changes: changes, orders: orders, stacked: stacked).prerequisites
            == [MissionChoices.Prerequisite(ref: Self.pr(4103), state: .waitsForIt)])
        #expect(throws: OrderChangeError.waitsForIt(Self.pr(4103))) {
            try changes.apply(
                .mergeAfter(Self.pr(4101), Self.pr(4103), in: .plan(planID), true), missions: missions, orders: orders, stacked: stacked
            )
        }
    }

    /// Put Yours Back puts the one you set as next back in the mission you set it in, though its order no longer has it.
    @Test func puttingBackOneSetAsNextPutsItBackInItsMission() throws {
        var orders = try tell([(4101, []), (4102, [4101]), (4103, [4102])])
        let facts = Self.facts([4101, 4102, 4103])
        var changes = OrderChanges()
        try changes.apply(.setNext(Self.pr(4103), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))
        orders = try tell([(4101, []), (4102, [4101])], replacing: orders, at: 70)
        changes.noteOverrides(in: orders, now: t(70))
        var missions = Self.missions(facts, orders, changes)
        #expect(OrderBoard.mission(of: Self.pr(4103), in: missions) == nil)
        #expect(MissionChoices.of(Self.pr(4103), missions: missions, changes: changes, orders: orders).canPutBack)

        try changes.apply(.putBack(Self.pr(4103)), missions: missions, orders: orders, now: t(80))
        #expect(changes[Self.pr(4103)]?.placement == .into(.plan(planID)))
        missions = Self.missions(facts, orders, changes)
        #expect(try Self.step(4103, in: Self.mission(.plan(planID), in: missions)).standing == .next)
        #expect(!MissionChoices.of(Self.pr(4103), missions: missions, changes: changes, orders: orders).canPutBack)
    }

    /// What it merges after that closed stays in Merge After, for you to take it away.
    @Test func oneThatClosedStaysInMergeAfterToTakeAway() throws {
        let orders = try tell([(4101, []), (4102, []), (4103, [])])
        var changes = OrderChanges()
        try changes.apply(
            .mergeAfter(Self.pr(4101), Self.pr(4102), in: .plan(planID), true), missions: Self.missions(Self.facts([4101, 4102, 4103]), orders, changes),
            orders: orders, now: t(60)
        )
        let facts = OrderFacts(pullRequests: [Self.ado(4101), Self.ado(4102, state: .closed), Self.ado(4103)])
        let missions = Self.missions(facts, orders, changes)
        #expect(try Self.step(4101, in: Self.mission(.plan(planID), in: missions)).standing == .prerequisiteClosed(Self.pr(4102)))
        #expect(MissionChoices.of(Self.pr(4101), missions: missions, changes: changes, orders: orders).prerequisites
            .contains(MissionChoices.Prerequisite(ref: Self.pr(4102), state: .checked)))
        try changes.apply(.mergeAfter(Self.pr(4101), Self.pr(4102), in: .plan(planID), false), missions: missions, orders: orders, now: t(70))
        #expect(changes.isEmpty)
    }

    /// Two orders' lines that go round through stacked branches from one mission to the other: the mission made later sets
    /// its line aside, with a note, so nothing waits for itself.
    @Test func ordersLinesThatGoRoundThroughAnotherMissionAreSetAside() throws {
        var orders = try tell([(4101, [4104]), (4104, [])])
        orders = try tell([(4102, []), (4103, [4102])], replacing: orders, id: otherID, at: 10)
        let facts = OrderFacts(pullRequests: [
            OrderBoardTests.ado(4101, from: "users/robin/a"), OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a"),
            OrderBoardTests.ado(4103, from: "users/robin/c"), OrderBoardTests.ado(4104, from: "users/robin/d", into: "users/robin/c"),
        ])
        let missions = Self.missions(facts, orders, OrderChanges())
        let first = try Self.mission(.plan(planID), in: missions)
        #expect(try Self.step(4101, in: first).standing == .waiting(open: [Self.pr(4104)], unknown: []))
        let second = try Self.mission(.plan(otherID), in: missions)
        let set = try Self.step(4103, in: second)
        #expect(set.prerequisites.isEmpty && set.notes.contains(.goesRound(Self.pr(4102), by: Self.session)))
        #expect(OrderText.note(.goesRound(Self.pr(4102), by: nil), of: Self.pr(4103)).hasSuffix(
            "puts it after !4102, but !4102 waits for it through another mission"
        ))
        #expect(try Self.step(4102, in: second).standing == .waiting(open: [Self.pr(4101)], unknown: []))
        #expect(missions.allSatisfy { mission in mission.steps.allSatisfy { if case .inCycle = $0.standing { false } else { true } } })
    }

    /// Two orders that put the same two pull requests the other way round each keep their own line: each mission says what
    /// its order says of its own pull requests.
    @Test func twoOrdersOfTheSamePullRequestsKeepTheirOwnLines() throws {
        var orders = try tell([(4101, [4102]), (4102, [])])
        orders = try tell([(4101, []), (4102, [4101])], replacing: orders, id: otherID, at: 10)
        let missions = Self.missions(Self.facts([4101, 4102]), orders, OrderChanges())
        let first = try Self.step(4101, in: Self.mission(.plan(planID), in: missions))
        let second = try Self.step(4102, in: Self.mission(.plan(otherID), in: missions))
        #expect(first.standing == .waiting(open: [Self.pr(4102)], unknown: []))
        #expect(second.standing == .waiting(open: [Self.pr(4101)], unknown: []))

        // Each says the other order goes the other way, so that you check the order.
        #expect(first.notes.contains(.ordersGoRound(Self.pr(4102), order: otherID, direct: true)))
        #expect(second.notes.contains(.ordersGoRound(Self.pr(4101), order: planID, direct: true)))
        let names = OrderNames(title: { [otherID] key in key == .plan(otherID) ? "Search" : nil })
        #expect(OrderText.note(.ordersGoRound(Self.pr(4102), order: otherID, direct: true), of: Self.pr(4101), names: names)
            == "‘Search’ puts !4102 after it: check the order")
        #expect(OrderText.note(.ordersGoRound(Self.pr(4102), order: otherID, direct: false), of: Self.pr(4101))
            == "!4102 waits for it through another order: check the order")
    }

    /// Three orders whose lines go round only together, each between pull requests the last one has too: the last one and
    /// the order whose line closes the circle say so.
    @Test func ordersThatGoRoundTogetherSaySo() throws {
        let thirdID = UUID(uuidString: "33333333-4444-4555-8666-777777777777")!
        var orders = try tell([(4101, []), (4102, [4101])])
        orders = try tell([(4102, []), (4103, [4102])], replacing: orders, id: otherID, at: 10)
        orders = try tell([(4101, [4103]), (4102, []), (4103, [])], replacing: orders, id: thirdID, at: 20)
        let missions = Self.missions(Self.facts([4101, 4102, 4103]), orders, OrderChanges())

        let last = try Self.step(4101, in: Self.mission(.plan(thirdID), in: missions))
        #expect(last.standing == .waiting(open: [Self.pr(4103)], unknown: []))
        #expect(last.notes.contains(.ordersGoRound(Self.pr(4103), order: planID, direct: false)))
        #expect(try Self.step(4102, in: Self.mission(.plan(planID), in: missions)).notes
            .contains(.ordersGoRound(Self.pr(4101), order: thirdID, direct: false)))
    }

    /// Put Yours Back puts the one you set as next back in its order's mission, though nothing else is left there to show
    /// it.
    @Test func puttingBackOneSetAsNextBringsBackAMissionNothingElseShows() throws {
        var orders = try tell([(4101, []), (4102, [])])
        let facts = Self.facts([4101, 4102])
        var changes = OrderChanges()
        try changes.apply(.move([Self.pr(4102)], to: .outside, from: nil), missions: Self.missions(facts, orders, changes), orders: orders, now: t(50))
        try changes.apply(.setNext(Self.pr(4101), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))
        orders = try tell([(4102, [])], replacing: orders, at: 70)
        changes.noteOverrides(in: orders, now: t(70))
        var missions = Self.missions(facts, orders, changes)
        #expect(missions.isEmpty)

        try changes.apply(.putBack(Self.pr(4101)), missions: missions, orders: orders, now: t(80))
        #expect(changes[Self.pr(4101)]?.placement == .into(.plan(planID)))
        missions = Self.missions(facts, orders, changes)
        #expect(try Self.step(4101, in: Self.mission(.plan(planID), in: missions)).standing == .next)
    }

    /// One stacked with an order's pull requests that its order doesn't name keeps what it's stacked on that you moved out
    /// of every mission, and can't be set as next before it.
    @Test func oneTheOrderDoesntNameKeepsWhatItsStackedOnThatYouMovedOut() throws {
        let orders = try tell([(4103, [])])
        let facts = OrderFacts(pullRequests: [
            OrderBoardTests.ado(4101, from: "users/robin/a"), OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a"),
            OrderBoardTests.ado(4103, from: "users/robin/c", into: "users/robin/b"),
        ])
        var changes = OrderChanges()
        try changes.apply(.move([Self.pr(4101)], to: .outside, from: nil), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))
        let missions = Self.missions(facts, orders, changes)
        let attached = try Self.step(4102, in: Self.mission(.plan(planID), in: missions))
        #expect(attached.standing == .notInOrder && attached.prerequisites.map(\.ref) == [Self.pr(4101)])
        #expect(!attached.notes.contains { if case .stackedWith(Self.pr(4101), _, _) = $0 { true } else { false } })
        #expect(MissionChoices.of(Self.pr(4102), missions: missions, changes: changes, orders: orders).next == .stacked(on: Self.pr(4101)))
        #expect(throws: OrderChangeError.stacked(on: Self.pr(4101))) {
            try changes.apply(.setNext(Self.pr(4102), in: .plan(planID), true), missions: missions, orders: orders)
        }
    }

    /// What you set as next goes before a session's order of another mission that would go round with it through a stacked
    /// branch, whichever was told first: that order's line is set aside, and nothing waits for itself.
    @Test func setAsNextGoesBeforeAnotherMissionsOrderThatWouldGoRoundWithIt() throws {
        var orders = try tell([(4103, []), (4101, [4103])], id: otherID)
        orders = try tell([(4101, []), (4102, [])], replacing: orders, at: 10)
        let facts = OrderFacts(pullRequests: [
            OrderBoardTests.ado(4101, from: "users/robin/a"), OrderBoardTests.ado(4102, from: "users/robin/b"),
            OrderBoardTests.ado(4103, from: "users/robin/c", into: "users/robin/b"),
        ])
        var changes = OrderChanges()
        try changes.apply(.setNext(Self.pr(4101), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))

        let missions = Self.missions(facts, orders, changes)
        #expect(OrderBoardTests.summary(try Self.mission(.plan(planID), in: missions).steps)
            == ["1 !4101 Next to merge", "2 !4102 Merge after !4101"])
        let other = try Self.mission(.plan(otherID), in: missions)
        let aside = try Self.step(4101, in: other)
        #expect(aside.prerequisites.isEmpty
            && aside.notes.contains(.yourNextGoesFirst(Self.pr(4103), by: Self.session, next: Self.pr(4101), in: .plan(planID))))
        let names = OrderNames(title: { [planID] key in key == .plan(planID) ? "Cart" : nil })
        #expect(OrderText.note(aside.notes.last { if case .yourNextGoesFirst = $0 { true } else { false } }!, of: Self.pr(4101), names: names)
            .hasSuffix("puts it after !4103, but you set it as next to merge in ‘Cart’"))
        #expect(try Self.step(4103, in: other).standing == .waiting(open: [Self.pr(4102)], unknown: []))
        #expect(missions.allSatisfy { mission in mission.steps.allSatisfy { if case .inCycle = $0.standing { false } else { true } } })
    }

    /// Put Yours Back puts one you put after another back in the mission you did it in, though its order no longer has it.
    @Test func puttingBackOneYouPutAfterAnotherPutsItBackInItsMission() throws {
        var orders = try tell([(4101, []), (4102, []), (4103, [])])
        let facts = Self.facts([4101, 4102, 4103])
        var changes = OrderChanges()
        try changes.apply(
            .mergeAfter(Self.pr(4102), Self.pr(4103), in: .plan(planID), true), missions: Self.missions(facts, orders, changes),
            orders: orders, now: t(60)
        )
        #expect(changes[Self.pr(4102)]?.from == .plan(planID) && changes[Self.pr(4102)]?.placement == nil)
        orders = try tell([(4101, []), (4103, [])], replacing: orders, at: 70)
        changes.noteOverrides(in: orders, now: t(70))
        var missions = Self.missions(facts, orders, changes)
        #expect(OrderBoard.mission(of: Self.pr(4102), in: missions) == nil)
        #expect(MissionChoices.of(Self.pr(4102), missions: missions, changes: changes, orders: orders).canPutBack)

        try changes.apply(.putBack(Self.pr(4102)), missions: missions, orders: orders, now: t(80))
        #expect(changes[Self.pr(4102)]?.placement == .into(.plan(planID)) && changes[Self.pr(4102)]?.from == nil)
        missions = Self.missions(facts, orders, changes)
        #expect(try Self.step(4102, in: Self.mission(.plan(planID), in: missions)).standing == .waiting(open: [Self.pr(4103)], unknown: []))
        #expect(!MissionChoices.of(Self.pr(4102), missions: missions, changes: changes, orders: orders).canPutBack)
    }

    /// One whose order nobody knows, such as one you made a mission of, says what became of it once it merges, closes or
    /// can't be seen; its mission still has no order.
    @Test func oneWhoseOrderNobodyKnowsSaysWhatBecameOfIt() throws {
        let mine = MissionKey.mine(UUID(uuidString: "44444444-5555-4666-8777-888888888888")!)
        var changes = OrderChanges()
        try changes.apply(
            .move([Self.pr(4111), Self.pr(4112)], to: .into(mine), from: nil), missions: Self.missions(Self.facts([4111, 4112]), DeclaredOrders(), changes),
            orders: DeclaredOrders(), now: t(60)
        )
        for (state, standing) in [(PullRequestState.merged, OrderStanding.merged), (.closed, .closed)] {
            let facts = OrderFacts(pullRequests: [Self.ado(4111, state: state), Self.ado(4112)])
            let mission = try Self.mission(mine, in: Self.missions(facts, DeclaredOrders(), changes))
            #expect(try Self.step(4111, in: mission).standing == standing)
            #expect(try Self.step(4112, in: mission).standing == .unordered)
            #expect(!mission.hasOrder)
        }
        let unseen = try Self.step(4111, in: Self.mission(mine, in: Self.missions(Self.facts([4112]), DeclaredOrders(), changes)))
        #expect(unseen.status.isUnknown && unseen.standing != .unordered)
    }

    /// What you set as next goes before a session's order of another mission that names both, though it says the other way
    /// round: that order's line is set aside, saying so, and neither waits for the other.
    @Test func setAsNextGoesBeforeAnOrderOfTheSamePullRequests() throws {
        var orders = try tell([(4101, []), (4102, [])])
        orders = try tell([(4102, []), (4101, [4102])], replacing: orders, id: otherID, at: 10)
        let facts = Self.facts([4101, 4102])
        var changes = OrderChanges()
        try changes.apply(.setNext(Self.pr(4101), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))

        let missions = Self.missions(facts, orders, changes)
        #expect(OrderBoardTests.summary(try Self.mission(.plan(planID), in: missions).steps)
            == ["1 !4101 Next to merge", "2 !4102 Merge after !4101"])
        let other = try Self.mission(.plan(otherID), in: missions)
        let next = try Self.step(4101, in: other)
        #expect(next.prerequisites.isEmpty && next.standing == .anyTime)
        #expect(next.notes.contains(.yourNextGoesFirst(Self.pr(4102), by: Self.session, next: Self.pr(4101), in: .plan(planID))))
        #expect(!next.notes.contains { if case .ordersGoRound = $0 { true } else { false } })
        let names = OrderNames(title: { [planID] key in key == .plan(planID) ? "Cart" : nil })
        #expect(OrderText.note(.yourNextGoesFirst(Self.pr(4103), by: nil, next: Self.pr(4101), in: .plan(planID)), of: Self.pr(4102), names: names)
            .hasSuffix("puts it after !4103, but !4103 waits for it since you set !4101 as next to merge in ‘Cart’"))
    }

    /// While the one you set as next doesn't hold, stacked on one that hasn't merged, what its order puts it after stays.
    @Test func aNextThatDoesntHoldKeepsWhatItsOrderPutsItAfter() throws {
        let orders = try tell([(4102, []), (4103, [4102])])
        let facts = OrderFacts(pullRequests: [
            OrderBoardTests.ado(4101, from: "users/robin/a"), Self.ado(4102), OrderBoardTests.ado(4103, from: "users/robin/c", into: "users/robin/a"),
        ])
        let changes = OrderChanges([
            OrderChange(ref: Self.pr(4103), first: .plan(planID), changedAt: t(60), replaced: OrderPlace(of: Self.pr(4103), in: orders)),
        ])
        let step = try Self.step(4103, in: Self.mission(.plan(planID), in: Self.missions(facts, orders, changes)))
        #expect(step.notes.contains(.nextDoesntHold(Self.pr(4101), retarget: false)))
        #expect(Set(step.prerequisites.map(\.ref)) == [Self.pr(4101), Self.pr(4102)])
        #expect(step.prerequisites.first { $0.ref == Self.pr(4102) }?.origins.contains(where: \.isDeclared) == true)
    }

    /// One that still targets the branch of one that merged is retargeted before it's next, though its standing says first
    /// that what its order puts it after closed.
    @Test func oneThatStillTargetsAMergedBranchIsRetargetedFirstWhateverItsStanding() throws {
        let orders = try tell([(4101, []), (4102, [4103]), (4103, [])])
        let facts = OrderFacts(pullRequests: [
            OrderBoardTests.ado(4101, from: "users/robin/a", state: .merged), OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a"),
            Self.ado(4103, state: .closed),
        ])
        var changes = OrderChanges()
        let missions = Self.missions(facts, orders, changes)
        #expect(try Self.step(4102, in: Self.mission(.plan(planID), in: missions)).standing == .prerequisiteClosed(Self.pr(4103)))
        #expect(MissionChoices.of(Self.pr(4102), missions: missions, changes: changes, orders: orders).next == .retarget(after: Self.pr(4101), to: nil))
        #expect(throws: OrderChangeError.retarget(after: Self.pr(4101), to: nil)) {
            try changes.apply(.setNext(Self.pr(4102), in: .plan(planID), true), missions: missions, orders: orders)
        }
        #expect(changes.isEmpty)
    }

    /// The one you set as next shows so in its menu while BriefBar can't see it, so that choosing it takes that away.
    @Test func setAsNextShowsSetWhileBriefBarCantSeeIt() throws {
        let orders = try tell([(4101, []), (4102, [4101])])
        var changes = OrderChanges([
            OrderChange(ref: Self.pr(4102), first: .plan(planID), changedAt: t(60), replaced: OrderPlace(of: Self.pr(4102), in: orders)),
        ])
        let missions = Self.missions(Self.facts([4101]), orders, changes)
        #expect(try Self.step(4102, in: Self.mission(.plan(planID), in: missions)).status.isUnknown)
        #expect(MissionChoices.of(Self.pr(4102), missions: missions, changes: changes, orders: orders).next == .isSet)
        try changes.apply(.setNext(Self.pr(4102), in: .plan(planID), false), missions: missions, orders: orders, now: t(70))
        #expect(changes.isEmpty)
    }

    /// A chain goes on by one of its own that what Undo would put back moved out of it: only where your changes put pull
    /// requests now counts.
    @Test func aChainGoesOnByOneUndoWouldMoveOut() throws {
        let chain = [OrderBoardTests.ado(4101, from: "users/robin/a"), OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a")]
        var changes = OrderChanges([OrderChange(ref: Self.pr(4110), placement: .into(.chain(Self.pr(4101))), changedAt: t(60))])
        let undo = OrderChanges([OrderChange(ref: Self.pr(4102), placement: .outside, changedAt: t(70))])
        var merged = chain
        merged[0].state = .merged
        let missions = Self.missions(OrderFacts(pullRequests: merged + [Self.ado(4110)]), DeclaredOrders(), changes)

        #expect(changes.moveAnchors(in: missions, alsoFor: undo) == [Self.pr(4101): Self.pr(4102)])
        #expect(changes[Self.pr(4110)]?.placement == .into(.chain(Self.pr(4102))))
    }

    // MARK: An order that agrees with yours

    /// A session that takes a pull request you moved out of its order out of it too agrees with you: yours holds, and what
    /// the order says now is what it replaced. Naming it there again goes against yours.
    @Test func aSessionThatTakesOutWhatYouMovedOutOfItsOrderAgreesWithYou() throws {
        var orders = try tell([(4101, []), (4102, [4101]), (4103, [4102])])
        let facts = Self.facts([4101, 4102, 4103, 4110])
        let mine = MissionKey.mine(UUID(uuidString: "55555555-6666-4777-8888-999999999999")!)
        var changes = OrderChanges()
        try changes.apply(
            .move([Self.pr(4103), Self.pr(4110)], to: .into(mine), from: nil), missions: Self.missions(facts, orders, changes),
            orders: orders, now: t(60)
        )

        orders = try tell([(4101, []), (4102, [4101])], replacing: orders, at: 120)
        #expect(changes[Self.pr(4103)]?.holds(in: orders) == true)
        let noted = changes.noteOverrides(in: orders, now: t(120))
        #expect(noted && changes[Self.pr(4103)]?.overridden == nil && changes[Self.pr(4103)]?.replaced == OrderPlace())
        var missions = Self.missions(facts, orders, changes)
        let yours = try Self.mission(mine, in: missions)
        #expect(yours.steps.map(\.ref) == [Self.pr(4103), Self.pr(4110)])
        #expect(try Self.step(4103, in: yours).notes == [.moved(from: .plan(planID), t(60))])

        orders = try tell([(4101, []), (4102, [4101]), (4103, [4102])], replacing: orders, at: 180)
        #expect(changes[Self.pr(4103)]?.holds(in: orders) == false)
        missions = Self.missions(facts, orders, changes)
        let back = try Self.step(4103, in: Self.mission(.plan(planID), in: missions))
        #expect(back.notes == [.orderChangedIt(OrderOverride(by: Self.session, at: t(180), now: .after([Self.pr(4102)]), yours: .moved))])
    }

    /// A session that takes a pull request you moved into its mission into its order agrees with you, whatever it puts it
    /// after there, and so do its later revisions of that, which you didn't change: the order you moved it out of, which
    /// still names it, doesn't get it back. Taking it out of the order you moved it to goes against yours.
    @Test func aSessionThatTakesInWhatYouMovedIntoItsMissionAgreesWithYou() throws {
        var orders = try tell([(4101, []), (4102, [4101])])
        orders = try tell([(4111, []), (4112, [4111])], replacing: orders, id: otherID, at: 10)
        let facts = Self.facts([4101, 4102, 4111, 4112])
        var changes = OrderChanges()
        try changes.apply(
            .move([Self.pr(4102)], to: .into(.plan(otherID)), from: .plan(planID)), missions: Self.missions(facts, orders, changes),
            orders: orders, now: t(60)
        )

        orders = try tell([(4111, []), (4112, [4111]), (4102, [4112])], replacing: orders, id: otherID, at: 120)
        #expect(changes[Self.pr(4102)]?.holds(in: orders) == true)
        var noted = changes.noteOverrides(in: orders, now: t(120))
        #expect(noted && changes[Self.pr(4102)]?.replaced == OrderPlace(orders: [planID: [Self.pr(4101)], otherID: [Self.pr(4112)]]))
        var missions = Self.missions(facts, orders, changes)
        let other = try Self.mission(.plan(otherID), in: missions)
        #expect(OrderBoardTests.summary(other.steps) == ["1 !4111 Next to merge", "2 !4112 Merge after !4111", "3 !4102 Merge after !4112"])
        #expect(try Self.mission(.plan(planID), in: missions).steps.map(\.ref) == [Self.pr(4101)])

        orders = try tell([(4111, []), (4112, [4111]), (4102, [4111])], replacing: orders, id: otherID, at: 180)
        noted = changes.noteOverrides(in: orders, now: t(180))
        #expect(noted && changes[Self.pr(4102)]?.holds(in: orders) == true)
        missions = Self.missions(facts, orders, changes)
        #expect(try Self.mission(.plan(planID), in: missions).steps.map(\.ref) == [Self.pr(4101)])

        orders = try tell([(4111, []), (4112, [4111])], replacing: orders, id: otherID, at: 240)
        #expect(changes[Self.pr(4102)]?.holds(in: orders) == false)
        missions = Self.missions(facts, orders, changes)
        #expect(try Self.mission(.plan(planID), in: missions).steps.map(\.ref) == [Self.pr(4101), Self.pr(4102)])
    }

    /// A session that names one you set as next beside its order, stacked with its own, agrees with you while it puts it
    /// after nothing there; putting it after another goes against yours.
    @Test func aSessionThatNamesOneYouSetAsNextBesideItsOrderAgreesUnlessItPutsItAfterAnother() throws {
        let orders = try tell([(4100, []), (4102, [])])
        let facts = OrderFacts(pullRequests: [
            Self.ado(4100), OrderBoardTests.ado(4101, from: "users/robin/a"),
            OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a"),
        ])
        var changes = OrderChanges()
        #expect(try Self.mission(.plan(planID), in: Self.missions(facts, orders, changes)).attached.map(\.ref) == [Self.pr(4101)])
        try changes.apply(.setNext(Self.pr(4101), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))

        let named = try tell([(4100, []), (4101, []), (4102, [4101])], replacing: orders, at: 120)
        #expect(changes[Self.pr(4101)]?.holds(in: named) == true)
        let step = try Self.step(4101, in: Self.mission(.plan(planID), in: Self.missions(facts, named, changes)))
        #expect(step.standing == .next && step.notes == [.yourNext(t(60))])

        let after = try tell([(4100, []), (4101, [4100]), (4102, [4101])], replacing: orders, at: 120)
        #expect(changes[Self.pr(4101)]?.holds(in: after) == false)
    }

    /// A session that puts a pull request after what you did, or puts the one you set as next after nothing, agrees with
    /// you; once BriefBar saw that, putting the one you set as next after another again goes against yours.
    @Test func aSessionThatOrdersItAsYouDidAgreesWithYou() throws {
        var orders = try tell([(4101, []), (4102, [4101]), (4103, [4101])])
        let facts = Self.facts([4101, 4102, 4103])
        var changes = OrderChanges()
        try changes.apply(.mergeAfter(Self.pr(4103), Self.pr(4102), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))
        try changes.apply(.setNext(Self.pr(4102), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(70))

        orders = try tell([(4101, []), (4102, []), (4103, [4101, 4102])], replacing: orders, at: 120)
        #expect(changes[Self.pr(4103)]?.holds(in: orders) == true && changes[Self.pr(4102)]?.holds(in: orders) == true)
        let mission = try Self.mission(.plan(planID), in: Self.missions(facts, orders, changes))
        #expect(try Self.step(4103, in: mission).notes == [.yourAfter([Self.pr(4102)], t(60))])
        #expect(try Self.step(4102, in: mission).standing == .next)
        let noted = changes.noteOverrides(in: orders, now: t(120))
        #expect(noted && changes[Self.pr(4102)]?.replaced == OrderPlace(orders: [planID: []]))

        orders = try tell([(4101, []), (4102, [4101]), (4103, [4101, 4102])], replacing: orders, at: 180)
        #expect(changes[Self.pr(4102)]?.holds(in: orders) == false && changes[Self.pr(4103)]?.holds(in: orders) == true)
    }

    /// An order that went against yours, forgotten since, is no change: yours holds again, and BriefBar notes that.
    @Test func yoursHoldsAgainOnceTheOrderThatWentAgainstItIsForgotten() throws {
        var orders = try tell([(4101, []), (4102, [4101])])
        let facts = Self.facts([4101, 4102, 4110])
        let mine = MissionKey.mine(UUID(uuidString: "66666666-7777-4888-8999-aaaaaaaaaaaa")!)
        var changes = OrderChanges()
        try changes.apply(
            .move([Self.pr(4102), Self.pr(4110)], to: .into(mine), from: nil), missions: Self.missions(facts, orders, changes),
            orders: orders, now: t(60)
        )
        orders = try tell([(4120, []), (4102, [4120])], replacing: orders, id: otherID, at: 120)
        var noted = changes.noteOverrides(in: orders, now: t(120))
        #expect(noted && changes[Self.pr(4102)]?.overridden == OrderChange.Overridden(by: otherID, at: t(120)))
        let without = try Self.mission(mine, in: Self.missions(facts, orders, changes))
        #expect(!without.contains(Self.pr(4102)))

        orders.forget(otherID)
        #expect(changes[Self.pr(4102)]?.holds(in: orders) == true)
        noted = changes.noteOverrides(in: orders, now: t(180))
        #expect(noted && changes[Self.pr(4102)]?.overridden == nil)
        let missions = Self.missions(facts, orders, changes)
        #expect(try Self.mission(mine, in: missions).steps.map(\.ref) == [Self.pr(4102), Self.pr(4110)])
        #expect(!MissionChoices.of(Self.pr(4102), missions: missions, changes: changes, orders: orders).canPutBack)
    }

    /// The one you set as next in an order that's forgotten since says so wherever it shows, and where it's in no mission.
    @Test func setAsNextInAnOrderThatsGoneSaysSo() throws {
        var orders = try tell([(4101, []), (4102, [4101])])
        let opener = ItemRef.session("7a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9")!
        let facts = Self.facts([4101, 4102], sessions: [OrderSession(ref: opener, pullRequests: [Self.pr(4101), Self.pr(4102)])])
        var changes = OrderChanges()
        try changes.apply(.setNext(Self.pr(4102), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))

        orders.forget(planID)
        #expect(changes[Self.pr(4102)]?.holds(in: orders) == true)
        let step = try Self.step(4102, in: Self.mission(.family(opener), in: Self.missions(facts, orders, changes)))
        #expect(step.standing == .unordered && step.notes == [.nextElsewhere(.plan(planID))])
        #expect(step.notes.map { OrderText.note($0, of: step.ref) } == ["Its order is gone: you'd set it as next to merge there"])
        #expect(step.notes.allSatisfy { $0.isAboutYourChanges })
        #expect(OrderBoard.notes(outside: Self.pr(4102), missions: [], changes: changes, orders: orders) == [.nextElsewhere(.plan(planID))])
    }

    // MARK: As the coordinator reviewed

    /// A line an order puts a pull request after that goes round with its order's other lines and a stacked branch is set
    /// aside, and says so without naming a change of yours.
    @Test func aLineThatGoesRoundWithItsOrdersOthersAndAStackedBranchSaysSo() throws {
        let orders = try tell([(4101, []), (4102, [4101]), (4103, [4102])])
        let facts = OrderFacts(pullRequests: [
            OrderBoardTests.ado(4101, from: "users/robin/a", into: "users/robin/c"), Self.ado(4102),
            OrderBoardTests.ado(4103, from: "users/robin/c"),
        ])
        let step = try Self.step(4103, in: Self.mission(.plan(planID), in: Self.missions(facts, orders, OrderChanges())))
        #expect(step.notes == [.setAside(Self.pr(4102), by: Self.session, through: .itsOrder)])
        let names = OrderNames(name: { $0 == Self.session ? "Fix the payments bugs" : nil })
        #expect(step.notes.map { OrderText.note($0, of: step.ref, names: names) }
            == ["‘Fix the payments bugs’ puts it after !4102, but !4102 waits for it through its order and a stacked branch"])
        #expect(!step.notes.contains { $0.isAboutYourChanges })
    }

    /// Setting one beside its order as next, then not, leaves nothing of it: it's beside its order again, never moved; and
    /// so does checking then unchecking what it merges after.
    @Test func settingOneBesideItsOrderAsNextAndBackLeavesNothing() throws {
        let orders = try tell([(4100, []), (4102, [])])
        let facts = OrderFacts(pullRequests: [
            Self.ado(4100), OrderBoardTests.ado(4101, from: "users/robin/a"),
            OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a"),
        ])
        var changes = OrderChanges()
        try changes.apply(.setNext(Self.pr(4101), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))
        #expect(changes[Self.pr(4101)]?.isAttached == true)
        var mission = try Self.mission(.plan(planID), in: Self.missions(facts, orders, changes))
        #expect(try Self.step(4101, in: mission).notes == [.yourNext(t(60))])

        try changes.apply(.setNext(Self.pr(4101), in: .plan(planID), false), missions: Self.missions(facts, orders, changes), orders: orders, now: t(70))
        #expect(changes.isEmpty)
        mission = try Self.mission(.plan(planID), in: Self.missions(facts, orders, changes))
        #expect(mission.attached.map(\.ref) == [Self.pr(4101)] && mission.changedByYou == 0)

        try changes.apply(.mergeAfter(Self.pr(4101), Self.pr(4100), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(80))
        #expect(changes[Self.pr(4101)]?.isAttached == true)
        try changes.apply(.mergeAfter(Self.pr(4101), Self.pr(4100), in: .plan(planID), false), missions: Self.missions(facts, orders, changes), orders: orders, now: t(90))
        #expect(changes.isEmpty)
    }

    /// Undo Your Changes to This Mission takes back, as its ⋯ counts, those that name its chain by another of its own.
    @Test func undoYourChangesToThisMissionFindsItsChainByAnyOfItsOwn() throws {
        let facts = OrderFacts(pullRequests: [
            OrderBoardTests.ado(4101, from: "users/robin/a", state: .merged), OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a"),
            OrderBoardTests.ado(4103, from: "users/robin/c", into: "users/robin/b"), Self.ado(4110),
        ])
        var changes = OrderChanges([OrderChange(ref: Self.pr(4110), placement: .outside, from: .chain(Self.pr(4102)), changedAt: t(60))])
        let missions = Self.missions(facts, DeclaredOrders(), changes)
        #expect(missions.map(\.key) == [.chain(Self.pr(4101))])
        #expect(changes.undone(in: .chain(Self.pr(4101)), missions: missions).map(\.ref) == [Self.pr(4110)])
        try changes.apply(.undoMission(.chain(Self.pr(4101))), missions: missions, orders: DeclaredOrders(), now: t(70))
        #expect(changes.isEmpty)
    }

    /// VoiceOver's actions do without Merge After's: the rest of what a menu offers is the same.
    @Test func choicesWithoutMergeAftersSayTheSameOfTheRest() throws {
        let orders = try tell([(4101, []), (4102, [4101]), (4103, [4101])])
        let facts = Self.facts([4101, 4102, 4103])
        var changes = OrderChanges()
        try changes.apply(.setNext(Self.pr(4103), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))
        let missions = Self.missions(facts, orders, changes)
        for number in [4101, 4102, 4103] {
            var full = MissionChoices.of(Self.pr(number), missions: missions, changes: changes, orders: orders)
            let quick = MissionChoices.of(Self.pr(number), missions: missions, changes: changes, orders: orders, withPrerequisites: false)
            #expect(!full.prerequisites.isEmpty && quick.prerequisites.isEmpty)
            full.prerequisites = []
            #expect(quick == full)
        }
    }

    /// Setting another as next where you'd set one beside its order takes that one back beside it, leaving nothing of yours.
    @Test func anotherSetAsNextTakesOneBesideItsOrderBackBesideIt() throws {
        let orders = try tell([(4100, []), (4102, [])])
        let facts = OrderFacts(pullRequests: [
            Self.ado(4100), OrderBoardTests.ado(4101, from: "users/robin/a"),
            OrderBoardTests.ado(4102, from: "users/robin/b", into: "users/robin/a"),
        ])
        var changes = OrderChanges()
        try changes.apply(.setNext(Self.pr(4101), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(60))
        let touched = try changes.apply(
            .setNext(Self.pr(4100), in: .plan(planID), true), missions: Self.missions(facts, orders, changes), orders: orders, now: t(70)
        )
        #expect(changes[Self.pr(4101)] == nil && changes[Self.pr(4100)]?.first == .plan(planID))
        #expect(try Self.mission(.plan(planID), in: Self.missions(facts, orders, changes)).attached.map(\.ref) == [Self.pr(4101)])
        changes.restore(touched)
        #expect(changes[Self.pr(4101)]?.isAttached == true && changes[Self.pr(4100)] == nil)
    }
}
