import Foundation
import Testing
@testable import BriefBarCore

/// My Work's Map: the Board's cards and the steps you and sessions added as graphs, by mission or all together, in waves, with
/// the lines between them, through what it doesn't show; and the cards and steps you hid.
@Suite struct WorkMapTests {
    private typealias Steps = NextStepsTests

    static func pr(_ number: Int) -> ItemRef { Steps.pr(number) }
    static func node(_ number: Int) -> MapNodeID { .card(pr(number)) }
    static func work(_ id: Int) -> MapNodeID { .card(Steps.task(id)) }
    static func id(_ number: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))! }
    static let session = ItemRef.session("2f8a4c6e-1b3d-4e5f-8a7b-9c0d1e2f3a14")!
    static let day = Date(timeIntervalSince1970: 1_800_000_000)

    static func name(_ item: WorkMapItem) -> String {
        switch item {
        case .card(let card): card.ref.shortOrderLabel
        case .step(let step): step.name
        }
    }

    /// Where each of a graph is: its name, column and row, as VoiceOver reads them, those of other bands with "~".
    static func places(_ graph: WorkMapGraph?) -> [String] {
        (graph?.nodes ?? []).map { "\($0.elsewhere == nil ? "" : "~")\(name($0.item)) \($0.column),\($0.row)" }
    }

    /// A graph's lines, as "from > to", by name.
    static func lines(_ graph: WorkMapGraph?, in map: WorkMap) -> Set<String> {
        Set((graph?.lines ?? []).map { "\(label($0.before, in: map)) > \(label($0.after, in: map))" })
    }

    static func label(_ node: MapNodeID, in map: WorkMap) -> String {
        map.item(node).map(name) ?? node.ref?.shortOrderLabel ?? "?"
    }

    static func waits(on numbers: [Int]) -> OrderStanding {
        .waiting(open: numbers.map(pr), unknown: [])
    }

    static func open(_ numbers: [Int]) -> [Int: StageReading] {
        Dictionary(uniqueKeysWithValues: numbers.map { ($0, Steps.reading(.inProgress, .draft, at: 1)) })
    }

    /// Steps and lines, as you or a session said them, in the order given, a second apart.
    static func edits(
        steps: [(Int, String)] = [], lines: [(MapNodeID, MapNodeID)] = [], off: [(MapNodeID, MapNodeID)] = [],
        by author: MapAuthor = .session(session), home: LaneOrderKey? = nil
    ) -> MapEdits {
        var edits = MapEdits()
        var at = day
        for (number, name) in steps {
            edits.addStep(id(number), name: name, home: home, by: author, at: at)
            at += 1
        }
        for (before, after) in lines {
            edits.set(.init(before, after), on: true, by: author, at: at)
            at += 1
        }
        for (before, after) in off {
            edits.set(.init(before, after), on: false, by: author, at: at)
            at += 1
        }
        return edits
    }

    /// !4100 merged, !4101 stacked on it, then !4102 and !4103 after it in the order.
    static let chain = Steps.mission([
        Steps.step(4100, .merged, status: .merged, place: 1),
        Steps.step(4101, .next, place: 2, stackedOn: [4100]),
        Steps.step(4102, Self.waits(on: [4101]), place: 3, after: [4101]),
        Steps.step(4103, Self.waits(on: [4102]), place: 4, after: [4102]),
    ])

    static let chainStages: [Int: StageReading] = [
        4100: Steps.reading(.merged, .merged, at: 1), 4101: Steps.reading(.inProgress, .draft, at: 2),
        4102: Steps.reading(.waits, .waitsFor([pr(4101)], words: "After !4101"), at: 3),
        4103: Steps.reading(.waits, .waitsFor([pr(4102)], words: "After !4102"), at: 4),
    ]

    @Test func aMissionsOrderRunsStraightThroughItsWavesSolidWhereStacked() throws {
        let map = WorkMap(Steps.board(Self.chainStages, missions: [Self.chain]), missions: [Self.chain])
        let graph = try #require(map.bands.first?.graph)
        #expect(map.bands.count == 1)
        #expect(graph.columns == [.done, .wave(0), .wave(1), .wave(2)])
        #expect(graph.columns.map(\.title) == ["Done", "Now", "Then", "Later"])
        #expect(Self.places(graph) == ["!4100 0,0", "!4101 1,0", "!4102 2,0", "!4103 3,0"])
        #expect(graph.lines == [
            WorkMapLine(before: Self.node(4100), after: Self.node(4101), style: .stacked),
            WorkMapLine(before: Self.node(4101), after: Self.node(4102), style: .order),
            WorkMapLine(before: Self.node(4102), after: Self.node(4103), style: .order),
        ])
        #expect(graph.rows == 1)
        #expect(graph.crossings == 0)
    }

    /// A card you hide leaves its band, which lists it, and a dotted line goes through it, which says so; what comes after it
    /// comes a wave after what's drawn before it, but no sooner than one wave on, as it still waits for the hidden one.
    @Test func aLineGoesDottedThroughACardYouHid() throws {
        let hidden = MapHidden([Self.node(4102)])
        let map = WorkMap(Steps.board(Self.chainStages, missions: [Self.chain]), missions: [Self.chain], hidden: hidden)
        let band = try #require(map.bands.first)
        let graph = try #require(band.graph)
        #expect(band.hidden.map(\.id) == [Self.node(4102)])
        #expect(band.count == 3)
        #expect(graph.columns == [.done, .wave(0), .wave(1)])
        #expect(Self.places(graph) == ["!4100 0,0", "!4101 1,0", "!4103 2,0"])
        #expect(graph.lines.last == WorkMapLine(before: Self.node(4101), after: Self.node(4103), style: .through([Self.node(4102)])))
        #expect(OrderText.through(["!4102"], hidden: 1) == "Through !4102, which you hid")
        #expect(OrderText.through(["!4102", "API tests"], hidden: 0) == "Through !4102 and API tests")
        #expect(OrderText.through(["!4102", "!4105"], hidden: 1) == "Through !4102 and !4105, one of which you hid")
        // All, too: the hidden card is listed, and the line goes through it.
        #expect(map.hidden.map(\.id) == [Self.node(4102)])
        #expect(map.groups.first?.graph?.lines.last?.style == .through([Self.node(4102)]))
    }

    /// A completed card the Map doesn't show holds nothing back, nor does what came before it: no dotted line goes through it,
    /// and what came after it can go now, By Mission too, where what came before it is in another band.
    @Test func whatCameBeforeACompletedCardYouHidHoldsNothingThroughIt() throws {
        let first = Steps.mission([
            Steps.step(4101, .next, place: 1), Steps.step(4102, .merged, status: .merged, place: 2, after: [4101]),
        ])
        let second = Steps.mission([Steps.step(4103, Self.waits(on: [4102]), place: 1, after: [4102])])
        let stages = Self.open([4101, 4103]).merging([4102: Steps.reading(.merged, .merged, at: 1)]) { first, _ in first }
        let board = Steps.board(stages, missions: [first, second])
        let map = WorkMap(board, missions: [first, second], hidden: MapHidden([Self.node(4102)]))
        #expect(map.bands.map { Self.places($0.graph) } == [["!4101 0,0"], ["!4103 0,0"]])
        #expect(map.bands.allSatisfy { $0.graph?.lines.isEmpty == true })
        #expect(map.groups.isEmpty)
        #expect(map.loose.map(\.id) == [Self.node(4101), Self.node(4103)])

        // Shown, it's what the later one waited for, in Done, of the other band.
        let shown = WorkMap(board, missions: [first, second])
        #expect(Self.places(shown.bands.last?.graph) == ["~!4102 0,0", "!4103 1,0"])
    }

    /// For X → A → B → D, with B merged, C after both A and D still waits for A, which is open: D doesn't stand in for it
    /// through B, which holds nothing back.
    @Test func aCompletedCardDoesntCarryWhatCameBeforeItToWhatComesAfter() throws {
        let mission = Steps.mission([
            Steps.step(4500, .next, place: 1), Steps.step(4501, Self.waits(on: [4500]), place: 2, after: [4500]),
            Steps.step(4502, .merged, status: .merged, place: 3, after: [4501]),
            Steps.step(4503, .next, place: 4, after: [4502]), Steps.step(4504, Self.waits(on: [4501, 4503]), place: 5, after: [4501, 4503]),
        ])
        let stages = Self.open([4500, 4501, 4503, 4504]).merging([4502: Steps.reading(.merged, .merged, at: 1)]) { first, _ in first }
        let map = WorkMap(Steps.board(stages, missions: [mission]), missions: [mission])
        let graph = try #require(map.bands.first?.graph)
        #expect(Self.lines(graph, in: map) == ["!4500 > !4501", "!4502 > !4503", "!4501 > !4504", "!4503 > !4504"])
        #expect(Self.places(graph).filter { $0.hasPrefix("!4504") } == ["!4504 3,0"])
        #expect(graph.columns == [.done, .wave(0), .wave(1), .wave(2)])
    }

    /// One that waits for a pull request in another mission shows it there, dimmed, and the line from it; All joins them.
    @Test func aBandShowsWhatItsCardsAreJoinedToElsewhereAndAllJoinsThem() throws {
        let first = Steps.mission([Steps.step(4101, .next, place: 1)])
        let second = Steps.mission([Steps.step(4201, Self.waits(on: [4101]), place: 1, after: [4101])])
        let stages: [Int: StageReading] = [
            4101: Steps.reading(.inProgress, .draft, at: 1),
            4201: Steps.reading(.waits, .waitsFor([Self.pr(4101)], words: "After !4101"), at: 2),
        ]
        let map = WorkMap(Steps.board(stages, missions: [first, second]), missions: [first, second])
        #expect(map.bands.map { Self.places($0.graph) } == [["!4101 0,0", "~!4201 1,0"], ["~!4101 0,0", "!4201 1,0"]])
        #expect(map.bands.last?.graph?.nodes.first?.elsewhere == .mission(first.key))
        #expect(map.bands.map(\.count) == [1, 1])

        let group = try #require(map.groups.first)
        #expect(map.groups.count == 1)
        #expect(group.lanes == [.mission(first.key), .mission(second.key)])
        #expect(Self.places(group.graph) == ["!4101 0,0", "!4201 1,0"])
        #expect(group.graph?.lines == [WorkMapLine(before: Self.node(4101), after: Self.node(4201), style: .order)])
        #expect(map.loose.isEmpty)
    }

    /// Your work's own cards go in their story's mission's band: in Done once resolved or done, else in Now; under the cards
    /// lines join, with none of their own.
    @Test func yourWorksOwnCardsGoUnderTheCardsLinesJoin() throws {
        var checkout = Steps.mission([Steps.step(4101, .next, place: 1), Steps.step(4102, Self.waits(on: [4101]), place: 2, after: [4101])])
        checkout.story = MissionStory(ref: Steps.task(5001))
        let stages: [Int: StageReading] = [
            4101: Steps.reading(.inProgress, .draft, at: 1),
            4102: Steps.reading(.waits, .waitsFor([Self.pr(4101)], words: "After !4101"), at: 2),
        ]
        let work = [
            Steps.work(5103, .inProgress, story: 5001), Steps.work(5104, .toDo, story: 5001), Steps.work(5106, .resolved, story: 5001),
        ]
        let board = Steps.board(stages, missions: [checkout]).withWork(work, missions: [checkout], stories: [Steps.task(5001)])
        let map = WorkMap(board, missions: [checkout])
        let graph = try #require(map.bands.first?.graph)
        #expect(map.bands.count == 1)
        #expect(graph.columns == [.done, .wave(0), .wave(1)])
        #expect(Self.places(graph) == ["5106 0,0", "!4101 1,0", "5103 1,1", "5104 1,2", "!4102 2,0"])

        // All: the order's cards are a graph; the rest no line joins, what's still to do first.
        #expect(map.groups.map { $0.items.map(\.id) } == [[Self.node(4101), Self.node(4102)]])
        #expect(map.loose.map(\.id) == [Self.work(5103), Self.work(5104), Self.work(5106)])
    }

    /// Cards are ordered in each column to cross as few lines as they can, and a line that skips a column keeps a row of it to
    /// itself, so that no card sits on it.
    @Test func linesCrossAsLittleAsTheyCanAndKeepARowOfEachColumnTheySkip() throws {
        let crossed = Steps.mission([
            Steps.step(4101, .next, place: 1), Steps.step(4102, .next, place: 2),
            Steps.step(4103, Self.waits(on: [4102]), place: 3, after: [4102]), Steps.step(4104, Self.waits(on: [4101]), place: 4, after: [4101]),
        ])
        let graph = try #require(WorkMap(Steps.board(Self.open([4101, 4102, 4103, 4104]), missions: [crossed]), missions: [crossed]).bands.first?.graph)
        #expect(Self.places(graph) == ["!4101 0,0", "!4102 0,1", "!4104 1,0", "!4103 1,1"])
        #expect(graph.crossings == 0)

        let skipping = Steps.mission([
            Steps.step(4100, .merged, status: .merged, place: 1), Steps.step(4101, .next, place: 2),
            Steps.step(4102, Self.waits(on: [4101]), place: 3, after: [4100, 4101]),
        ])
        let skipped = try #require(WorkMap(Steps.board(Self.chainStages, missions: [skipping]), missions: [skipping]).bands.first?.graph)
        #expect(Self.places(skipped) == ["!4100 0,0", "!4101 1,0", "!4102 2,0"])
        #expect(skipped.lines.first { $0.before == Self.node(4100) }?.rows == [1])
        #expect(skipped.rows == 2)
        #expect(skipped.crossings == 0)
    }

    /// A pull request that merged before one it should have waited for doesn't stand in for it: what comes after both still
    /// waits for the one that's open, with a line from it.
    @Test func aCardDoneOutOfOrderDoesntHideWhatsStillOpenBeforeIt() throws {
        let mission = Steps.mission([
            Steps.step(4101, .next, place: 1), Steps.step(4102, .merged, status: .merged, place: 2, after: [4101]),
            Steps.step(4103, Self.waits(on: [4101]), place: 3, after: [4101, 4102]),
        ])
        let stages: [Int: StageReading] = [
            4101: Steps.reading(.inProgress, .draft, at: 1), 4102: Steps.reading(.merged, .merged, at: 2),
            4103: Steps.reading(.waits, .waitsFor([Self.pr(4101)], words: "After !4101"), at: 3),
        ]
        let graph = try #require(WorkMap(Steps.board(stages, missions: [mission]), missions: [mission]).bands.first?.graph)
        #expect(graph.columns == [.done, .wave(0), .wave(1)])
        #expect(Self.places(graph) == ["!4102 0,0", "!4101 1,0", "!4103 2,0"])
        #expect(graph.lines.contains(WorkMapLine(before: Self.node(4101), after: Self.node(4103), style: .order)))
    }

    /// Cards in a loop of lines, where none can go first, share a wave, and what comes after the loop comes a wave after it,
    /// with its line, wherever the Board puts it.
    @Test func aLoopSharesAWaveAndWhatComesAfterItFollows() throws {
        let mission = Steps.mission([
            Steps.step(4203, Self.waits(on: [4202]), place: 1, after: [4202]),
            Steps.step(4201, Self.waits(on: [4202]), place: 2, after: [4202]),
            Steps.step(4202, Self.waits(on: [4201]), place: 3, after: [4201]),
        ])
        let map = WorkMap(Steps.board(Self.open([4201, 4202, 4203]), missions: [mission]), missions: [mission])
        let graph = try #require(map.bands.first?.graph)
        #expect(graph.columns == [.wave(0), .wave(1)])
        #expect(Self.places(graph) == ["!4202 0,0", "!4201 0,1", "!4203 1,0"])
        #expect(graph.lines == [WorkMapLine(before: Self.node(4202), after: Self.node(4203), style: .order)])
        #expect(WorkMapGraph.loops([4203, 4201, 4202].map(Self.node), lines: [
            WorkMapLine(before: Self.node(4202), after: Self.node(4203), style: .order),
            WorkMapLine(before: Self.node(4202), after: Self.node(4201), style: .order),
            WorkMapLine(before: Self.node(4201), after: Self.node(4202), style: .order),
        ]) == [[Self.node(4203)], [Self.node(4201), Self.node(4202)]])
        #expect(map.wouldLoop(before: Self.node(4203), after: Self.node(4201)))
        #expect(!map.wouldLoop(before: Self.node(4201), after: Self.node(4203)))
    }

    /// One that waits for an open card and for a card in a loop with it still waits for the open one, with its line: the loop
    /// doesn't say it already, through itself; the loop comes a wave after it, and All joins them.
    @Test func aLoopThroughACardKeepsWhatElseItWaitsFor() throws {
        let mission = Steps.mission([
            Steps.step(4200, .next, place: 1), Steps.step(4201, Self.waits(on: [4202]), place: 2, after: [4202]),
            Steps.step(4202, Self.waits(on: [4200, 4201]), place: 3, after: [4200, 4201]),
        ])
        let map = WorkMap(Steps.board(Self.open([4200, 4201, 4202]), missions: [mission]), missions: [mission])
        let graph = try #require(map.bands.first?.graph)
        #expect(Self.lines(graph, in: map) == ["!4200 > !4202"])
        #expect(graph.columns == [.wave(0), .wave(1)])
        #expect(Self.places(graph).first == "!4200 0,0")
        #expect(map.groups.map { $0.items.count } == [3] && map.loose.isEmpty)
    }

    /// What's said of a work item with no card of its own is said of the cards of the pull requests Show Links links to it,
    /// whatever Show shows, as with + Sprint Tasks of those the cards name: the task's pull request is joined, and a line
    /// said of the task on one side only stays.
    @Test func aWorkItemsLinesGoToThePullRequestsLinkedToItWhateverShowShows() throws {
        let board = Steps.board(Self.open([4300, 4301, 4302, 4303]))
        let told = MapEdits.merged([
            Self.edits(lines: [(Self.work(5300), Self.node(4301)), (Self.node(4302), Self.work(5300)), (Self.work(5301), Self.node(4303))]),
        ], now: Self.day)
        let without = WorkMap(board, missions: [], state: told)
        #expect(without.groups.map { Self.lines($0.graph, in: without) } == [["!4302 > !4301"]])
        #expect(without.loose.map(\.id) == [Self.node(4300), Self.node(4303)])

        let linked = [Self.pr(4300): [Steps.task(5300)], Self.pr(4303): [], Self.pr(4301): [Steps.task(5301)]]
        let map = WorkMap(board, missions: [], state: told, linked: linked)
        let group = try #require(map.groups.first)
        #expect(map.groups.count == 1 && map.loose.isEmpty)
        #expect(Self.lines(group.graph, in: map) == ["!4302 > !4300", "!4300 > !4301", "!4301 > !4303"])
    }

    /// A graph as big as the Map draws, whose lines skip many waves and so take a slot in each, lays out at once: a swap of
    /// neighbours weighs only the lines it changes, rather than counting every crossing again.
    @Test(.onTestThreads) func aBigGraphWithLongLinesLaysOutQuickly() throws {
        // A chain of 30 steps, and 30 more, each after its first and before its last.
        var lines = (1..<30).map { (MapNodeID.step(Self.id($0)), MapNodeID.step(Self.id($0 + 1))) }
        for number in 31...60 {
            lines += [(.step(Self.id(1)), .step(Self.id(number))), (.step(Self.id(number)), .step(Self.id(30)))]
        }
        let state = MapEdits.merged([Self.edits(steps: (1...60).map { ($0, "Step \($0)") }, lines: lines)], now: Self.day)
        let start = ContinuousClock.now
        let map = WorkMap(Steps.board([:]), missions: [], state: state)
        #expect(ContinuousClock.now - start < .seconds(2))
        let graph = try #require(map.bands.first?.graph)
        #expect(graph.nodes.count == 60 && graph.columns.count == 30 && graph.crossings == 0)
    }

    /// An open card that both cards of a loop wait for keeps its line into each: neither says it already for the other.
    @Test func aCardBeforeBothOfALoopKeepsItsLineIntoEach() throws {
        let mission = Steps.mission([
            Steps.step(4200, .next, place: 1), Steps.step(4201, Self.waits(on: [4200, 4202]), place: 2, after: [4200, 4202]),
            Steps.step(4202, Self.waits(on: [4200, 4201]), place: 3, after: [4200, 4201]),
        ])
        let map = WorkMap(Steps.board(Self.open([4200, 4201, 4202]), missions: [mission]), missions: [mission])
        let graph = try #require(map.bands.first?.graph)
        #expect(Self.lines(graph, in: map) == ["!4200 > !4201", "!4200 > !4202"])
        #expect(graph.columns == [.wave(0), .wave(1)])
        #expect(map.groups.map { $0.items.count } == [3] && map.loose.isEmpty)
    }

    /// While a search shows only part of the Map, a card it leaves out that's done on the whole board holds nothing back: what
    /// waits for it can go now.
    @Test func aDoneCardTheSearchLeavesOutHoldsNothingBack() throws {
        let board = Steps.board([:]).withWork([Steps.work(5103, .toDo)], missions: [], stories: [])
        let state = MapEdits.merged([Self.edits(lines: [(Self.work(5102), Self.work(5103))], by: .you)], now: Self.day)
        let searched = WorkMap(board, missions: [], state: state, done: [Steps.task(5102)])
        #expect(searched.bands.first?.graph?.columns == [.wave(0)])
        let unknown = WorkMap(board, missions: [], state: state)
        #expect(unknown.bands.first?.graph?.columns == [.wave(1)])
        let whole = Steps.board([:]).withWork([Steps.work(5102, .completed), Steps.work(5103, .toDo)], missions: [], stories: [])
        #expect(WorkMap.done(on: whole) == [Steps.task(5102)])
    }

    /// All: each set of cards lines join is a group, the one with the Board's first card first; the cards no line joins are
    /// loose, and those you hid are listed apart, in the Board's order.
    @Test func allGroupsWhatLinesJoinAndListsTheRest() {
        let other = Steps.mission([Steps.step(4201, place: 1), Steps.step(4202, place: 2)])
        let stages = Self.chainStages.merging([
            4201: Steps.reading(.inProgress, .draft, at: 5), 4202: Steps.reading(.inProgress, .draft, at: 6),
        ]) { first, _ in first }
        let board = Steps.board(stages, missions: [Self.chain, other])
            .withWork([Steps.work(5150, .toDo)], missions: [Self.chain, other], stories: [])
        let map = WorkMap(board, missions: [Self.chain, other], hidden: MapHidden([Self.node(4202)]))
        #expect(map.groups.map { $0.items.map(Self.name) } == [["!4100", "!4101", "!4102", "!4103"]])
        #expect(map.loose.map(Self.name) == ["!4201", "5150"])
        #expect(map.hidden.map(Self.name) == ["!4202"])
        #expect(map.bands.map(\.lane.kind) == [.mission(Self.chain.key), .mission(other.key), .notInAMission])
        #expect(map.columns == [.done, .wave(0), .wave(1), .wave(2)])
    }

    /// Lines you or sessions add join cards and steps, whatever their missions, and those taken away go, an order's too, on
    /// the Map only; a step goes in the band it was added in, else in that of the cards it's joined to; and what's said of a
    /// work item a pull request's card names is said of that card.
    @Test func linesAndStepsYouAndSessionsAddJoinTheMapAndTakenAwayGo() throws {
        let retries = Steps.mission([Steps.step(4101, .next, place: 1), Steps.step(4102, Self.waits(on: [4101]), place: 2, after: [4101])])
        let coupons = Steps.mission([Steps.step(4091, .next, place: 1)])
        let board = Steps.board(Self.open([4101, 4102, 4091]), missions: [retries, coupons])
            .withWork(
                [Steps.work(5112, .inProgress, linked: [Steps.linked(4091)]), Steps.work(5150, .toDo)], missions: [retries, coupons],
                stories: []
            )
        #expect(board.workOfPullRequests[Self.pr(4091)] == [Steps.task(5112)])
        let told = Self.edits(
            steps: [(1, "Load test retries"), (2, "Enable retries in production")],
            lines: [(Self.node(4102), .step(Self.id(1))), (.step(Self.id(1)), .step(Self.id(2))), (Self.work(5112), .step(Self.id(2)))]
        )
        let yours = Self.edits(lines: [(Self.work(5150), Self.node(4091))], off: [(Self.node(4101), Self.node(4102))], by: .you)
        var later = yours
        later.set(.init(Self.node(4102), .step(Self.id(1))), on: false, by: .you, at: Self.day - 10)
        let map = WorkMap(board, missions: [retries, coupons], state: MapEdits.merged([later, told], now: Self.day))

        let band = try #require(map.bands.first)
        #expect(band.lane.kind == .mission(retries.key))
        // !4101 no longer comes before !4102, as you took that line away: lines join !4102, which goes first.
        #expect(Self.places(band.graph) == [
            "!4102 0,0", "!4101 0,1", "Load test retries 1,0", "~!4091 1,1", "Enable retries in production 2,0",
        ])
        #expect(Self.lines(band.graph, in: map) == [
            "!4102 > Load test retries", "Load test retries > Enable retries in production", "!4091 > Enable retries in production",
        ])
        // The rounding fix's band shows what its card is joined to elsewhere: the task you said comes first, and the step.
        #expect(Self.places(map.bands[1].graph) == ["~5150 0,0", "!4091 1,0", "~Enable retries in production 2,0"])
        let said = band.graph?.lines.first { $0.after == .step(Self.id(1)) }
        #expect(said?.style == .said(.session(Self.session)))
        #expect(map.waitsFor(Self.node(4102)).isEmpty)
        #expect(map.waitsFor(.step(Self.id(2))).map(\.node) == [Self.node(4091), .step(Self.id(1))])
        #expect(map.waitingFor(Self.node(4091)) == [.step(Self.id(2))])
        #expect(map.band(of: .step(Self.id(2))) == .mission(retries.key))
        // All: one graph, across the three bands; !4101, which nothing joins now, in the grid.
        #expect(map.groups.map { $0.items.map(Self.name) }
            == [["!4102", "Load test retries", "Enable retries in production", "!4091", "5150"]])
        #expect(map.loose.map(Self.name) == ["!4101"])
    }

    /// A feature as it usually goes: three flows of pull requests that wait for each other, then tests that wait for all of
    /// them, and what waits for those, to the announcement; and another feature beside it. Lines run only from what holds
    /// each, though more was said; By Mission each band shows what its own wait for elsewhere; All shows the two graphs, their
    /// columns lined up.
    @Test func aWholeFeatureFansInAndOutAcrossItsMissions() throws {
        let search = Steps.mission([Steps.step(4301, .next, place: 1), Steps.step(4302, Self.waits(on: [4301]), place: 2, after: [4301])])
        let entity = Steps.mission([
            Steps.step(4311, .next, place: 1), Steps.step(4312, Self.waits(on: [4311]), place: 2, after: [4311]),
            Steps.step(4313, Self.waits(on: [4311]), place: 3, after: [4311]),
        ])
        let relations = Steps.mission([Steps.step(4321, .next, place: 1), Steps.step(4322, Self.waits(on: [4321]), place: 2, after: [4321])])
        let payments = Steps.mission([Steps.step(4401, .next, place: 1), Steps.step(4402, Self.waits(on: [4401]), place: 2, after: [4401])])
        let missions = [search, entity, relations, payments]
        let features = [4301, 4302, 4311, 4312, 4313, 4321, 4322].map(Self.node)
        let ends = [4302, 4312, 4313, 4322].map(Self.node)
        let (api, e2e, dev, monitoring, staging, production, announce) =
            (MapNodeID.step(Self.id(1)), MapNodeID.step(Self.id(2)), MapNodeID.step(Self.id(3)), MapNodeID.step(Self.id(4)),
             MapNodeID.step(Self.id(5)), MapNodeID.step(Self.id(6)), MapNodeID.step(Self.id(7)))
        // Piece by piece, as one expression takes the compiler too long on a slower Mac.
        var lines: [(MapNodeID, MapNodeID)] = features.map { ($0, api) }
        lines += ends.map { ($0, e2e) }
        lines += [(api, dev), (dev, monitoring)]
        lines += [api, e2e, dev, monitoring].map { ($0, staging) }
        let beforeProduction: [MapNodeID] = features + [api, e2e, dev, monitoring, staging]
        lines += beforeProduction.map { ($0, production) }
        lines += [(production, announce), (Self.node(4402), MapNodeID.step(Self.id(8)))]
        let steps: [(Int, String)] = [
            (1, "API tests"), (2, "E2E tests"), (3, "Test in dev"), (4, "Monitoring and alerts"), (5, "Enable in staging"),
            (6, "Enable in production"), (7, "Announce it"), (8, "Load test"),
        ]
        let told = Self.edits(steps: steps, lines: lines)
        let map = WorkMap(
            Steps.board(Self.open([4301, 4302, 4311, 4312, 4313, 4321, 4322, 4401, 4402]), missions: missions), missions: missions,
            state: MapEdits.merged([told], now: Self.day)
        )

        let feature = try #require(map.groups.first?.graph)
        #expect(map.groups.count == 2)
        #expect(Self.lines(feature, in: map) == [
            "!4301 > !4302", "!4311 > !4312", "!4311 > !4313", "!4321 > !4322",
            "!4302 > API tests", "!4312 > API tests", "!4313 > API tests", "!4322 > API tests",
            "!4302 > E2E tests", "!4312 > E2E tests", "!4313 > E2E tests", "!4322 > E2E tests",
            "API tests > Test in dev", "Test in dev > Monitoring and alerts", "Monitoring and alerts > Enable in staging",
            "E2E tests > Enable in staging", "Enable in staging > Enable in production", "Enable in production > Announce it",
        ])
        var columns: [String: WorkMapColumn] = [:]
        for node in feature.nodes {
            columns[Self.name(node.item)] = feature.columns[node.column]
        }
        #expect(columns["!4311"] == .wave(0))
        #expect(columns["!4313"] == .wave(1))
        #expect(columns["API tests"] == .wave(2))
        #expect(columns["E2E tests"] == .wave(2))
        #expect(columns["Enable in staging"] == .wave(5))
        #expect(columns["Announce it"] == .wave(7))
        #expect(map.columns == (0...7).map(WorkMapColumn.wave))
        #expect(map.groups.last?.graph?.columns == map.columns)
        #expect(map.groups.last.map { $0.items.map(Self.name) } == ["!4401", "!4402", "Load test"])

        // By Mission, the steps go where most of the cards they wait for are, the entity page's, which shows the other flows'
        // ends they wait for, dimmed; and each other flow's band shows the tests its end holds.
        func elsewhere(_ mission: OrderMission) -> [String] {
            let band = map.bands.first { $0.lane.kind == .mission(mission.key) }
            let nodes: [WorkMapNode] = band?.graph?.nodes ?? []
            return nodes.filter { $0.elsewhere != nil }.map { Self.name($0.item) }.sorted()
        }
        let entityBand = try #require(map.bands.first { $0.lane.kind == .mission(entity.key) })
        #expect(entityBand.count == 10)
        #expect(elsewhere(entity) == ["!4302", "!4322"])
        #expect(elsewhere(search) == ["API tests", "E2E tests"])
        #expect(map.band(of: announce) == .mission(entity.key))
        #expect(map.band(of: .step(Self.id(8))) == .mission(payments.key))
    }

    /// A graph of more than the Map draws clearly has none: the Board shows them.
    @Test func tooManyCardsHaveNoGraph() {
        let count = WorkMap.mostCards + 1
        let mission = Steps.mission((1...count).map { Steps.step(4100 + $0, place: $0) })
        let stages = Self.open((1...count).map { 4100 + $0 })
        let map = WorkMap(Steps.board(stages, missions: [mission]), missions: [mission])
        #expect(map.bands.first?.graph == nil)
        #expect(map.bands.first?.count == count)
        #expect(OrderText.tooManyCards(61) == "These 61 cards are too many to draw clearly. The Board shows them.")
        let fewer = WorkMap(Steps.board(stages, missions: [mission]), missions: [mission], hidden: MapHidden([Self.node(4100 + count)]))
        #expect(fewer.bands.first?.graph != nil)
    }

    /// The cards and steps you hid: the one you hid last first, each once, at most `mostCards`; shown again one by one, all at
    /// once, as their source goes, or as a step does; kept by reference.
    @Test func hiddenCardsAreKeptByReference() {
        var hidden = MapHidden()
        let hidFirst = hidden.hide(Self.node(4101))
        let hidSecond = hidden.hide(Self.work(5104))
        let hidAgain = hidden.hide(Self.node(4101))
        #expect(hidFirst && hidSecond && !hidAgain)
        #expect(hidden.nodes == [Self.work(5104), Self.node(4101)])
        let shown = hidden.show([Self.node(4101)])
        let shownAgain = hidden.show([Self.node(4101)])
        #expect(shown && !shownAgain)
        #expect(hidden.nodes == [Self.work(5104)])

        let defaults = MemorySettings()
        hidden.hide(Self.node(4102))
        hidden.hide(.step(Self.id(1)))
        hidden.save(to: defaults)
        #expect(defaults.object(forKey: "order.map.hidden") as? [String] == [
            "step/00000000-0000-0000-0000-000000000001", "pullRequest/contoso/4102", "workItem/contoso/5104",
        ])
        #expect(MapHidden.load(from: defaults) == hidden)
        let forgot = hidden.forget([.workItem])
        let kept = hidden.keep(steps: [])
        #expect(forgot && kept)
        #expect(hidden.nodes == [Self.node(4102)])
        MapHidden().save(to: defaults)
        #expect(defaults.object(forKey: "order.map.hidden") == nil)

        var full = MapHidden((1...MapHidden.mostCards).map { Self.node(5000 + $0) })
        full.hide(Self.node(4101))
        #expect(full.nodes.count == MapHidden.mostCards)
        #expect(full.nodes.first == Self.node(4101))
        #expect(!full.contains(Self.node(5000 + MapHidden.mostCards)))

        // What My Work shows, and how the Map groups: the Board and By Mission until you choose.
        #expect(MyWorkView.load(from: defaults) == .board)
        MyWorkView.map.save(to: defaults)
        #expect(MyWorkView.load(from: defaults) == .map)
        #expect(WorkMapGrouping.load(from: defaults) == .byMission)
        WorkMapGrouping.all.save(to: defaults)
        #expect(WorkMapGrouping.load(from: defaults) == .all)
    }
}

