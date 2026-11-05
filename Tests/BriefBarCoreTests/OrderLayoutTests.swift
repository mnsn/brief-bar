import Foundation
import Testing
@testable import BriefBarCore

@Suite struct OrderLayoutTests {
    static func pr(_ number: Int) -> ItemRef { OrderPlansTests.pr(number) }

    static func session(_ number: Int) -> ItemRef {
        ItemRef.session(String(format: "00000000-0000-4000-8000-%012d", number))!
    }

    /// A pull request in a mission, after these, stacked on some of them.
    static func step(
        _ number: Int, after earlier: [Int] = [], stacked: Set<Int> = [], session: ItemRef? = nil, status: OrderStatus = .open
    ) -> OrderStep {
        OrderStep(
            ref: pr(number), status: status,
            standing: earlier.isEmpty ? .next : .waiting(open: earlier.map(pr), unknown: []),
            prerequisites: earlier.map {
                OrderPrerequisite(ref: pr($0), origins: stacked.contains($0) ? [.branch] : [.declared(revision: 1)], status: .open)
            },
            directPrerequisites: earlier.map(pr), session: session
        )
    }

    static func mission(_ steps: [OrderStep]) -> OrderMission {
        OrderMission(
            key: .chain(steps[0].ref), kind: .stack, steps: steps, attached: [], cycles: [], isFocused: false, isFinished: false,
            isStale: false, attention: nil, date: nil, sessions: []
        )
    }

    static func line(_ before: Int, _ after: Int, _ style: OrderLineStyle = .dashed) -> OrderLine {
        OrderLine(edge: OrderEdge(pr(before), pr(after)), style: style)
    }

    // MARK: List's gutter

