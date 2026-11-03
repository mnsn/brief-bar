import Foundation
import Testing
@testable import BriefBarCore

@Suite struct OrderBoardTests {
    static let repository = "contoso/7d3f9a12/shop-web"
    static let gitHubRepository = "octo/storefront"
    private let planID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    static func pr(_ number: Int) -> ItemRef { OrderPlansTests.pr(number) }

    static func gh(_ number: Int) -> ItemRef { .gitHubPullRequest(repository: gitHubRepository, number: number) }

    /// An Azure DevOps pull request from `source` into `target`, opened at `number` seconds unless said.
    static func ado(
        _ number: Int, from source: String, into target: String = "main", state: PullRequestState = .open,
        author: String? = "robin", isFork: Bool? = nil, defaultBranch: String? = nil, attention: ItemState? = nil,
        repository: String = repository
    ) -> OrderPullRequest {
        OrderPullRequest(
            ref: pr(number), repository: repository, sourceBranch: "refs/heads/\(source)", targetBranch: "refs/heads/\(target)",
            isFork: isFork, defaultBranch: defaultBranch, author: author, state: state, attention: attention,
            createdAt: t(Double(number))
        )
    }

    /// Steps' references, numbers and where each stands, in words.
    static func summary(_ steps: [OrderStep]) -> [String] {
        steps.map { step in
            let number = step.number.map(String.init) ?? "–"
            return "\(number) \(step.ref.shortOrderLabel) \(OrderText.standing(step) ?? "")"
        }
    }

    // MARK: What BriefBar sees

    @Test func aPullRequestThatTargetsAnothersBranchMergesAfterIt() {
        let facts = OrderFacts(pullRequests: [
            Self.ado(4101, from: "users/robin/rounding"),
            Self.ado(4102, from: "users/robin/cart", into: "users/robin/rounding"),
        ])
        #expect(OrderInference.edges(facts) == [OrderEdge(Self.pr(4101), Self.pr(4102)): [.branch]])
    }

    @Test func branchesSayNothingAcrossRepositoriesFromForksOrOnBranchesPeopleShare() {
        let stacked = Self.ado(4102, from: "users/robin/cart", into: "users/robin/rounding")
        let cases: [String: [OrderPullRequest]] = [
            "another repository": [Self.ado(4101, from: "users/robin/rounding", repository: "contoso/7d3f9a12/other"), stacked],
            "a fork": [Self.ado(4101, from: "users/robin/rounding", isFork: true), stacked],
            "maybe a fork, by someone else": [Self.ado(4101, from: "users/robin/rounding", author: "sam"), stacked],
            "the default branch": [Self.ado(4101, from: "users/robin/rounding", defaultBranch: "users/robin/rounding"), stacked],
            "a branch everybody works on": [
                Self.ado(4101, from: "develop"), Self.ado(4102, from: "users/robin/cart", into: "develop"),
            ],
            "a branch more than three merge into": [Self.ado(4101, from: "users/robin/rounding")] + (4102...4105).map {
                Self.ado($0, from: "users/robin/part-\($0)", into: "users/robin/rounding")
            },
            "a branch two come from": [
                Self.ado(4101, from: "users/robin/rounding"), Self.ado(4103, from: "users/robin/rounding", into: "release/2.3"), stacked,
            ],
        ]
        for (name, pullRequests) in cases {
            #expect(OrderInference.edges(OrderFacts(pullRequests: pullRequests)).isEmpty, "\(name)")
        }
        // Not a fork, by someone else: it stacks.
        let notAFork = OrderFacts(pullRequests: [Self.ado(4101, from: "users/robin/rounding", author: "sam", isFork: false), stacked])
        #expect(OrderInference.edges(notAFork).keys.map(\.after) == [Self.pr(4102)])
    }