/// What you and sessions change of My Work's Map: lines and steps, the latest change of each winning, kept by reference with
/// the names typed; and what sessions tell through `tell_dependencies`, and read with `work_map`.
@Suite struct WorkMapEditsTests {
    typealias Map = WorkMapTests

    /// Both sides together: each line's latest change, each step's latest name and done, wherever made; a step deleted is
    /// gone for good, with its lines, and one done for two weeks goes too.
    @Test func theLatestChangeOfEachLineAndStepWinsAndADeletedStepIsGone() {
        let (step, other, old) = (Map.id(1), Map.id(2), Map.id(3))
        var yours = MapEdits()
        var told = MapEdits()
        told.addStep(step, name: "API tests", home: nil, by: .session(Map.session), at: Map.day)
        yours.rename(step, to: "API and contract tests", by: .you, at: Map.day + 10)
        told.setDone(step, true, by: .session(Map.session), at: Map.day + 20)
        yours.set(.init(Map.node(4101), .step(step)), on: true, by: .you, at: Map.day + 30)
        told.set(.init(Map.node(4101), .step(step)), on: false, by: .session(Map.session), at: Map.day + 40)
        told.set(.init(Map.node(4102), .step(step)), on: true, by: .session(Map.session), at: Map.day + 50)
        yours.addStep(other, name: "Monitoring", home: .notInAMission, by: .you, at: Map.day + 60)
        told.set(.init(.step(step), .step(other)), on: true, by: .session(Map.session), at: Map.day + 70)
        told.addStep(old, name: "Old", home: nil, by: .session(Map.session), at: Map.day - 30 * 86_400)
        told.setDone(old, true, by: .session(Map.session), at: Map.day - 20 * 86_400)

        let state = MapEdits.merged([yours, told], now: Map.day + 100)
        #expect(state.steps.map(\.name) == ["API and contract tests", "Monitoring"])
        #expect(state.steps.first?.isDone == true)
        #expect(state.steps.first?.addedBy == .session(Map.session))
        #expect(state.steps.first?.changedBy == .session(Map.session))
        #expect(state.steps.last?.home == .notInAMission)
        #expect(state.lines[.init(Map.node(4101), .step(step))]?.isOn == false)
        #expect(state.lines.count == 3)

        yours.delete(other, by: .you, at: Map.day + 80)
        let after = MapEdits.merged([yours, told], now: Map.day + 100)
        #expect(after.steps.map(\.name) == ["API and contract tests"])
        #expect(after.lines[.init(.step(step), .step(other))] == nil)

        // Each side forgets what's done or deleted two weeks ago, its own only; what the side that added a step forgot doesn't
        // come back from the other's.
        let later = Map.day + 15 * 86_400
        let prunedTold = told.prune(with: yours, now: later)
        #expect(prunedTold)
        #expect(told.steps[old] == nil && told.steps[step] == nil)
        #expect(MapEdits.merged([yours, told], now: later).steps.isEmpty)
        let prunedYours = yours.prune(with: told, now: later)
        #expect(prunedYours)
        #expect(yours.steps.isEmpty && yours.lines.isEmpty)
        #expect(MapEdits.name("  API\ntests  ") == "API tests")
        #expect(MapEdits.name(" \n ") == nil)
        #expect(MapEdits.name(String(repeating: "x", count: 100))?.count == MapEdits.mostCharacters)
    }

