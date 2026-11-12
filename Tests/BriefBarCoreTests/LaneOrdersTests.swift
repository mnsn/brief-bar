import Foundation
import Testing
@testable import BriefBarCore

/// Your order on My Work's Board: in each lane, To start's and In progress's cards as you put them, one order across both.
@Suite struct LaneOrdersTests {
    private typealias Steps = NextStepsTests

    private static let story = Steps.task(5001)

    /// A lane for story 5001's mission: its draft !4101 in In progress, with the Board's own order, and its work.
    private static func board(
        _ work: [SprintWork], orders: LaneOrders = LaneOrders(), picks: UpNextPicks = UpNextPicks(), startPick: ItemRef? = nil,
        stages: [Int: StageReading] = [4101: Steps.reading(.inProgress, .draft, at: 1)]
    ) -> PullRequestBoard {
        var checkout = Steps.mission([Steps.step(4101, .next)] + stages.keys.filter { $0 != 4101 }.sorted().map { Steps.step($0) })
        checkout.story = MissionStory(ref: story)
        return Steps.board(stages, missions: [checkout], picks: picks).withWork(
            work, missions: [checkout], stories: [story], startPick: startPick, yourOrder: orders
        )
    }

    private static func refs(_ lane: BoardLane, _ column: BoardColumn) -> [String] {
        lane.items(in: column).map(\.ref.shortOrderLabel)
    }

    private static let work = [
        Steps.work(5103, .inProgress, story: 5001), Steps.work(5104, .toDo, story: 5001), Steps.work(5105, .toDo, story: 5001),
        Steps.work(5108, .toDo, story: 5001),
    ]