    @Test func aGitHubStackGoesByItsPositionsWithWhatMergedBelow() throws {
        let stack = GitHubStack(repository: "Octo/Storefront", number: 41, baseBranch: "main", members: [
            .init(position: 2, ref: Self.gh(211), state: .merged),
            .init(position: 1, ref: Self.gh(210), state: .merged),
            .init(position: 3, ref: Self.gh(212), state: .open),
            .init(position: 4, ref: Self.gh(213), state: .open),
        ])
        let facts = OrderFacts(pullRequests: [
            OrderPullRequest(
                ref: Self.gh(212), repository: Self.gitHubRepository, sourceBranch: "address-form", targetBranch: "main",
                isFork: false, attention: .needsYou, createdAt: t(5), stack: stack
            ),
            OrderPullRequest(
                ref: Self.gh(213), repository: Self.gitHubRepository, sourceBranch: "saved-addresses", targetBranch: "address-form",
                isFork: false, createdAt: t(4), stack: stack
            ),
        ])
        let edges = OrderInference.edges(facts)
        #expect(edges[OrderEdge(Self.gh(210), Self.gh(211))] == [.gitHubStack(number: 41, position: 2, size: 4)])
        #expect(edges[OrderEdge(Self.gh(212), Self.gh(213))] == [.gitHubStack(number: 41, position: 4, size: 4), .branch])
        #expect(facts.observations == [
            OrderObservation(ref: Self.gh(212), state: .open, witness: .list),
            OrderObservation(ref: Self.gh(213), state: .open, witness: .list),
            OrderObservation(ref: Self.gh(210), state: .merged, witness: .gitHubStack),
            OrderObservation(ref: Self.gh(211), state: .merged, witness: .gitHubStack),
        ])

        let missions = OrderBoard.missions(facts: facts, orders: DeclaredOrders(), evidence: OrderEvidence(), now: t(10))
        let mission = try #require(missions.first)
        #expect(missions.count == 1)
        #expect(mission.key == .stack(repository: "octo/storefront", number: 41))
        #expect(mission.kind == .stack)
        #expect(mission.attention == .needsYou)
        #expect(Self.summary(mission.steps) == ["1 #210 Merged", "2 #211 Merged", "3 #212 Next to merge", "4 #213 Merge after #212"])
        let top = mission.steps[3]
        #expect(top.prerequisites == [
            OrderPrerequisite(ref: Self.gh(212), origins: [.gitHubStack(number: 41, position: 4, size: 4), .branch], status: .open),
        ])
        #expect(top.notes == [.showsAgainst(Self.gh(212))])
        #expect(OrderText.note(top.notes[0], of: top.ref) == "Its changes show against #212's branch, which may still change")
        #expect(OrderText.origin(top.prerequisites[0].origins[0], earlier: Self.gh(212), later: top.ref) == "GitHub stack 41, 4 of 4")
    }

    // MARK: A session's order

    /// The user's example, with x1 to x6 as !4101 to !4106, each on a branch of its own into main.
    static func userExampleFacts(_ first: PullRequestState? = .merged) -> OrderFacts {
        var pullRequests = (4102...4106).map { Self.ado($0, from: "users/robin/part-\($0)") }
        if let first { pullRequests.append(Self.ado(4101, from: "users/robin/part-4101", state: first)) }
        return OrderFacts(pullRequests: pullRequests)
    }

    @Test func aSessionsOrderNumbersWhatMergesInOrderAndLeavesWhatGoesAnyTimeLast() throws {
        var orders = DeclaredOrders()
        try orders.apply(OrderPlansTests.userExample, now: t(0), newID: planID)
        let missions = OrderBoard.missions(facts: Self.userExampleFacts(), orders: orders, evidence: OrderEvidence(), now: t(60))
        let mission = try #require(missions.first)
        #expect(missions.count == 1)
        #expect(mission.key == .plan(planID))
        #expect(mission.kind == .declared(id: planID, revision: 1, declaredBy: nil, updatedAt: t(0)))
        #expect(Self.summary(mission.steps) == [
            "1 !4101 Merged",
            "2 !4102 Next to merge",
            "3 !4103 Merge after !4102",
            "4 !4105 Merge after !4102",
            "5 !4106 Merge after !4105",
            "– !4104 Any time",
        ])
        #expect(mission.steps[1].prerequisites == [
            OrderPrerequisite(ref: Self.pr(4101), origins: [.declared(revision: 1)], status: .merged),
        ])
        #expect(!mission.isFinished && !mission.isStale)
    }

    @Test func onlyAMergeBriefBarSawCountsAndOneItCantSeeStaysUnresolved() throws {
        var orders = DeclaredOrders()
        try orders.apply(OrderPlansTests.userExample, now: t(0), newID: planID)
        func standings(_ facts: OrderFacts, _ evidence: OrderEvidence = OrderEvidence()) throws -> [String] {
            let mission = try #require(OrderBoard.missions(facts: facts, orders: orders, evidence: evidence, now: t(60)).first)
            return Self.summary(Array(mission.steps.prefix(2)))
        }
        // Gone from the list, it didn't merge for all that.
        #expect(try standings(Self.userExampleFacts(nil)) == [
            "1 !4101 BriefBar can't see it now", "2 !4102 Merge after !4101 · BriefBar can't see whether !4101 merged",
        ])
        var evidence = OrderEvidence()
        evidence.observe(OrderObservation(ref: Self.pr(4101), state: .merged, witness: .list), at: t(30))
        #expect(try standings(Self.userExampleFacts(nil), evidence) == ["1 !4101 Merged", "2 !4102 Next to merge"])
        var closed = OrderEvidence()
        closed.observe(OrderObservation(ref: Self.pr(4101), state: .closed, witness: .list), at: t(30))
        let closedStandings = ["1 !4101 Closed without merging", "2 !4102 !4101 was closed without merging: check the order"]
        #expect(try standings(Self.userExampleFacts(nil), closed) == closedStandings)
        #expect(try standings(Self.userExampleFacts(.closed)) == closedStandings)
        // Reactivated and listed again, it's where its list shows it, whatever was kept.
        #expect(try standings(Self.userExampleFacts(.open), closed) == ["1 !4101 Next to merge", "2 !4102 Merge after !4101"])
        let off = OrderFacts(pullRequests: [], sourcesOn: [.gitHubPullRequest])
        #expect(try standings(off) == ["1 !4101 Azure DevOps is off in BriefBar", "2 !4102 Azure DevOps is off in BriefBar"])
    }

    @Test func oneThatStillTargetsTheBranchOfOneThatMergedIsToBeRetargetedWhereThatOneWent() throws {
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [
            .init(link: OrderPlansTests.link(4101)), .init(link: OrderPlansTests.link(4102), after: ["4101"]),
        ]), now: t(0), newID: planID)
        func second(_ first: OrderPullRequest) throws -> String? {
            let facts = OrderFacts(pullRequests: [first, Self.ado(4102, from: "users/robin/cart", into: "users/robin/rounding")])
            let mission = try #require(OrderBoard.missions(facts: facts, orders: orders, evidence: OrderEvidence(), now: t(60)).first)
            return OrderText.standing(mission.steps[1])
        }
        #expect(try second(Self.ado(4101, from: "users/robin/rounding", into: "release/2.3", state: .merged))
            == "!4101 merged: retarget it to release/2.3")
        var unknownTarget = Self.ado(4101, from: "users/robin/rounding", state: .merged)
        unknownTarget.targetBranch = ""
        #expect(try second(unknownTarget) == "!4101 merged: retarget it to the branch !4101 merged into")
        #expect(try second(Self.ado(4101, from: "users/robin/rounding")) == "Merge after !4101")
    }

    @Test func whereBriefBarSeesAnOrderTheSessionsOrderDoesntItSaysSoAndTheOrderDecides() throws {
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [
            .init(link: OrderPlansTests.link(4101)), .init(link: OrderPlansTests.link(4102)),
        ]), now: t(0), newID: planID)
        let facts = OrderFacts(pullRequests: [
            Self.ado(4101, from: "users/robin/rounding"), Self.ado(4102, from: "users/robin/cart", into: "users/robin/rounding"),
        ])
        var mission = try #require(OrderBoard.missions(facts: facts, orders: orders, evidence: OrderEvidence(), now: t(60)).first)
        #expect(Self.summary(mission.steps) == ["– !4101 Any time", "– !4102 Any time"])
        #expect(mission.steps[1].notes.map { OrderText.note($0, of: Self.pr(4102)) } == [
            "Its changes show against !4101's branch, which may still change",
            "It targets !4101's branch; its order doesn't put it after !4101",
        ])
        try orders.apply(OrderRequest(plan: planID.uuidString, revision: 1, entries: [
            .init(link: OrderPlansTests.link(4101)), .init(link: OrderPlansTests.link(4102), after: ["4101"]),
        ]), now: t(30))
        mission = try #require(OrderBoard.missions(facts: facts, orders: orders, evidence: OrderEvidence(), now: t(60)).first)
        #expect(Self.summary(mission.steps) == ["1 !4101 Next to merge", "2 !4102 Merge after !4101"])
        #expect(mission.steps[1].notes == [.showsAgainst(Self.pr(4101))])
        #expect(mission.steps[1].prerequisites[0].origins == [.declared(revision: 2), .branch])
    }

    @Test func pullRequestsTheOrderDoesntNameShowApartWithItWhenStackedOnlyWithItsOwn() throws {
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [
            .init(link: OrderPlansTests.link(4101)), .init(link: OrderPlansTests.link(4102), after: ["4101"]),
        ]), now: t(0), newID: planID)
        let facts = OrderFacts(pullRequests: [
            Self.ado(4101, from: "users/robin/rounding"),
            Self.ado(4102, from: "users/robin/cart"),
            Self.ado(4109, from: "users/robin/docs", into: "users/robin/cart"),
            Self.ado(4111, from: "users/robin/docs-images", into: "users/robin/docs"),
        ])
        let missions = OrderBoard.missions(facts: facts, orders: orders, evidence: OrderEvidence(), now: t(60))
        #expect(missions.map(\.key) == [.plan(planID)])
        let attached = try #require(missions.first?.attached)
        #expect(attached.map(\.ref) == [Self.pr(4109), Self.pr(4111)])
        #expect(attached.allSatisfy { $0.standing == .notInOrder && $0.number == nil && OrderText.standing($0) == nil })
        #expect(attached[0].notes.map { OrderText.note($0, of: Self.pr(4109)) } == ["Targets !4102's branch", "!4111 targets its branch"])
        #expect(attached[1].notes.map { OrderText.note($0, of: Self.pr(4111)) } == ["Targets !4109's branch"])
    }

    @Test func ordersThatShareAPullRequestStayApartAndEachSaysSo() throws {
        var orders = DeclaredOrders()
        let first = try orders.apply(OrderRequest(entries: [
            .init(link: OrderPlansTests.link(4101)), .init(link: OrderPlansTests.link(4102), after: ["4101"]),
        ]), now: t(0))
        let second = try orders.apply(OrderRequest(entries: [
            .init(link: OrderPlansTests.link(4102)), .init(link: OrderPlansTests.link(4110), after: ["4102"]),
        ]), now: t(1))
        let facts = OrderFacts(pullRequests: [4101, 4102, 4110].map { Self.ado($0, from: "users/robin/part-\($0)") })
        let missions = OrderBoard.missions(facts: facts, orders: orders, evidence: OrderEvidence(), now: t(60))
        #expect(Set(missions.map(\.key)) == [.plan(first.id), .plan(second.id)])
        let inFirst = try #require(missions.first { $0.key == .plan(first.id) }?.steps.first { $0.ref == Self.pr(4102) })
        let inSecond = try #require(missions.first { $0.key == .plan(second.id) }?.steps.first { $0.ref == Self.pr(4102) })
        #expect(inFirst.notes == [.alsoIn([second.id])])
        #expect(inSecond.notes == [.alsoIn([first.id])])
        #expect(OrderText.note(inFirst.notes[0], of: inFirst.ref) == "Also in another order")
        #expect(OrderText.standing(inFirst) == "Merge after !4101")
        #expect(OrderText.standing(inSecond) == "Next to merge")
    }

    @Test func pullRequestsOpenedUnderOneSessionGroupWithNoOrderOneLevelUpOnly() throws {
        let root = ItemRef.session("00000000-0000-4000-8000-000000000001")!
        let coordinator = ItemRef.session("00000000-0000-4000-8000-000000000002")!
        let cart = ItemRef.session("00000000-0000-4000-8000-000000000003")!
        let giftCards = ItemRef.session("00000000-0000-4000-8000-000000000004")!
        let alone = ItemRef.session("00000000-0000-4000-8000-000000000005")!
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [.init(link: OrderPlansTests.link(4122))]), now: t(0), newID: planID)
        let facts = OrderFacts(
            pullRequests: [
                Self.ado(4120, from: "users/robin/cart", attention: .needsYou), Self.ado(4121, from: "users/robin/gift-cards"),
                Self.ado(4122, from: "users/robin/cart-tests"), Self.ado(4123, from: "users/robin/old", state: .merged),
                Self.ado(4130, from: "users/robin/alone"),
            ],
            sessions: [
                OrderSession(ref: coordinator, parent: root, coordinator: root),
                OrderSession(ref: cart, parent: coordinator, coordinator: coordinator, pullRequests: [Self.pr(4120), Self.pr(4122)]),
                OrderSession(ref: giftCards, parent: coordinator, pullRequests: [Self.pr(4121), Self.pr(4123)]),
                OrderSession(ref: alone, pullRequests: [Self.pr(4130)]),
            ]
        )
        let missions = OrderBoard.missions(facts: facts, orders: orders, evidence: OrderEvidence(), now: t(60))
        #expect(missions.map(\.key) == [.plan(planID), .family(coordinator)])
        let family = try #require(missions.last)
        #expect(family.kind == .family(session: coordinator))
        #expect(family.steps.map(\.ref) == [Self.pr(4120), Self.pr(4121)])
        #expect(family.steps.allSatisfy { $0.number == nil && $0.standing == .unordered && OrderText.standing($0) == nil })
        #expect(family.attention == .needsYou)
    }

    @Test func theFocusedMissionComesFirstThenThoseStillGoingByWhatNeedsYouAndFinishedOnesLast() throws {
        var orders = DeclaredOrders()
        let finished = UUID(), waiting = UUID(), failing = UUID()
        try orders.apply(OrderRequest(entries: [.init(link: OrderPlansTests.link(4201))]), now: t(0), newID: finished)
        try orders.apply(OrderRequest(entries: [.init(link: OrderPlansTests.link(4202))]), now: t(10), newID: waiting)
        try orders.apply(OrderRequest(entries: [.init(link: OrderPlansTests.link(4203))]), now: t(5), newID: failing)
        let facts = OrderFacts(pullRequests: [
            Self.ado(4201, from: "users/robin/a", state: .merged),
            Self.ado(4202, from: "users/robin/b", attention: .done),
            Self.ado(4203, from: "users/robin/c", attention: .failing),
        ])
        let monthLater = t(31 * 86_400)
        var missions = OrderBoard.missions(facts: facts, orders: orders, evidence: OrderEvidence(), now: monthLater)
        #expect(missions.map(\.key) == [.plan(failing), .plan(waiting), .plan(finished)])
        #expect(missions.map(\.isFinished) == [false, false, true])
        // Not told again for a month and not finished: marked, and kept.
        #expect(missions.map(\.isStale) == [true, true, false])
        missions = OrderBoard.missions(facts: facts, orders: orders, evidence: OrderEvidence(), focus: .plan(finished), now: monthLater)
        #expect(missions.map(\.key) == [.plan(finished), .plan(failing), .plan(waiting)])
        #expect(missions.map(\.isFocused) == [true, false, false])
        #expect(OrderBoard.missions(facts: facts, orders: orders, evidence: OrderEvidence(), now: t(60)).allSatisfy { !$0.isStale })
    }

    @Test func pullRequestsThatGoBeforeEachOtherAreToBeChecked() throws {
        let facts = OrderFacts(pullRequests: [
            Self.ado(4101, from: "users/robin/a", into: "users/robin/b"), Self.ado(4102, from: "users/robin/b", into: "users/robin/a"),
        ])
        let mission = try #require(
            OrderBoard.missions(facts: facts, orders: DeclaredOrders(), evidence: OrderEvidence(), now: t(60)).first
        )
        #expect(mission.key == .chain(Self.pr(4101)))
        #expect(mission.cycles == [[Self.pr(4101), Self.pr(4102)]])
        #expect(Self.summary(mission.steps) == [
            "1 !4101 It and !4102 go before each other: check the order", "2 !4102 It and !4101 go before each other: check the order",
        ])
        #expect(OrderText.cycle(mission.cycles[0]) == "!4101 and !4102 go before each other: check the order")
    }

    @Test func whenASessionSuggestsReviewingOneItsAdviceWithItsReasonUntilWhatItWaitsForMerges() throws {
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [
            .init(link: OrderPlansTests.link(4102)),
            .init(link: OrderPlansTests.link(4103), after: ["4102"], review: .after(["4102"], reason: "builds_on_changes")),
            .init(link: OrderPlansTests.link(4104), review: .now),
        ]), now: t(0), newID: planID)
        func reviews(_ state: PullRequestState) throws -> [String?] {
            let facts = OrderFacts(pullRequests: [
                Self.ado(4102, from: "users/robin/b", state: state), Self.ado(4103, from: "users/robin/c"),
                Self.ado(4104, from: "users/robin/d"),
            ])
            let mission = try #require(OrderBoard.missions(facts: facts, orders: orders, evidence: OrderEvidence(), now: t(60)).first)
            return mission.steps.map { step in step.review.map { OrderText.review($0, of: step.ref, session: "Cart totals") } }
        }
        #expect(try reviews(.open) == [
            nil,
            "Review after !4102: it builds on !4102's changes, which may still change",
            "‘Cart totals’ says it can be reviewed now",
        ])
        #expect(try reviews(.merged) == [nil, nil, "‘Cart totals’ says it can be reviewed now"])
    }

    @Test func wordsNameEachPullRequestAsItReadsBesideTheOneTheyreAboutAndNeverSayReady() {
        #expect(OrderText.list([Self.pr(4101), Self.pr(4102), Self.pr(4103)]) == "!4101, !4102 and !4103")
        #expect(OrderText.list([Self.gh(212)], near: Self.pr(4101)) == "octo/storefront#212")
        #expect(OrderText.list([OrderPlansTests.pr(4101, in: "fabrikam")], near: Self.pr(4102)) == "!4101 in fabrikam")
        #expect(OrderText.standing(.waiting(open: [Self.pr(4102)], unknown: [Self.pr(4107)]), of: Self.pr(4105))
            == "Merge after !4102 and !4107 · BriefBar can't see whether !4107 merged")
        #expect(OrderText.standing(.notVisible(.sourceOff), of: Self.gh(212)) == "GitHub is off in BriefBar")
        #expect(OrderText.review(.after([Self.pr(4102), Self.pr(4103)], .stackedDiff), of: Self.pr(4105))
            == "Review after !4102 and !4103: its changes include theirs until they merge")
        #expect(OrderText.review(.now, of: Self.pr(4105)) == "Its order says it can be reviewed now")
        let beforeIt = OrderNote.stackedWith(Self.gh(212), comesAfter: false, .gitHubStack(number: 41, position: 3, size: 4))
        #expect(OrderText.note(beforeIt, of: Self.gh(211))
            == "Before #212 in GitHub stack 41")
        let standings: [OrderStanding] = [
            .merged, .closed, .notVisible(.notListed), .next, .anyTime, .waiting(open: [Self.pr(1)], unknown: []),
            .unresolved([Self.pr(1)]), .prerequisiteClosed(Self.pr(1)), .retarget(after: Self.pr(1), to: nil), .inCycle(with: [Self.pr(1)]),
        ]
        for standing in standings {
            #expect(OrderText.standing(standing, of: Self.pr(2))?.lowercased().contains("ready") == false, "\(standing)")
        }
    }
}