    /// Kept as references, dates and the names typed, without what this build can't read; and forgotten with the source of
    /// what they're about.
    @Test func editsAreKeptByReferenceAndForgottenWithTheirSource() {
        var edits = MapEdits()
        let story = LaneOrderKey.story(Steps.task(5101))
        edits.addStep(Map.id(1), name: "API tests", home: story, by: .you, at: Map.day)
        edits.addStep(Map.id(2), name: "Enable in prod", home: nil, by: .session(Map.session), at: Map.day)
        edits.set(.init(Map.node(4101), .step(Map.id(1))), on: true, by: .you, at: Map.day)
        edits.set(.init(Map.node(4101), Map.node(4102)), on: false, by: .session(nil), at: Map.day)
        edits.set(.init(Map.node(4101), Map.node(4101)), on: true, by: .you, at: Map.day)
        let defaults = MemorySettings()
        edits.save(to: defaults, key: MapEdits.yoursKey)
        #expect(MapEdits.load(from: defaults, key: MapEdits.yoursKey) == edits)
        #expect(MapEdits.load(from: defaults, key: MapEdits.toldKey).isEmpty)
        let json = String(data: defaults.data(forKey: MapEdits.yoursKey) ?? Data(), encoding: .utf8) ?? ""
        #expect(json.contains("story\\/workItem\\/contoso\\/5101") && json.contains("session"))

        // As Copilot goes, which session said what goes; as Azure DevOps goes, everything does, the Map being its My Work's.
        var forgotten = edits
        let forgotSessions = forgotten.forget([.session])
        #expect(forgotSessions)
        #expect(MapEdits.merged([forgotten], now: Map.day).steps.map(\.addedBy) == [.you, .session(nil)])
        #expect(forgotten.steps.count == 2 && forgotten.lines.count == 2)
        let forgotWork = forgotten.forget([.workItem])
        let forgotAgain = forgotten.forget([.pullRequest])
        #expect(forgotWork && forgotten.isEmpty && !forgotAgain)
        MapEdits().save(to: defaults, key: MapEdits.yoursKey)
        #expect(defaults.data(forKey: MapEdits.yoursKey) == nil)
    }