    @Test func aStackIsOneStraightSolidLane() {
        let gutter = OrderGutter([Self.step(1), Self.step(2, after: [1], stacked: [1]), Self.step(3, after: [2], stacked: [2])])
        let (first, second) = (Self.line(1, 2, .solid), Self.line(2, 3, .solid))
        #expect(gutter.rows.map(\.lane) == [0, 0, 0])
        #expect(gutter.laneCount == 1)
        #expect(gutter.rows.map(\.segments) == [
            [.init(from: .node, to: .bottom(0), line: first)],
            [.init(from: .top(0), to: .node, line: first), .init(from: .node, to: .bottom(0), line: second)],
            [.init(from: .top(0), to: .node, line: second)],
        ])
        #expect(gutter.hidden.isEmpty)
    }

    /// The user's example, with x1 merged and folded: !4102, then !4103 and !4105 after it, !4106 after !4105, and !4104
    /// any time.
    static let userExampleRows = [
        step(4102), step(4103, after: [4102]), step(4105, after: [4102]), step(4106, after: [4105]), step(4104),
    ]

    @Test func aForkTakesTheNextLaneToItsEndAndOneThatGoesAnyTimeHasNoLines() {
        let gutter = OrderGutter(Self.userExampleRows)
        let (toCart, toFlag, toSettings) = (Self.line(4102, 4103), Self.line(4102, 4105), Self.line(4105, 4106))
        #expect(gutter.rows.map(\.lane) == [0, 0, 1, 1, 0])
        #expect(gutter.laneCount == 2)
        #expect(gutter.rows.map(\.segments) == [
            [.init(from: .node, to: .bottom(0), line: toCart), .init(from: .node, to: .bottom(1), line: toFlag)],
            [.init(from: .top(0), to: .node, line: toCart), .init(from: .top(1), to: .bottom(1), line: toFlag)],
            [.init(from: .top(1), to: .node, line: toFlag), .init(from: .node, to: .bottom(1), line: toSettings)],
            [.init(from: .top(1), to: .node, line: toSettings)],
            [],
        ])
    }

    @Test func aJoinComesIntoTheLeftmostOfItsLanesAndALineThatWouldNeedAFourthIsntDrawn() {
        let gutter = OrderGutter([Self.step(1), Self.step(2), Self.step(3), Self.step(4), Self.step(5, after: [1, 2, 3, 4])])
        #expect(gutter.hidden == [Self.line(1, 5)])
        #expect(gutter.rows.map(\.lane) == [0, 0, 1, 2, 0])
        #expect(gutter.laneCount == 3)
        #expect(gutter.rows[4].segments == [
            .init(from: .top(0), to: .node, line: Self.line(2, 5)),
            .init(from: .top(1), to: .node, line: Self.line(3, 5)),
            .init(from: .top(2), to: .node, line: Self.line(4, 5)),
        ])
        #expect(gutter.rows[0].segments.isEmpty)
        // Hidden, it's still said in words, and hovering still finds it.
        #expect(gutter.highlighted(by: Self.pr(1)) == [Self.pr(1), Self.pr(5)])
    }

    @Test func hoveringARowHighlightsWhatGoesBeforeAndAfterIt() {
        let gutter = OrderGutter(Self.userExampleRows)
        #expect(gutter.highlighted(by: Self.pr(4105)) == [Self.pr(4102), Self.pr(4105), Self.pr(4106)])
        #expect(gutter.highlighted(by: Self.pr(4103)) == [Self.pr(4102), Self.pr(4103)])
        #expect(gutter.highlighted(by: Self.pr(4104)) == [Self.pr(4104)])
        #expect(gutter.highlights(Self.line(4105, 4106), hovering: Self.pr(4102)))
        #expect(!gutter.highlights(Self.line(4102, 4103), hovering: Self.pr(4105)))
    }

    @Test func aLineIsSolidWhenStackedAndDashedWhenItOnlyMergesAfter() throws {
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [
            .init(link: OrderPlansTests.link(4101)), .init(link: OrderPlansTests.link(4102), after: ["4101"]),
            .init(link: OrderPlansTests.link(4103), after: ["4102"]),
        ]), now: t(0))
        let facts = OrderFacts(pullRequests: [
            OrderBoardTests.ado(4101, from: "users/robin/rounding"),
            OrderBoardTests.ado(4102, from: "users/robin/cart", into: "users/robin/rounding"),
            OrderBoardTests.ado(4103, from: "users/robin/gift-cards"),
        ])
        let mission = try #require(OrderBoard.missions(facts: facts, orders: orders, evidence: OrderEvidence(), now: t(60)).first)
        #expect(OrderGutter(mission.steps).lines == [Self.line(4101, 4102, .solid), Self.line(4102, 4103, .dashed)])
    }

    // MARK: The Map

    @Test func theMapLaysAMissionOutInMergeWavesWithItsSessionsAsLanes() throws {
        let (cart, flag) = (Self.session(1), Self.session(2))
        var orders = DeclaredOrders()
        try orders.apply(OrderPlansTests.userExample, now: t(0))
        let pullRequests = (4102...4106).map { OrderBoardTests.ado($0, from: "users/robin/part-\($0)") }
            + [OrderBoardTests.ado(4101, from: "users/robin/part-4101", state: .merged)]
        let facts = OrderFacts(pullRequests: pullRequests, sessions: [
            OrderSession(ref: cart, pullRequests: [4101, 4102, 4103].map(Self.pr)),
            OrderSession(ref: flag, pullRequests: [4105, 4106].map(Self.pr)),
        ])
        let mission = try #require(OrderBoard.missions(facts: facts, orders: orders, evidence: OrderEvidence(), now: t(60)).first)
        let map = try #require(OrderMap(mission))
        #expect(map.columns == [.ended, .wave(0), .wave(1), .wave(2)])
        #expect(map.columns.map(OrderText.title(of:)) == ["Merged", "Now", "Then", "Later"])
        #expect(map.lanes == [
            .init(session: cart, row: 0, height: 1), .init(session: flag, row: 1, height: 1), .init(session: nil, row: 2, height: 1),
        ])
        #expect(map.nodes == [
            .init(ref: Self.pr(4101), column: 0, lane: 0, row: 0), .init(ref: Self.pr(4102), column: 1, lane: 0, row: 0),
            .init(ref: Self.pr(4103), column: 2, lane: 0, row: 0), .init(ref: Self.pr(4105), column: 2, lane: 1, row: 1),
            .init(ref: Self.pr(4106), column: 3, lane: 1, row: 1), .init(ref: Self.pr(4104), column: 1, lane: 2, row: 2),
        ])
        #expect(map.lines == [Self.line(4101, 4102), Self.line(4102, 4103), Self.line(4102, 4105), Self.line(4105, 4106)])
        #expect(map.crossings == 0)
    }

    /// One that waits only for a pull request the Map doesn't show, in another mission, goes a wave on, with no line there.
    @Test func oneThatWaitsForAPullRequestInAnotherMissionGoesAWaveOn() throws {
        let map = try #require(OrderMap(Self.mission([Self.step(1), Self.step(2, after: [9], stacked: [9])])))
        #expect(map.columns == [.wave(0), .wave(1)])
        #expect(map.nodes.first { $0.ref == Self.pr(2) }?.column == 1)
        #expect(map.lines.isEmpty)
    }

    @Test func lanesAreSwappedWhileThatCrossesFewerLines() throws {
        let steps = [
            Self.step(1, session: Self.session(1)), Self.step(2, session: Self.session(2)),
            Self.step(3, after: [2], session: Self.session(3)), Self.step(4, after: [1], session: Self.session(4)),
        ]
        // As the sessions first come, the two lines would cross.
        let asTheyCome: [ItemRef: OrderMap.Place] = [
            Self.pr(1): .init(x: 0, y: 0), Self.pr(2): .init(x: 0, y: 1), Self.pr(3): .init(x: 1, y: 2), Self.pr(4): .init(x: 1, y: 3),
        ]
        #expect(OrderMap.crossings([Self.line(2, 3), Self.line(1, 4)], at: asTheyCome) == 1)
        let map = try #require(OrderMap(Self.mission(steps)))
        #expect(map.crossings == 0)
        #expect(map.lanes.map(\.session) == [Self.session(2), Self.session(1), Self.session(3), Self.session(4)])
    }

    @Test func aLanesPullRequestsInAColumnAreOrderedToCrossFewerLines() throws {
        let one = Self.session(1)
        let steps = [
            Self.step(1, session: one), Self.step(2, session: one), Self.step(3, after: [2], session: one),
            Self.step(4, after: [1], session: one),
        ]
        let map = try #require(OrderMap(Self.mission(steps)))
        #expect(map.lanes == [.init(session: one, row: 0, height: 2)])
        #expect(map.nodes.map(\.row) == [1, 0, 0, 1])
        #expect(map.crossings == 0)
    }

    @Test func aMissionTooLargeToDrawClearlyHasNoMap() {
        let steps = (1...31).map { Self.step($0) }
        #expect(OrderMap(Self.mission(steps)) == nil)
        #expect(OrderMap(Self.mission(Array(steps.prefix(30)))) != nil)
        #expect(OrderText.tooManyToDraw(31) == "This mission has 31 pull requests, too many to draw clearly, so it shows as a list.")
        #expect(OrderText.notInAMission(1) == "1 pull request isn't in a mission. List shows it.")
        #expect(OrderText.notInAMission(3) == "3 pull requests aren't in a mission. List shows them.")
        #expect(OrderText.title(of: .wave(3)) == nil)
    }
}
