import Foundation
import Testing
@testable import BriefBarCore

/// Missions by story (§7.4): pull requests whose work items are a story's tasks, or the story itself, go together as its
/// mission, in its tasks' backlog order, with no merge order claimed; where they rank against orders, stacks and the
/// sessions they were opened under; and what follows a mission as its key changes.
@Suite struct StoryMissionsTests {
    private let planID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let otherPlanID = UUID(uuidString: "11111111-2222-4333-8444-666666666666")!

    static func pr(_ number: Int) -> ItemRef { OrderBoardTests.pr(number) }
    static func item(_ id: Int) -> ItemRef { .workItem(organization: "contoso", id: id) }

    /// User Story 5101's task `task`, at `rank` in the backlog.
    static func task(_ task: Int, rank: Double?, of story: Int = 5101, type: String? = "User Story") -> OrderStory {
        OrderStory(ref: item(story), type: type, task: item(task), rank: rank)
    }

    /// An Azure DevOps pull request from its own branch into main, opened at `number` seconds, for these stories.
    static func ado(
        _ number: Int, _ stories: [OrderStory]?, from source: String? = nil, into target: String = "main",
        state: PullRequestState = .open, createdAt: Date? = nil
    ) -> OrderPullRequest {
        var pullRequest = OrderBoardTests.ado(number, from: source ?? "users/robin/part-\(number)", into: target, state: state)
        pullRequest.stories = stories
        if let createdAt { pullRequest.createdAt = createdAt }
        return pullRequest
    }

    static func missions(
        _ facts: OrderFacts, _ orders: DeclaredOrders = DeclaredOrders(), focus: MissionKey? = nil, changes: OrderChanges = OrderChanges()
    ) -> [OrderMission] {
        OrderBoard.missions(facts: facts, orders: orders, evidence: OrderEvidence(), focus: focus, changes: changes, now: t(60))
    }

    static func facts(_ pullRequests: [OrderPullRequest], sessions: [OrderSession] = []) -> OrderFacts {
        OrderFacts(pullRequests: pullRequests, sessions: sessions, readsStories: true)
    }

    // MARK: A story's mission