    private typealias Steps = NextStepsTests

    /// `tell_dependencies`: steps by name, added when new and found again whatever their case; pull requests and work items by
    /// their links, or numbers with the organization; what's taken away; and where it goes against what the user said, which
    /// it says. Anything it can't read changes nothing.
    @Test func sessionsTellDependenciesByLinksNumbersAndStepNames() throws {
        var yours = MapEdits()
        yours.set(.init(Map.node(4105), Map.node(4116)), on: true, by: .you, at: Map.day)
        var told = MapEdits()
        let by = MapAuthor.session(Map.session)
        let request = MapRequest(
            dependencies: [
                .init(item: "step:API tests", waitsFor: ["!4105", "https://dev.azure.com/contoso/shop/_workitems/edit/5104"]),
                .init(item: "step:api TESTS", waitsFor: ["5103"]),
                .init(item: "step:Enable in production", waitsFor: ["step:API tests"]),
            ],
            remove: [.init(item: "!4116", waitsFor: ["!4105"])],
            organization: "Contoso"
        )
        let lines = try told.apply(request, yours: yours, by: by, now: Map.day + 10)
        let state = MapEdits.merged([yours, told], now: Map.day + 10)
        #expect(state.steps.map(\.name) == ["API tests", "Enable in production"])
        let api = try #require(state.steps.first?.id)
        #expect(state.lines.filter(\.value.isOn).keys.filter { $0.after == .step(api) }.map(\.before).sorted()
            == [Map.work(5103), Map.work(5104), Map.node(4105)])
        #expect(state.lines[.init(Map.node(4105), Map.node(4116))]?.isOn == false)
        #expect(lines.first == "Added step “API tests” (step:\(api.uuidString.lowercased())).")
        #expect(lines.contains("“API tests” (step:\(api.uuidString.lowercased())) waits for !4105 in contoso and work item 5104 in contoso."))
        #expect(lines.contains { $0.hasPrefix("The user had drawn the line from !4105 in contoso to !4116 in contoso") })