    /// The first move puts the lane's cards in your order as they show, In progress's first, and only swaps places within its
    /// column: the other column's keep theirs, and so does what Show doesn't show now. At the ends, nothing moves.
    @Test func aMoveSwapsPlacesWithinItsColumnOnly() throws {
        let lane = try #require(Self.board(Self.work).lanes.first)
        #expect(lane.orderKey == .story(Self.story))
        #expect(lane.yourOrder == nil)
        #expect(Self.refs(lane, .stage(.inProgress)) == ["!4101", "5103"])
        #expect(Self.refs(lane, .toStart) == ["5104", "5105", "5108"])

        let moved = try #require(lane.moving(Steps.task(5108), .toTop))
        #expect(moved.order.map(\.shortOrderLabel) == ["!4101", "5103", "5108", "5104", "5105"])
        #expect(moved.place == LanePlace(position: 1, count: 3))
        #expect(lane.moving(Steps.task(5104), .up) == nil)
        #expect(lane.moving(Steps.task(5108), .down) == nil)
        #expect(lane.moving(Steps.task(5104), .toTop) == nil)
        #expect(lane.moving(Steps.pr(4101), .down)?.order.map(\.shortOrderLabel) == ["5103", "!4101", "5104", "5105", "5108"])
        // A drop's place, at either end too.
        #expect(lane.moving(Steps.task(5104), .to(1))?.order.map(\.shortOrderLabel) == ["!4101", "5103", "5105", "5104", "5108"])
        #expect(lane.moving(Steps.task(5104), .to(9))?.place == LanePlace(position: 3, count: 3))

        let ordered = try #require(Self.board(Self.work, orders: LaneOrders([(.story(Self.story), moved.order)])).lanes.first)
        #expect(Self.refs(ordered, .toStart) == ["5108", "5104", "5105"])
        #expect(Self.refs(ordered, .stage(.inProgress)) == ["!4101", "5103"])

        // Work Show doesn't show keeps its place among the rest: 5052 stays between them.
        let kept = [Steps.task(5104), Steps.task(5052), Steps.task(5105)]
        #expect(LaneOrders.moving(
            Steps.task(5105), .toTop, column: [Steps.task(5104), Steps.task(5105)], shown: [Steps.task(5104), Steps.task(5105)],
            kept: kept
        ) == [Steps.task(5105), Steps.task(5052), Steps.task(5104)])
    }

    /// A task that starts keeps its place, after what you started before it, and moving it in In progress leaves To start as
    /// it was; work that comes later goes to the bottom of its column until you move it, and done work leaves the order.
    @Test func aTaskKeepsItsPlaceAsItStartsAndNewWorkGoesToTheBottom() throws {
        let order = [Steps.pr(4101), Steps.task(5103), Steps.task(5108), Steps.task(5104), Steps.task(5105)]
        let orders = LaneOrders([(.story(Self.story), order)])
        var started = Self.work
        started[1] = Steps.work(5104, .inProgress, story: 5001)
        let lane = try #require(Self.board(started, orders: orders).lanes.first)
        #expect(Self.refs(lane, .stage(.inProgress)) == ["!4101", "5103", "5104"])
        #expect(Self.refs(lane, .toStart) == ["5108", "5105"])
        let top = try #require(lane.moving(Steps.task(5104), .toTop))
        #expect(top.order.map(\.shortOrderLabel) == ["5104", "!4101", "5108", "5103", "5105"])

        // 5109 comes into the sprint, ahead of the rest in its backlog: the bottom of To start, till you move it. 5103 resolved:
        // the next move drops it.
        let later = [Steps.work(5109, .toDo, story: 5001), Steps.work(5103, .resolved, story: 5001)] + Self.work.dropFirst()
        let newer = try #require(Self.board(later, orders: orders).lanes.first)
        #expect(Self.refs(newer, .toStart) == ["5108", "5104", "5105", "5109"])
        let up = try #require(newer.moving(Steps.task(5109), .up))
        #expect(up.order.map(\.shortOrderLabel) == ["!4101", "5108", "5104", "5109", "5105"])
    }

    /// Start next follows each lane's order in the places its work holds in the backlog: between lanes, the backlog's order
    /// still decides. Where your order has it, the one you chose for it stays where your order puts it, and so does Fix
    /// next's in In progress; where it doesn't, each still comes first of the rest, as before.
    @Test func startNextFollowsEachLanesOrderAndPicksStayInTheirPlaces() throws {
        let work = [
            Steps.work(5104, .toDo, story: 5001), Steps.work(5150, .toDo), Steps.work(5105, .toDo, story: 5001),
            Steps.work(5108, .toDo, story: 5001),
        ]
        let orders = LaneOrders([(.story(Self.story), [Steps.task(5108), Steps.task(5104), Steps.task(5105)])])
        let ordered = Self.board(work, orders: orders)
        #expect(ordered.startNext?.tasks.map(\.ref.shortOrderLabel) == ["5108", "5150", "5104", "5105"])
        #expect(Self.board(work).startNext?.tasks.map(\.ref.shortOrderLabel) == ["5104", "5150", "5105", "5108"])

        // A later sprint's work still comes last, wherever you put it: it takes no place of the rest's, which keep theirs.
        var nextSprint = Steps.work(5190, .toDo, story: 5001)
        nextSprint.laterSprint = "Shop\\Sprint 43"
        let first = LaneOrders([(.story(Self.story), [Steps.task(5190), Steps.task(5108), Steps.task(5104), Steps.task(5105)])])
        let later = Self.board(work + [nextSprint], orders: first)
        #expect(later.startNext?.tasks.map(\.ref.shortOrderLabel) == ["5108", "5150", "5104", "5105", "5190"])
        #expect(Self.refs(try #require(later.lanes.first), .toStart) == ["5190", "5108", "5104", "5105"])

        let picked = Self.board(work, orders: orders, startPick: Steps.task(5105))
        #expect(picked.startNext?.task.ref == Steps.task(5105))
        #expect(picked.startNext?.isPicked == true)
        #expect(Self.refs(try #require(picked.lanes.first), .toStart) == ["5108", "5104", "5105"])
        let unordered = Self.board(work, startPick: Steps.task(5105))
        #expect(Self.refs(try #require(unordered.lanes.first), .toStart) == ["5105", "5104", "5108"])
        // An order that doesn't have the lane's work yet, as one made while To start showed none: there it comes first too.
        let inProgressOnly = Self.board(work, orders: LaneOrders([(.story(Self.story), [Steps.pr(4101)])]), startPick: Steps.task(5105))
        #expect(Self.refs(try #require(inProgressOnly.lanes.first), .toStart) == ["5105", "5104", "5108"])
        // With work your order has and work that came since, the one you chose of that work comes first of it, under the work
        // your order has: your order still beats it.
        let since = work + [Steps.work(5109, .toDo, story: 5001)]
        let mixed = LaneOrders([(.story(Self.story), [Steps.task(5108), Steps.task(5104)])])
        #expect(Self.refs(try #require(Self.board(since, orders: mixed).lanes.first), .toStart) == ["5108", "5104", "5105", "5109"])
        let newPick = Self.board(since, orders: mixed, startPick: Steps.task(5109))
        #expect(Self.refs(try #require(newPick.lanes.first), .toStart) == ["5108", "5104", "5109", "5105"])

        let stages: [Int: StageReading] = [
            4101: Steps.reading(.inProgress, .draft, at: 1), 4102: Steps.reading(.inProgress, .failing("Build failed"), at: 2),
        ]
        let fix = UpNextPicks([.fix: Steps.pr(4102)])
        let inProgress = LaneOrders([(.story(Self.story), [Steps.pr(4101), Steps.pr(4102)])])
        let fixing = Self.board([], orders: inProgress, picks: fix, stages: stages)
        #expect(fixing.next[.fix] == Steps.pr(4102))
        #expect(Self.refs(try #require(fixing.lanes.first), .stage(.inProgress)) == ["!4101", "!4102"])
        #expect(Self.refs(try #require(Self.board([], picks: fix, stages: stages).lanes.first), .stage(.inProgress)) == ["!4102", "!4101"])
        // So does Fix next's: of the pull requests your order doesn't have yet, it comes first, under !4101, which it has.
        let failing = stages.merging([4103: Steps.reading(.inProgress, .failing("Build failed"), at: 3)]) { $1 }
        let newFix = Self.board(
            [], orders: LaneOrders([(.story(Self.story), [Steps.pr(4101)])]), picks: UpNextPicks([.fix: Steps.pr(4103)]), stages: failing
        )
        #expect(newFix.next[.fix] == Steps.pr(4103))
        #expect(Self.refs(try #require(newFix.lanes.first), .stage(.inProgress)) == ["!4101", "!4103", "!4102"])
    }

    /// Past `mostCards`, what a lane doesn't show goes, from the bottom, what you'd do last first; what it shows all stays,
    /// however many, the card you moved too.
    @Test func theCapNeverDropsWhatALaneShows() throws {
        let many = (1...(LaneOrders.mostCards + 30)).map { Steps.task(6000 + $0) }
        let last = try #require(many.last)
        let moved = try #require(LaneOrders.moving(last, .toTop, column: many, shown: many, kept: [Steps.task(5901)] + many))
        #expect(moved.count == many.count && moved.first == last)
        var orders = LaneOrders()
        orders.set(moved, for: .all)
        #expect(orders[.all] == moved)

        let few = Array(many.prefix(LaneOrders.mostCards - 1))
        let trimmed = try #require(
            LaneOrders.moving(few[1], .up, column: few, shown: few, kept: [Steps.task(5901)] + few + [Steps.task(5902)])
        )
        #expect(trimmed.count == LaneOrders.mostCards)
        #expect(trimmed.contains(Steps.task(5901)) && !trimmed.contains(Steps.task(5902)))
    }

    /// A story's lane and the lane of a mission for that story have one order, so that its work keeps your order as its
    /// first pull request makes it a mission; what the preferences keep names the organization, and reads back the same.
    @Test func aStorysOrderGoesOnInItsMissionsLaneAndReadsBack() {
        var plan = Steps.mission([Steps.step(4101)])
        plan.key = .plan(UUID(uuidString: "6F0C1D2E-3A4B-4C5D-8E6F-7A8B9C0D1E2F")!)
        plan.story = MissionStory(ref: Self.story)
        #expect(LaneOrderKey(.mission(plan.key), missions: [plan]) == .story(Self.story))
        #expect(LaneOrderKey(.mission(.story(Self.story)), missions: []) == .story(Self.story))
        #expect(LaneOrderKey(.story(Self.story), missions: []) == .story(Self.story))
        #expect(LaneOrderKey(.mission(plan.key), missions: []) == .mission(plan.key))
        let keys: [LaneOrderKey] = [.story(Self.story), .mission(plan.key), .notInAMission, .all]
        #expect(keys.map(\.description) == [
            "story/workItem/contoso/5001", "mission/plan/6f0c1d2e-3a4b-4c5d-8e6f-7a8b9c0d1e2f", "none", "all",
        ])
        #expect(keys.map { LaneOrderKey($0.description) } == keys)
        #expect(LaneOrderKey("mission/story/workItem/contoso/5001") == .story(Self.story))
        #expect(LaneOrderKey("story/pullRequest/contoso/4101") == nil)
        #expect(LaneOrderKey("lane/5001") == nil)

        let defaults = MemorySettings()
        let orders = LaneOrders([(.story(Self.story), [Steps.task(5108), Steps.pr(4101)]), (.notInAMission, [Steps.task(5150)])])
        orders.save(to: defaults)
        let saved = defaults.object(forKey: "order.laneOrders") as? [[String: Any]]
        #expect(saved?.map { $0["lane"] as? String } == ["story/workItem/contoso/5001", "none"])
        #expect(saved?.map { $0["refs"] as? [String] } == [["workItem/contoso/5108", "pullRequest/contoso/4101"], ["workItem/contoso/5150"]])
        #expect(LaneOrders.load(from: defaults) == orders)
        defaults.set([["lane": "lane/5", "refs": ["x"]], ["lane": "none", "refs": ["workItem/contoso/5150", "nothing"]]], forKey: LaneOrders.defaultsKey)
        #expect(LaneOrders.load(from: defaults) == LaneOrders([(.notInAMission, [Steps.task(5150)])]))
        LaneOrders().save(to: defaults)
        #expect(defaults.object(forKey: LaneOrders.defaultsKey) == nil)
    }

    /// It keeps the lanes you changed last, and forgets what's about a source's things as that source goes.
    @Test func keepsTheLanesYouChangedLastAndForgetsASourcesThings() {
        var orders = LaneOrders()
        for id in 1...(LaneOrders.mostLanes + 2) {
            orders.set([Steps.task(5000 + id)], for: .story(Steps.task(id)))
        }
        #expect(orders.keys.count == LaneOrders.mostLanes)
        #expect(orders.keys.first == .story(Steps.task(LaneOrders.mostLanes + 2)))
        #expect(orders[.story(Steps.task(1))] == nil)
        let reset = orders.reset(.story(Steps.task(3)))
        let again = orders.reset(.story(Steps.task(3)))
        #expect(reset && !again)

        var mixed = LaneOrders([
            (.notInAMission, [Steps.task(5150), Steps.gh(12)]), (.story(Self.story), [Steps.task(5104)]),
            (.mission(.chain(Steps.gh(14))), [Steps.gh(14)]),
        ])
        let gitHub = mixed.forget([.gitHubPullRequest])
        #expect(gitHub)
        #expect(mixed == LaneOrders([(.notInAMission, [Steps.task(5150)]), (.story(Self.story), [Steps.task(5104)])]))
        let azureDevOps = mixed.forget([.workItem, .pullRequest])
        let nothing = mixed.forget([.workItem])
        #expect(azureDevOps && !nothing)
        #expect(mixed.isEmpty)
    }
}
