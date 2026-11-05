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

        // A session that takes it out of its order changed its place too.
        orders = try tell([(4101, []), (4102, [4101])], replacing: orders, at: 600)
        #expect(changes[Self.pr(4103)]?.overridden(in: orders)
            == OrderOverride(by: Self.session, at: t(600), now: .out, yours: .next))
        // Forgetting an order is no change of its place.
        var forgotten = orders
        forgotten.forget(planID)
        #expect(changes[Self.pr(4103)]?.holds(in: forgotten) == true)
        // And an order that starts naming it is.
        orders = try tell([(4103, [])], replacing: orders, id: otherID, at: 700)
        #expect(changes[Self.pr(4103)]?.holds(in: orders) == false)
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
        #expect(changes[Self.pr(4102)]?.holds(in: orders) == false)
        #expect(changes[Self.pr(4102)]?.overridden(in: orders) == nil)
        step = try Self.step(4102, in: Self.mission(.plan(planID), in: Self.missions(facts, orders, changes)))
        #expect(step.notes.isEmpty && !step.isYours)
        #expect(!MissionChoices.of(Self.pr(4102), missions: Self.missions(facts, orders, changes), changes: changes, orders: orders).canPutBack)
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
        #expect(moved.isYours && OrderBoard.step(for: Self.pr(4102), in: missions) == nil)

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
        #expect(moved)
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
        let text = try #require(defaults.data(forKey: DeclaredOrders.defaultsKey).flatMap { String(data: $0, encoding: .utf8) })
        // What an older `--mcp` writes: the fields it knows, the same as now.
        for field in ["\"id\"", "\"revision\"", "\"entries\"", "\"pullRequest\"", "\"after\""] {
            #expect(text.contains(field), "\(field)")
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
        #expect(moved)
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
}