        let production = try #require(state.steps.last?.id)
        let renamed = try told.apply(
            MapRequest(steps: [
                .init(step: "step:\(api.uuidString.lowercased())", name: "API and contract tests", done: true),
                .init(step: "\(production.uuidString.lowercased()) (“Enable in production”)", delete: true),
            ]),
            yours: yours, by: by, now: Map.day + 20
        )
        #expect(renamed == [
            "Renamed step “API tests” (step:\(api.uuidString.lowercased())) to “API and contract tests”.",
            "Marked step “API and contract tests” (step:\(api.uuidString.lowercased())) done.",
            "Deleted step “Enable in production” (step:\(production.uuidString.lowercased())).",
        ])
        #expect(MapEdits.merged([yours, told], now: Map.day + 20).steps.map(\.name) == ["API and contract tests"])

        // A name never finds a step another call added, as another mission's can share it: it adds one, saying so.
        let other = try told.apply(
            MapRequest(dependencies: [.init(item: "step:API and contract tests", waitsFor: ["!4116"])], organization: "contoso"),
            yours: yours, by: .session(nil), now: Map.day + 25
        )
        let both = MapEdits.merged([yours, told], now: Map.day + 25).steps
        #expect(both.map(\.name) == ["API and contract tests", "API and contract tests"])
        #expect(other.first?.hasSuffix(
            "The Map has another step called so, step:\(api.uuidString.lowercased()), which this isn't: name that one by its ID where you mean it."
        ) == true)
        #expect(throws: MapRequestError.noSuchStep("API and contract tests")) {
            try told.apply(MapRequest(steps: [.init(step: "API and contract tests", done: false)]), yours: yours, by: by, now: Map.day + 26)
        }

        let before = told
        let refusals: [(MapRequest, MapRequestError)] = [
            (MapRequest(), .nothing),
            (MapRequest(dependencies: [.init(item: "!4116", waitsFor: ["!4105"])]), .noOrganization("!4116")),
            (MapRequest(dependencies: [.init(item: "step:Docs", waitsFor: ["the API"])], organization: "contoso"), .unreadable("the API")),
            (MapRequest(dependencies: [.init(item: "https://github.com/contoso/shop-web/pull/12", waitsFor: ["!4105"])], organization: "contoso"),
             .notOnTheMap("https://github.com/contoso/shop-web/pull/12")),
            (MapRequest(dependencies: [.init(item: "!4105", waitsFor: ["!4105"])], organization: "contoso"), .itself("!4105")),
            (MapRequest(steps: [.init(step: "Nothing like it", done: true)]), .noSuchStep("Nothing like it")),
        ]
        for (request, refusal) in refusals {
            #expect(throws: refusal) { try told.apply(request, yours: yours, by: by, now: Map.day + 30) }
        }
        #expect(told == before)
    }

    /// `work_map`: the steps and the lines said or taken away, with who and when, the asking session's as its own.
    @Test func sessionsReadTheMapsStepsAndLinesWithWhoSaidThem() throws {
        #expect(MapEdits.describe(yours: MapEdits(), told: MapEdits(), now: Map.day, session: nil).hasPrefix("Neither the user nor"))
        var told = MapEdits()
        told.addStep(Map.id(1), name: "API tests", home: nil, by: .session(Map.session), at: Map.day)
        told.set(.init(Map.node(4105), .step(Map.id(1))), on: true, by: .session(Map.session), at: Map.day)
        var yours = MapEdits()
        yours.set(.init(Map.node(4101), Map.node(4102)), on: false, by: .you, at: Map.day)
        let text = MapEdits.describe(yours: yours, told: told, now: Map.day, session: Map.session)
        #expect(text.contains("- “API tests” (step:00000000-0000-0000-0000-000000000001): to do. Added by your session."))
        #expect(text.contains("- “API tests” (step:00000000-0000-0000-0000-000000000001) waits for !4105 in contoso: said by your session on "))
        #expect(text.contains("- !4102 in contoso doesn't wait for !4101 in contoso: taken away by the user on "))
    }
}