    @Test func aStorysPullRequestsGoTogetherInItsTasksOrderWithNoOrderKnown() throws {
        // Opened in the other order than their tasks': the tasks' order lists them.
        let missions = Self.missions(Self.facts([
            Self.ado(4105, [Self.task(5103, rank: 1)]),
            Self.ado(4102, [Self.task(5102, rank: 2)]),
            Self.ado(4101, [Self.task(5104, rank: 3)], state: .merged),
        ]))
        let mission = try #require(missions.first)
        #expect(missions.count == 1)
        #expect(mission.key == .story(Self.item(5101)))
        #expect(mission.kind == .story(Self.item(5101)))
        #expect(mission.story == MissionStory(ref: Self.item(5101), type: "User Story"))
        #expect(mission.steps.map(\.ref) == [Self.pr(4105), Self.pr(4102), Self.pr(4101)])
        // No order known: no place, no mark, no capsule, nothing it waits for; one that merged says so, as a session's pull
        // requests' does; and no progress bar.
        let open = mission.steps.filter(\.status.isOpen)
        #expect(open.count == 2)
        #expect(open.allSatisfy { $0.standing == .unordered && $0.standing.marker == .none })
        #expect(open.allSatisfy { OrderText.capsule($0) == nil && OrderText.standing($0) == nil })
        #expect(mission.steps.allSatisfy { $0.number == nil && $0.prerequisites.isEmpty })
        #expect(mission.steps.last?.standing == .merged)
        #expect(!mission.hasOrder && mission.isStory && !mission.isFamily)
        #expect(mission.folded.map(\.ref) == [Self.pr(4101)])
        #expect(OrderText.kind(of: mission) == "No order known")
        #expect(OrderText.story(of: mission, title: "Checkout coupons") == "User Story 5101")
        #expect(OrderText.title(of: mission) { $0 == Self.item(5101) ? "Checkout redesign" : nil } == "Checkout redesign")
        #expect(OrderText.title(of: mission) { _ in nil } == "Work Item 5101")
        // Its title says it already while BriefBar can't read the story.
        var unread = mission
        unread.story?.type = nil
        #expect(OrderText.story(of: unread, title: "Work Item 5101") == nil)
        #expect(OrderText.storyHelp(mission, title: "Checkout redesign")
            == "Its story: ‘Checkout redesign’. Listed in the order of its tasks in the backlog. Nothing says which merges first.")
    }

    @Test func whatTheTasksOrderDoesntKnowGoesLastAndTheOrderIsTotal() throws {
        let pullRequests = [
            // Its task's rank isn't known: after those whose is, by when it was opened.
            Self.ado(4110, [Self.task(5110, rank: nil)], createdAt: t(5)),
            // Linked to the story itself: no task, so no rank.
            Self.ado(4111, [OrderStory(ref: Self.item(5101), type: "User Story")], createdAt: t(4)),
            // Neither rank nor date: last of all.
            Self.ado(4112, [Self.task(5112, rank: nil)], createdAt: nil),
            Self.ado(4113, [Self.task(5113, rank: nil)], createdAt: nil),
            Self.ado(4114, [Self.task(5114, rank: 2)]),
            Self.ado(4115, [Self.task(5115, rank: 1)]),
        ]
        var unopened = pullRequests
        unopened[2].createdAt = nil
        unopened[3].createdAt = nil
        let expected = [4115, 4114, 4111, 4110, 4112, 4113].map(Self.pr)
        for order in [unopened, unopened.reversed(), [unopened[3], unopened[0], unopened[5], unopened[1], unopened[4], unopened[2]]] {
            let mission = try #require(Self.missions(Self.facts(order)).first)
            #expect(mission.steps.map(\.ref) == expected)
        }
    }

    @Test func aStoryWithOnePullRequestIsNoMissionAndItGroupsAsItWouldWithoutIt() throws {
        let coordinator = ItemRef.session("00000000-0000-4000-8000-000000000002")!
        let sessions = [OrderSession(ref: coordinator, pullRequests: [Self.pr(4120), Self.pr(4121)])]
        let missions = Self.missions(Self.facts([
            Self.ado(4120, [Self.task(5102, rank: 1)]), Self.ado(4121, [Self.task(5130, rank: 1, of: 5130)]),
        ], sessions: sessions))
        #expect(missions.map(\.key) == [.family(coordinator)])
        #expect(missions.first?.steps.map(\.ref) == [Self.pr(4120), Self.pr(4121)])
        // Each is for a story of its own: the session's pull requests aren't all for one.
        #expect(missions.first?.story == nil)
    }

    @Test func aStorysMissionShowsWhileTwoOrMoreAreListedMergedOnesIncluded() throws {
        let both = Self.missions(Self.facts([
            Self.ado(4101, [Self.task(5102, rank: 1)], state: .merged), Self.ado(4102, [Self.task(5103, rank: 2)]),
        ]))
        #expect(both.map(\.key) == [.story(Self.item(5101))])
        #expect(OrderText.folded(both[0].folded) == "1 merged")
        // Once Done drops the merged one, it's one pull request alone.
        #expect(Self.missions(Self.facts([Self.ado(4102, [Self.task(5103, rank: 2)])])).isEmpty)
        // Every one merged: it's finished, and goes last.
        let finished = Self.missions(Self.facts([
            Self.ado(4101, [Self.task(5102, rank: 1)], state: .merged), Self.ado(4102, [Self.task(5103, rank: 2)], state: .merged),
            Self.ado(4201, [Self.task(5202, rank: 1, of: 5201)]), Self.ado(4202, [Self.task(5203, rank: 2, of: 5201)]),
        ]))
        #expect(finished.map(\.key) == [.story(Self.item(5201)), .story(Self.item(5101))])
        #expect(finished.map(\.isFinished) == [false, true])
    }

    // MARK: Where it ranks

    @Test func aSessionsOrderThatNamesOneWinsAndTheStorysOthersShowApartInIt() throws {
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [
            .init(link: OrderPlansTests.link(4101)), .init(link: OrderPlansTests.link(4102), after: ["4101"]),
        ]), now: t(0), newID: planID)
        let facts = Self.facts([
            Self.ado(4101, [Self.task(5102, rank: 1)]), Self.ado(4102, [Self.task(5103, rank: 2)]),
            Self.ado(4106, [Self.task(5105, rank: 4)]), Self.ado(4105, [Self.task(5104, rank: 3)]),
        ])
        let missions = Self.missions(facts, orders)
        #expect(missions.map(\.key) == [.plan(planID)])
        let mission = try #require(missions.first)
        #expect(mission.steps.map(\.ref) == [Self.pr(4101), Self.pr(4102)])
        // What it names is all for the story: it says so.
        #expect(mission.story == MissionStory(ref: Self.item(5101), type: "User Story"))
        #expect(mission.sameStory.map(\.ref) == [Self.pr(4105), Self.pr(4106)])
        #expect(mission.sameStory.allSatisfy { $0.standing == .unordered && OrderText.capsule($0) == nil })
        #expect(mission.attached.isEmpty && mission.pullRequestCount == 2)
        #expect(mission.contains(Self.pr(4106)))
        #expect(OrderText.sameStory == "Same story · not in this order")
        #expect(OrderBoard.step(for: Self.pr(4105), in: missions)?.mission.key == .plan(planID))
    }

    @Test func withTwoOrdersForTheStoryItsOthersAreItsOwnMission() throws {
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [.init(link: OrderPlansTests.link(4101))]), now: t(0), newID: planID)
        try orders.apply(OrderRequest(entries: [.init(link: OrderPlansTests.link(4102))]), now: t(0), newID: otherPlanID)
        let missions = Self.missions(Self.facts([
            Self.ado(4101, [Self.task(5102, rank: 1)]), Self.ado(4102, [Self.task(5103, rank: 2)]),
            Self.ado(4105, [Self.task(5104, rank: 3)]), Self.ado(4106, [Self.task(5105, rank: 4)]),
        ]), orders)
        #expect(Set(missions.map(\.key)) == [.plan(planID), .plan(otherPlanID), .story(Self.item(5101))])
        #expect(missions.first { $0.key == .story(Self.item(5101)) }?.steps.map(\.ref) == [Self.pr(4105), Self.pr(4106)])
        #expect(missions.allSatisfy { $0.sameStory.isEmpty })
    }

    /// An order whose own pull requests for a story all merged no longer claims the story's new ones: they're the story's
    /// own mission, as without it, rather than "Same story · not in this order" under a finished order. One of its pull
    /// requests that hasn't merged or closed keeps them.
    @Test func aFinishedOrderLeavesItsStorysNewPullRequestsToTheStory() throws {
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [
            .init(link: OrderPlansTests.link(4101)), .init(link: OrderPlansTests.link(4102), after: ["4101"]),
        ]), now: t(0), newID: planID)
        let new = [Self.ado(4105, [Self.task(5104, rank: 3)]), Self.ado(4106, [Self.task(5105, rank: 4)])]
        var missions = Self.missions(Self.facts([
            Self.ado(4101, [Self.task(5102, rank: 1)], state: .merged), Self.ado(4102, [Self.task(5103, rank: 2)], state: .merged),
        ] + new), orders)
        #expect(Set(missions.map(\.key)) == [.plan(planID), .story(Self.item(5101))])
        #expect(missions.first { $0.key == .plan(planID) }?.sameStory.isEmpty == true)
        #expect(missions.first { $0.key == .story(Self.item(5101)) }?.steps.map(\.ref) == [Self.pr(4105), Self.pr(4106)])

        missions = Self.missions(Self.facts([
            Self.ado(4101, [Self.task(5102, rank: 1)], state: .merged), Self.ado(4102, [Self.task(5103, rank: 2)]),
        ] + new), orders)
        #expect(missions.map(\.key) == [.plan(planID)])
        #expect(missions.first?.sameStory.map(\.ref) == [Self.pr(4105), Self.pr(4106)])
    }

    /// An order that isn't finished claims the stories of all its pull requests, merged ones included, and one BriefBar
    /// can't see leaves it unfinished: a story's new pull requests show with it, though its own for the story merged.
    @Test func anUnfinishedOrderClaimsTheStoriesOfItsMergedPullRequestsToo() throws {
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [
            .init(link: OrderPlansTests.link(4101)), .init(link: OrderPlansTests.link(4102), after: ["4101"]),
        ]), now: t(0), newID: planID)
        let new = [Self.ado(4105, [Self.task(5104, rank: 3)]), Self.ado(4106, [Self.task(5105, rank: 4)])]
        // !4101, for the story, merged and still listed; !4102 isn't listed, and BriefBar never saw it merge.
        var missions = Self.missions(Self.facts([Self.ado(4101, [Self.task(5102, rank: 1)], state: .merged)] + new), orders)
        #expect(missions.map(\.key) == [.plan(planID)])
        #expect(missions.first?.isFinished == false)
        #expect(missions.first?.sameStory.map(\.ref) == [Self.pr(4105), Self.pr(4106)])

        // !4102 open, for another story.
        missions = Self.missions(Self.facts([
            Self.ado(4101, [Self.task(5102, rank: 1)], state: .merged), Self.ado(4102, [Self.task(5131, rank: 1, of: 5130)]),
        ] + new), orders)
        #expect(missions.map(\.key) == [.plan(planID)])
        #expect(missions.first?.sameStory.map(\.ref) == [Self.pr(4105), Self.pr(4106)])
    }

    @Test func stackedOnesKeepTheirOrderAndComeFirstThenTheRestAndStacksNeverSplit() throws {
        let missions = Self.missions(Self.facts([
            Self.ado(4101, [Self.task(5102, rank: 1)]),
            // A stack: !4111 targets !4110's branch. Only !4110 is for the story; !4111 goes with it all the same.
            Self.ado(4110, [Self.task(5104, rank: 3)], from: "users/robin/totals"),
            Self.ado(4111, [], from: "users/robin/totals-ui", into: "users/robin/totals"),
            Self.ado(4102, [Self.task(5103, rank: 2)]),
        ]))
        #expect(missions.map(\.key) == [.story(Self.item(5101))])
        let mission = try #require(missions.first)
        #expect(OrderBoardTests.summary(mission.steps) == [
            "1 !4110 Next to merge", "2 !4111 Merge after !4110", "– !4101 ", "– !4102 ",
        ])
        #expect(OrderText.capsule(mission.steps[1]) == "After !4110 · stacked")
        #expect(mission.steps[1].comesRightAfter(Self.pr(4110)))
        #expect(mission.steps[2...].allSatisfy { $0.standing == .unordered })
        // Some have an order: its graph shows, for them, and its help says their rows say so; its header shows no progress,
        // as nothing told BriefBar the story's go together in an order.
        #expect(mission.hasOrder && !mission.showsProgress)
        #expect(OrderText.storyHelp(mission, title: "Checkout redesign")
            == "Its story: ‘Checkout redesign’. Listed in the order of its tasks in the backlog. Those with an order say so on their rows.")
    }

    /// An order's header shows how far it got though nothing in it waits for another, also once they all merged; and so
    /// does a mission of your own with no order known. A story's and a session's pull requests' don't.
    @Test func anOrderShowsItsProgressThoughItsPullRequestsMergeAnyTime() throws {
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [
            .init(link: OrderPlansTests.link(4101)), .init(link: OrderPlansTests.link(4102)),
        ]), now: t(0), newID: planID)
        let merged = Self.missions(Self.facts([Self.ado(4101, [], state: .merged), Self.ado(4102, [], state: .merged)]), orders)
        let order = try #require(merged.first { $0.key == .plan(planID) })
        #expect(!order.hasOrder && order.showsProgress)
        let mine = MissionKey.mine(UUID(uuidString: "44444444-5555-4666-8777-888888888888")!)
        let yours = Self.missions(Self.facts([Self.ado(4103, []), Self.ado(4104, [])]), changes: OrderChanges([
            OrderChange(ref: Self.pr(4103), placement: .into(mine), changedAt: t(10)),
            OrderChange(ref: Self.pr(4104), placement: .into(mine), changedAt: t(11)),
        ]))
        let own = try #require(yours.first { $0.key == mine })
        #expect(!own.hasOrder && own.showsProgress)
        let story = try #require(Self.missions(Self.facts([
            Self.ado(4105, [Self.task(5103, rank: 1)]), Self.ado(4106, [Self.task(5102, rank: 2)]),
        ])).first)
        #expect(story.isStory && !story.showsProgress)
    }

    @Test func twoStacksForAStoryGoInItsTasksOrderEachInItsOwn() throws {
        let missions = Self.missions(Self.facts([
            Self.ado(4120, [Self.task(5104, rank: 3)], from: "users/robin/later"),
            Self.ado(4121, [], from: "users/robin/later-ui", into: "users/robin/later"),
            Self.ado(4110, [Self.task(5102, rank: 1)], from: "users/robin/first"),
            Self.ado(4111, [], from: "users/robin/first-ui", into: "users/robin/first"),
        ]))
        let mission = try #require(missions.first)
        #expect(missions.count == 1)
        #expect(OrderBoardTests.summary(mission.steps) == [
            "1 !4110 Next to merge", "2 !4111 Merge after !4110", "3 !4120 Next to merge", "4 !4121 Merge after !4120",
        ])
    }

    @Test func aStackWithOneOrdersPullRequestsShowsWithItOverItsStory() throws {
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [.init(link: OrderPlansTests.link(4101))]), now: t(0), newID: planID)
        let missions = Self.missions(Self.facts([
            Self.ado(4101, [], from: "users/robin/rounding"),
            Self.ado(4102, [Self.task(5102, rank: 1)], from: "users/robin/cart", into: "users/robin/rounding"),
            Self.ado(4103, [Self.task(5103, rank: 2)]),
        ]), orders)
        #expect(missions.map(\.key) == [.plan(planID)])
        #expect(missions[0].attached.map(\.ref) == [Self.pr(4102)])
        #expect(missions[0].attached[0].standing == .notInOrder)
        // The story's other pull request is alone, and goes as it would.
        #expect(missions[0].sameStory.isEmpty)
    }

    @Test func underTwoStoriesItGoesWithTheOneMoreOfItsGroupIsForThenTheFirstTaskThenTheLowerID() throws {
        // !4101 is for 5101 and 5120; the stack !4101 → !4102 has two pull requests for 5101: 5101 wins.
        var missions = Self.missions(Self.facts([
            Self.ado(4101, [Self.task(5102, rank: 9), Self.task(5122, rank: 1, of: 5120)], from: "users/robin/a"),
            Self.ado(4102, [Self.task(5103, rank: 9)], from: "users/robin/b", into: "users/robin/a"),
            Self.ado(4130, [Self.task(5123, rank: 2, of: 5120)]),
        ]))
        #expect(missions.map(\.key) == [.story(Self.item(5101))])
        let first = try #require(missions.first?.steps.first)
        #expect(first.notes.contains(.alsoFor(MissionStory(ref: Self.item(5120), type: "User Story"))))
        #expect(OrderText.note(.alsoFor(MissionStory(ref: Self.item(5120), type: "User Story")), of: first.ref) == "Also for User Story 5120")
        #expect(OrderText.note(.alsoFor(MissionStory(ref: Self.item(5120))), of: first.ref) == "Also for Work Item 5120")
        #expect(OrderText.sentence(of: first)?.contains("Also for User Story 5120") == true)

        // As many for each: the one whose task comes first in the backlog.
        missions = Self.missions(Self.facts([
            Self.ado(4101, [Self.task(5102, rank: 9), Self.task(5122, rank: 1, of: 5120)]),
            Self.ado(4130, [Self.task(5123, rank: 2, of: 5120)]),
            Self.ado(4140, [Self.task(5103, rank: 3)]),
        ]))
        #expect(missions.map(\.key) == [.story(Self.item(5120))])
        #expect(missions[0].steps.map(\.ref) == [Self.pr(4101), Self.pr(4130)])

        // Neither ranked: the lower ID.
        missions = Self.missions(Self.facts([
            Self.ado(4101, [Self.task(5122, rank: nil, of: 5120), Self.task(5102, rank: nil)]),
            Self.ado(4130, [Self.task(5123, rank: nil, of: 5120)]),
            Self.ado(4140, [Self.task(5103, rank: nil)]),
        ]))
        #expect(missions.map(\.key) == [.story(Self.item(5101))])
    }

    /// An order's mission whose pull requests are all for one story names it: each of them, and each stacked with them,
    /// says what other stories it's for.
    @Test func anOrdersMissionForOneStorySaysWhatElseEachOfItsPullRequestsIsFor() throws {
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [
            .init(link: OrderPlansTests.link(4101)), .init(link: OrderPlansTests.link(4102), after: ["4101"]),
        ]), now: t(0), newID: planID)
        let missions = Self.missions(Self.facts([
            Self.ado(4101, [Self.task(5102, rank: 1), Self.task(5122, rank: 1, of: 5120)]),
            Self.ado(4102, [Self.task(5103, rank: 2)], from: "users/robin/b"),
            // Stacked on !4102, and not in the order.
            Self.ado(
                4103, [Self.task(5104, rank: 3), Self.task(5131, rank: 1, of: 5130, type: nil)], from: "users/robin/c",
                into: "users/robin/b"
            ),
        ]), orders)
        #expect(missions.map(\.key) == [.plan(planID)])
        let mission = try #require(missions.first)
        #expect(mission.story == MissionStory(ref: Self.item(5101), type: "User Story"))
        let alsoFor = { (step: OrderStep) -> [OrderNote] in
            step.notes.filter {
                guard case .alsoFor = $0 else { return false }
                return true
            }
        }
        #expect(alsoFor(mission.steps[0]) == [.alsoFor(MissionStory(ref: Self.item(5120), type: "User Story"))])
        #expect(alsoFor(mission.steps[1]).isEmpty)
        #expect(mission.attached.map(\.ref) == [Self.pr(4103)])
        #expect(alsoFor(mission.attached[0]) == [.alsoFor(MissionStory(ref: Self.item(5130)))])
        #expect(OrderText.sentence(of: mission.steps[0])?.contains("Also for User Story 5120") == true)
    }

    @Test func storiesChangeNothingWhileShowLinksReadsNone() throws {
        let coordinator = ItemRef.session("00000000-0000-4000-8000-000000000002")!
        let sessions = [OrderSession(ref: coordinator, pullRequests: [Self.pr(4101), Self.pr(4102), Self.pr(4110)])]
        var pullRequests = [
            Self.ado(4101, nil), Self.ado(4102, nil),
            Self.ado(4110, nil, from: "users/robin/a"), Self.ado(4111, nil, from: "users/robin/b", into: "users/robin/a"),
        ]
        let without = Self.missions(OrderFacts(pullRequests: pullRequests, sessions: sessions))
        #expect(Set(without.map(\.key)) == [.family(coordinator), .chain(Self.pr(4110))])
        // Read, but for no story: the same.
        for index in pullRequests.indices { pullRequests[index].stories = [] }
        #expect(Self.missions(Self.facts(pullRequests, sessions: sessions)) == without)
    }

    /// `isEarlier` stays as it is: it names a chain's mission, and sorts attached pull requests, stacks, chains and families
    /// the same with stories as without.
    @Test func chainsStacksAndFamiliesSortAsTheyDidWithStoriesElsewhere() throws {
        let coordinator = ItemRef.session("00000000-0000-4000-8000-000000000002")!
        let sessions = [OrderSession(ref: coordinator, pullRequests: [Self.pr(4141), Self.pr(4140)])]
        let base = [
            Self.ado(4111, nil, from: "users/robin/b", into: "users/robin/a"), Self.ado(4110, nil, from: "users/robin/a"),
            Self.ado(4141, nil), Self.ado(4140, nil),
        ]
        let stories = [Self.ado(4201, [Self.task(5102, rank: 2)]), Self.ado(4202, [Self.task(5103, rank: 1)])]
        let without = Self.missions(Self.facts(base, sessions: sessions))
        let with = Self.missions(Self.facts(base + stories, sessions: sessions)).filter { !$0.isStory }
        #expect(with == without)
        #expect(with.first { $0.key == .chain(Self.pr(4110)) }?.steps.map(\.ref) == [Self.pr(4110), Self.pr(4111)])
        #expect(with.first { $0.isFamily }?.steps.map(\.ref) == [Self.pr(4140), Self.pr(4141)])
    }

    // MARK: Following a mission

    @Test func focusFollowsPullRequestsToTheirStorysMissionAndAChainsEarliestOneLeaving() throws {
        let coordinator = ItemRef.session("00000000-0000-4000-8000-000000000002")!
        let sessions = [OrderSession(ref: coordinator, pullRequests: [Self.pr(4101), Self.pr(4102)])]
        let before = Self.missions(Self.facts([Self.ado(4101, nil), Self.ado(4102, nil)], sessions: sessions))
        #expect(before.map(\.key) == [.family(coordinator)])
        // Show Links read their work items: both are for 5101.
        let after = Self.missions(Self.facts([
            Self.ado(4101, [Self.task(5102, rank: 1)]), Self.ado(4102, [Self.task(5103, rank: 2)]),
        ], sessions: sessions))
        #expect(after.map(\.key) == [.story(Self.item(5101))])
        #expect(OrderBoard.successor(of: .family(coordinator), from: before, to: after) == .story(Self.item(5101)))
        // Only one of them went: it waits.
        let split = Self.missions(Self.facts([
            Self.ado(4101, [Self.task(5102, rank: 1)]), Self.ado(4102, []), Self.ado(4103, [Self.task(5103, rank: 2)]),
        ], sessions: sessions))
        #expect(OrderBoard.successor(of: .family(coordinator), from: before, to: split) == nil)
        // Still there: nothing to follow.
        #expect(OrderBoard.successor(of: .story(Self.item(5101)), from: after, to: after) == nil)

        // A chain whose earliest pull request merged and left the lists.
        let chain = Self.missions(Self.facts([
            Self.ado(4110, [], from: "users/robin/a", state: .merged), Self.ado(4111, [], from: "users/robin/b", into: "users/robin/a"),
            Self.ado(4112, [], from: "users/robin/c", into: "users/robin/b"),
        ]))
        #expect(chain.map(\.key) == [.chain(Self.pr(4110))])
        let moved = Self.missions(Self.facts([
            Self.ado(4111, [], from: "users/robin/b", into: "users/robin/a"), Self.ado(4112, [], from: "users/robin/c", into: "users/robin/b"),
        ]))
        #expect(moved.map(\.key) == [.chain(Self.pr(4111))])
        #expect(OrderBoard.successor(of: .chain(Self.pr(4110)), from: chain, to: moved) == .chain(Self.pr(4111)))
        // A family whose pull requests went to a chain: it waits, as today.
        let stacked = Self.missions(Self.facts([
            Self.ado(4101, [], from: "users/robin/a"), Self.ado(4102, [], from: "users/robin/b", into: "users/robin/a"),
        ], sessions: sessions))
        #expect(OrderBoard.successor(of: .family(coordinator), from: before, to: stacked) == nil)

        // A chain whose earliest you moved out to a mission of your own, still open: it goes on by the next, and what was
        // kept by it follows there, not after the one you moved.
        let mine = MissionKey.mine(UUID(uuidString: "44444444-5555-4666-8777-888888888888")!)
        let open = [
            Self.ado(4110, [], from: "users/robin/a"), Self.ado(4111, [], from: "users/robin/b", into: "users/robin/a"),
            Self.ado(4112, [], from: "users/robin/c", into: "users/robin/b"),
        ]
        let whole = Self.missions(Self.facts(open))
        #expect(whole.map(\.key) == [.chain(Self.pr(4110))])
        let out = OrderChanges([OrderChange(ref: Self.pr(4110), placement: .into(mine), from: .chain(Self.pr(4111)), changedAt: t(10))])
        let left = Self.missions(Self.facts(open), changes: out)
        #expect(Set(left.map(\.key)) == [.chain(Self.pr(4111)), mine])
        #expect(OrderBoard.successor(of: .chain(Self.pr(4110)), from: whole, to: left, moved: [Self.pr(4110)]) == .chain(Self.pr(4111)))
        #expect(OrderBoard.successor(of: .chain(Self.pr(4110)), from: whole, to: left) == nil)
        // A mission of your own never moves: it's kept by its ID.
        #expect(OrderBoard.successor(of: mine, from: left, to: whole) == nil)
    }

    /// Your changes that name a session's pull requests' mission follow them to their story's, as Focus does: where you put
    /// one, and which you set as next there. The one you put with them goes along, rather than stay in a mission that's
    /// gone, and doesn't count for where the session's went.
    @Test func yourChangesFollowASessionsPullRequestsToTheirStory() throws {
        let coordinator = ItemRef.session("00000000-0000-4000-8000-000000000002")!
        let sessions = [OrderSession(ref: coordinator, pullRequests: [Self.pr(4101), Self.pr(4102)])]
        let (family, story) = (MissionKey.family(coordinator), MissionKey.story(Self.item(5101)))
        var changes = OrderChanges([
            OrderChange(ref: Self.pr(4103), placement: .into(family), changedAt: t(10)),
            OrderChange(ref: Self.pr(4102), first: family, changedAt: t(20)),
        ])
        let before = Self.missions(Self.facts([Self.ado(4101, nil), Self.ado(4102, nil), Self.ado(4103, nil)], sessions: sessions), changes: changes)
        #expect(before.map(\.key) == [family])
        // Show Links read their work items: the session's are for 5101, !4103 for none.
        let read = Self.facts([Self.ado(4101, [Self.task(5102, rank: 1)]), Self.ado(4102, [Self.task(5103, rank: 2)]), Self.ado(4103, [])], sessions: sessions)
        let after = Self.missions(read, changes: changes)
        // What you put there waits alone where it was, as if gone; the session's went to their story's.
        #expect(Set(after.map(\.key)) == [story, family])
        #expect(after.first { $0.key == family }?.isMine == true)
        let successor = { (key: MissionKey) in OrderBoard.successor(of: key, from: before, to: after, moved: [Self.pr(4103)]) }
        #expect(successor(family) == story)
        #expect(OrderBoard.successor(of: family, from: before, to: after) == nil)

        #expect(changes.followMissions(successor) == [family: story])
        #expect(changes[Self.pr(4103)]?.placement == .into(story) && changes[Self.pr(4102)]?.first == story)
        let followed = Self.missions(read, changes: changes)
        #expect(followed.map(\.key) == [story])
        let mission = try #require(followed.first)
        #expect(mission.steps.map(\.ref).contains(Self.pr(4103)))
        #expect(mission.steps.first { $0.ref == Self.pr(4102) }?.standing == .next)
    }

    /// Moving one of a story's pull requests into an order moves only that one: the order doesn't claim the story for it,
    /// and the story's others stay its mission.
    @Test func movingAStorysPullRequestIntoAnOrderLeavesItsOthersTheStorysMission() throws {
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [
            .init(link: OrderPlansTests.link(4110)), .init(link: OrderPlansTests.link(4111), after: ["4110"]),
        ]), now: t(0), newID: planID)
        let facts = Self.facts([
            Self.ado(4110, []), Self.ado(4111, []), Self.ado(4101, [Self.task(5102, rank: 1)]),
            Self.ado(4102, [Self.task(5103, rank: 2)]), Self.ado(4103, [Self.task(5104, rank: 3)]),
        ])
        let story = MissionKey.story(Self.item(5101))
        #expect(Set(Self.missions(facts, orders).map(\.key)) == [.plan(planID), story])
        let changes = OrderChanges([
            OrderChange(ref: Self.pr(4101), placement: .into(.plan(planID)), from: story, changedAt: t(10)),
        ])
        let missions = Self.missions(facts, orders, changes: changes)
        #expect(try #require(missions.first { $0.key == story }).steps.map(\.ref) == [Self.pr(4102), Self.pr(4103)])
        let order = try #require(missions.first { $0.key == .plan(planID) })
        #expect(order.steps.map(\.ref).contains(Self.pr(4101)) && order.sameStory.isEmpty)
    }

    /// One you put in a story's mission waits with the others you put there while BriefBar can't read stories, as before
    /// Show Links has: its mission isn't gone, only unseen. Once it reads them and no pull request is for that story, it's
    /// gone.
    @Test func oneYouPutInAStorysMissionWaitsUnseenWhileStoriesArentRead() throws {
        let story = MissionKey.story(Self.item(5101))
        let changes = OrderChanges([OrderChange(ref: Self.pr(4110), placement: .into(story), changedAt: t(10))])
        let unread = OrderFacts(pullRequests: [Self.ado(4110, nil), Self.ado(4101, nil), Self.ado(4102, nil)])
        let waiting = try #require(Self.missions(unread, changes: changes).first { $0.key == story })
        let step = try #require(waiting.steps.first)
        #expect(waiting.isMine && step.notes.contains(.placementUnseen(story)) && !step.notes.contains(.placementGone(story)))
        #expect(OrderText.note(.placementUnseen(story), of: step.ref) == "You put it in a story's mission, which shows once Show Links reads the story")
        // Read, with no pull request for the story anymore: gone.
        let read = Self.facts([Self.ado(4110, []), Self.ado(4101, []), Self.ado(4102, [])])
        let gone = try #require(Self.missions(read, changes: changes).first { $0.key == story }?.steps.first)
        #expect(gone.notes.contains(.placementGone(story)))
    }

    /// Move to Mission from one an order lists apart, for its story, into that order: it goes in it, rather than count as
    /// in it already.
    @Test func movingOneAnOrderListsApartForItsStoryIntoThatOrderPutsItThere() throws {
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [
            .init(link: OrderPlansTests.link(4101)), .init(link: OrderPlansTests.link(4102), after: ["4101"]),
        ]), now: t(0), newID: planID)
        let facts = Self.facts([
            Self.ado(4101, [Self.task(5102, rank: 1)]), Self.ado(4102, [Self.task(5103, rank: 2)]), Self.ado(4105, [Self.task(5104, rank: 3)]),
        ])
        let missions = Self.missions(facts, orders)
        #expect(missions.first?.sameStory.map(\.ref) == [Self.pr(4105)])
        var changes = OrderChanges()
        let touched = try changes.apply(.move([Self.pr(4105)], to: .into(.plan(planID)), from: nil), missions: missions, orders: orders, now: t(60))
        #expect(touched.keys.contains(Self.pr(4105)))
        let order = try #require(Self.missions(facts, orders, changes: changes).first)
        #expect(order.key == .plan(planID) && order.steps.map(\.ref).contains(Self.pr(4105)) && order.sameStory.isEmpty)
    }

    @Test func anOrderNeverMovesItsKeptByItsID() throws {
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [
            .init(link: OrderPlansTests.link(4101)), .init(link: OrderPlansTests.link(4102), after: ["4101"]),
        ]), now: t(0), newID: planID)
        let facts = Self.facts([Self.ado(4101, [Self.task(5102, rank: 1)]), Self.ado(4102, [Self.task(5103, rank: 2)])])
        let before = Self.missions(facts, orders)
        // Forgotten, its pull requests are their story's mission: what was kept by it doesn't go there.
        let after = Self.missions(facts)
        #expect(after.map(\.key) == [.story(Self.item(5101))])
        #expect(OrderBoard.successor(of: .plan(planID), from: before, to: after) == nil)
    }

    @Test func aStorysKeyIsKeptAsAReferenceAndGoesWithAzureDevOps() {
        let key = MissionKey.story(Self.item(5101))
        #expect(key.description == "story/workItem/contoso/5101")
        #expect(MissionKey("story/workItem/contoso/5101") == key)
        #expect(MissionKey("story/pullRequest/contoso/4101") == nil)
        #expect(MissionKey("story/workItem/contoso/x") == nil)
        #expect(key.kinds == [.workItem])
        #expect(OrderFocus.kept(key, in: DeclaredOrders()) == key)
        #expect(OrderFocus.kept(key, in: DeclaredOrders(), forgetting: [.workItem, .pullRequest]) == nil)
        #expect(OrderFocus.kept(key, in: DeclaredOrders(), forgetting: [.session]) == key)
        // The others, as before.
        let chain = MissionKey.chain(Self.pr(4101))
        #expect(OrderFocus.kept(chain, in: DeclaredOrders(), forgetting: [.gitHubPullRequest]) == chain)
        #expect(OrderFocus.kept(chain, in: DeclaredOrders(), forgetting: [.workItem, .pullRequest]) == nil)
        #expect(OrderFocus.kept(.stack(repository: "octo/storefront", number: 41), in: DeclaredOrders(), forgetting: [.gitHubPullRequest]) == nil)
    }

    @Test func aStorysUnorderedPullRequestShowsItsMissionFromAnotherList() throws {
        let missions = Self.missions(Self.facts([
            Self.ado(4101, [Self.task(5102, rank: 1)]), Self.ado(4102, [Self.task(5103, rank: 2)]),
        ]))
        let found = try #require(OrderBoard.step(for: Self.pr(4102), in: missions))
        #expect(found.mission.key == .story(Self.item(5101)))
        #expect(OrderText.capsule(found.step) == nil)
    }
}
