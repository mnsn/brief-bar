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
        case .workItem(let item): item.ref.shortOrderLabel
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

    /// Where a graph's columns don't all fit across the page, they fold into as few tiers as that takes, as text wraps: where
    /// the fewest lines cross, and, of those, with the first tiers fullest. A tier takes only the rows its cards and the lines
    /// through it take.
    @Test func columnsFoldWhereTheFewestLinesCrossAndATierTakesOnlyItsRows() throws {
        let chain = (0..<6).map { $0...($0 + 1) }
        #expect(WorkMapFold(columns: 7, across: 7, spans: chain).starts == [0])
        let folded = WorkMapFold(columns: 7, across: 4, spans: chain)
        #expect(folded.starts == [0, 4])
        #expect(folded.columns(ofTier: 0) == 0..<4 && folded.columns(ofTier: 1) == 4..<7)
        #expect([3, 4, 6].map(folded.tier(of:)) == [0, 1, 1])
        #expect(folded.wraps(3...4, into: 1) && folded.wraps(1...6, into: 1))
        #expect(!folded.wraps(0...3, into: 1) && !folded.wraps(4...6, into: 1) && !folded.wraps(3...4, into: 0))
        // Three lines leave the fourth column, and only one the third: it folds before the fourth.
        #expect(WorkMapFold(columns: 7, across: 4, spans: Array(chain.prefix(4)) + [3...5, 3...6, 4...5]).starts == [0, 3])
        #expect(WorkMapFold(columns: 9, across: 4, spans: (0..<8).map { $0...($0 + 1) }).starts == [0, 4, 8])
        #expect(WorkMapFold(columns: 3, across: 1, spans: [0...2]).starts == [0, 1, 2])

        let skipping = Steps.mission([
            Steps.step(4100, .merged, status: .merged, place: 1), Steps.step(4101, .next, place: 2),
            Steps.step(4102, Self.waits(on: [4101]), place: 3, after: [4100, 4101]),
        ])
        let skipped = try #require(WorkMap(Steps.board(Self.chainStages, missions: [skipping]), missions: [skipping]).bands.first?.graph)
        #expect(Set(skipped.spans) == [0...2, 1...2])
        #expect([0..<1, 1..<2, 2..<3, 0..<3].map(skipped.rows(in:)) == [[0], [0, 1], [0], [0, 1]])
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

    /// A step added in Not in a mission stays there once a line joins it to a mission's card, though the Board has no such
    /// lane: only one added nowhere goes where what it's joined to is.
    @Test func aStepAddedInNotInAMissionStaysThereJoined() {
        let mission = Steps.mission([Steps.step(4400, .next, place: 1)])
        let board = Steps.board(Self.open([4400]), missions: [mission])
        #expect(!board.lanes.contains { $0.kind == .notInAMission })
        let added = Self.edits(steps: [(1, "Announce it")], lines: [(Self.node(4400), .step(Self.id(1)))], by: .you, home: .notInAMission)
        let told = Self.edits(steps: [(2, "Enable in prod")], lines: [(Self.node(4400), .step(Self.id(2)))])
        let map = WorkMap(board, missions: [mission], state: MapEdits.merged([added, told], now: Self.day))
        #expect(map.band(of: .step(Self.id(1))) == .notInAMission)
        #expect(map.band(of: .step(Self.id(2))) == .mission(mission.key))
        #expect(map.bands.map(\.lane.kind) == [.mission(mission.key), .notInAMission])
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

    /// Done off leaves what's done off the Map, as what you hid is, but listed nowhere: pull requests that merged, work
    /// that's done and steps done, and with them the Done column and a band with nothing else, but for one that keeps what
    /// you hid; no line goes through them, as they hold nothing back. On until you turn it off, remembered.
    @Test func doneOffLeavesWhatsDoneOffTheMap() throws {
        let finished = Steps.mission([Steps.step(4201, .merged, status: .merged, place: 1)])
        let missions = [Self.chain, finished]
        let stages = Self.chainStages.merging([4201: Steps.reading(.merged, .merged, at: 5)]) { first, _ in first }
        let work = [Steps.work(5106, .completed), Steps.work(5107, .inProgress, linked: [Steps.linked(4100)]), Steps.work(5150, .toDo)]
        let board = Steps.board(stages, missions: missions).withWork(work, missions: missions, stories: [])
        var yours = Self.edits(steps: [(1, "API tests")], lines: [(Self.node(4103), .step(Self.id(1)))], by: .you)
        yours.setDone(Self.id(1), true, by: .you, at: Self.day + 10)
        let state = MapEdits.merged([yours], now: Self.day + 20)
        let hidden = MapHidden([Self.work(5150), Self.node(4100)])

        let shown = WorkMap(board, missions: missions, state: state, hidden: hidden)
        #expect(shown.showsDone && shown.doneCount == 3 && shown.workItemsLeftOut.isEmpty)
        #expect(shown.bands.count == 3)
        #expect(shown.hidden.map(Self.name) == ["!4100", "5150"])

        let map = WorkMap(board, missions: missions, state: state, hidden: hidden, showsDone: false)
        #expect(!map.showsDone && map.doneCount == 3)
        // Task 5106, done, and Task 5107, whose merged !4100 stands for it: + Task says Done would show them.
        #expect(map.workItemsLeftOut == [Steps.task(5106), Steps.task(5107)])
        #expect(map.bands.map(\.lane.kind) == [.mission(Self.chain.key), .notInAMission])
        let chain = try #require(map.bands.first?.graph)
        #expect(chain.columns == [.wave(0), .wave(1), .wave(2)])
        #expect(Self.places(chain) == ["!4101 0,0", "!4102 1,0", "!4103 2,0"])
        #expect(Self.lines(chain, in: map) == ["!4101 > !4102", "!4102 > !4103"])
        let rest = try #require(map.bands.last)
        #expect(rest.graph == nil && rest.count == 0 && rest.hidden.map(Self.name) == ["5150"])
        #expect(map.groups.map { $0.items.map(Self.name) } == [["!4101", "!4102", "!4103"]])
        #expect(map.loose.isEmpty && map.columns == [.wave(0), .wave(1), .wave(2)])
        #expect(map.hidden.map(Self.name) == ["5150"])

        let defaults = MemorySettings()
        #expect(MapDoneWork.load(from: defaults))
        MapDoneWork.save(false, to: defaults)
        #expect(defaults.object(forKey: "order.map.hidesDone") as? Bool == true)
        #expect(!MapDoneWork.load(from: defaults))
        MapDoneWork.save(true, to: defaults)
        #expect(defaults.object(forKey: "order.map.hidesDone") == nil)
    }

    /// Azure DevOps' dependencies are lines too, solid, of a work item a pull request's card names as of that card; taken away
    /// on the Map, one goes from the Map only.
    @Test func azureDevOpsDependenciesDrawLinesOntoTheirCards() throws {
        let board = Steps.board(Self.open([4091]))
            .withWork([Steps.work(5112, .inProgress, linked: [Steps.linked(4091)]), Steps.work(5150, .toDo)], missions: [], stories: [])
        let linked: Set<MapEdits.Line> = [.init(Self.work(5112), Self.work(5150))]
        let map = WorkMap(board, missions: [], azureDevOps: linked)
        let group = try #require(map.groups.first)
        #expect(Self.lines(group.graph, in: map) == ["!4091 > 5150"])
        #expect(group.graph?.lines.first?.style == .azureDevOps)
        #expect(map.waitsFor(Self.work(5150)).map { $0.link } == [.azureDevOps])

        let off = MapEdits.merged([Self.edits(off: [(Self.node(4091), Self.work(5150))], by: .you)], now: Self.day)
        let taken = WorkMap(board, missions: [], state: off, azureDevOps: linked)
        #expect(taken.groups.isEmpty && taken.loose.count == 2)
    }

    /// A line stands, in Azure DevOps, for dependencies between the work items its ends stand for: a work item's card, itself;
    /// a pull request's card, the work items of yours it names, each of them, but where the line was said of one of them,
    /// that one only; never a step, a dotted line, or work items of two organizations. Link All takes the lines drawn that
    /// Azure DevOps doesn't link yet.
    @Test func aLineLinksTheWorkItemsItsEndsStandFor() throws {
        let work = [
            Steps.work(5110, .inProgress, linked: [Steps.linked(4091)]), Steps.work(5112, .inProgress, linked: [Steps.linked(4091)]),
            Steps.work(5160, .inProgress, linked: [Steps.linked(4102)]), Steps.work(5150, .toDo), Steps.work(5151, .toDo),
        ]
        let board = Steps.board(Self.open([4091, 4102])).withWork(work, missions: [], stories: [])
        let said: [(MapNodeID, MapNodeID)] = [
            (Self.node(4091), Self.node(4102)), (Self.work(5112), Self.work(5150)), (Self.work(5150), .step(Self.id(1))),
            (Self.work(5150), Self.work(5151)),
        ]
        let state = MapEdits.merged([Self.edits(steps: [(1, "API tests")], lines: said, by: .you)], now: Self.day)
        let map = WorkMap(board, missions: [], state: state, azureDevOps: [.init(Self.work(5150), Self.work(5151))])
        func line(_ before: MapNodeID, _ after: MapNodeID) -> WorkMapLine {
            WorkMapLine(before: before, after: after, style: .said(.you))
        }
        #expect(map.workItems(of: Self.node(4091)) == [Steps.task(5110), Steps.task(5112)])
        #expect(map.links(of: line(Self.node(4091), Self.node(4102)))?.missing == [
            .init(Self.work(5110), Self.work(5160)), .init(Self.work(5112), Self.work(5160)),
        ])
        #expect(map.links(of: line(Self.node(4091), Self.work(5150)))?.pairs == [.init(Self.work(5112), Self.work(5150))])
        let linked = try #require(map.links(of: line(Self.work(5150), Self.work(5151))))
        #expect(linked.isLinked && linked.missing.isEmpty)
        #expect(map.links(of: line(Self.work(5150), .step(Self.id(1)))) == nil)
        #expect(map.links(of: WorkMapLine(before: Self.node(4091), after: Self.node(4102), style: .through([Self.work(5150)]))) == nil)
        let elsewhere = MapNodeID.card(.workItem(organization: "fabrikam", id: 7))
        #expect(map.links(of: line(elsewhere, Self.work(5150))) == nil)
        let all = map.unlinked.map { Self.label($0.line.before, in: map) + " > " + Self.label($0.line.after, in: map) }
        #expect(all.sorted() == ["!4091 > !4102", "!4091 > 5150"])
        let words = OrderText.dependencies([.init(Self.work(5112), Self.work(5160)), .init(Self.work(5110), Self.work(5160))]) {
            "Task " + ($0.ref?.id ?? "")
        }
        #expect(words == ["Task 5160 waits for Task 5110 and Task 5112"])
    }

    /// Others' work, once you show it: the open work items the Board doesn't have that yours wait for, and what those wait
    /// for, and those that wait right after yours, in the band of what they're joined to; not one that's done, one that
    /// waits on those, or one joined to nothing of yours. Without it, yours waits a wave on for the open one it doesn't show.
    @Test func othersWorkShowsWhatYoursWaitsForAndWhatWaitsRightAfterIt() throws {
        let board = Steps.board([:]).withWork([Steps.work(5150, .toDo)], missions: [], stories: [])
        func line(_ before: Int, _ after: Int) -> MapEdits.Line { .init(Self.work(before), Self.work(after)) }
        let linked: Set<MapEdits.Line> = [
            line(5201, 5150), line(5202, 5201), line(5203, 5150), line(5150, 5204), line(5204, 5205), line(5206, 5207),
        ]
        let done: [Int: Bool] = [5201: false, 5202: false, 5203: true, 5204: false, 5205: false, 5206: false, 5207: false]
        let work = { (ref: ItemRef) -> MapWorkItem? in
            ref.number.flatMap { done[$0] }.map { MapWorkItem(ref: ref, isDone: $0) }
        }
        let mine = WorkMap(board, missions: [], azureDevOps: linked, work: work)
        #expect(mine.everything.map(Self.name) == ["5150"])
        #expect(mine.bands.first?.graph?.columns == [.wave(1)])

        let map = WorkMap(board, missions: [], azureDevOps: linked, work: work, showsOthers: true)
        let band = try #require(map.bands.first)
        #expect(map.bands.count == 1)
        #expect(Self.places(band.graph) == ["5202 0,0", "5201 1,0", "5150 2,0", "5204 3,0"])
        #expect(Self.lines(band.graph, in: map) == ["5202 > 5201", "5201 > 5150", "5150 > 5204"])
        #expect(map.item(Self.work(5201))?.workItem == MapWorkItem(ref: Steps.task(5201)))
        #expect(map.band(of: Self.work(5202)) == .notInAMission)
    }

    /// A work item you added shows whatever Others' work says, in the band you added it in; one the page doesn't know yet by
    /// its reference alone; and one the Board has, or a pull request's card stands for, not again.
    @Test func aWorkItemYouAddedShowsInTheBandYouAddedItIn() {
        var checkout = Steps.mission([Steps.step(4101, .next, place: 1)])
        checkout.story = MissionStory(ref: Steps.task(5001))
        let work = [Steps.work(5103, .inProgress, story: 5001, linked: [Steps.linked(4101)]), Steps.work(5150, .toDo)]
        let board = Steps.board(Self.open([4101]), missions: [checkout])
            .withWork(work, missions: [checkout], stories: [Steps.task(5001)])
        var yours = MapEdits()
        yours.addItem(Steps.task(5210), home: LaneOrderKey(.mission(checkout.key), missions: [checkout]), by: .you, at: Self.day)
        yours.addItem(Steps.task(5299), home: nil, by: .you, at: Self.day + 1)
        yours.addItem(Steps.task(5150), home: nil, by: .you, at: Self.day + 2)
        yours.addItem(Steps.task(5103), home: nil, by: .you, at: Self.day + 3)
        let known = { (ref: ItemRef) -> MapWorkItem? in ref == Steps.task(5210) ? MapWorkItem(ref: ref) : nil }
        let map = WorkMap(board, missions: [checkout], state: MapEdits.merged([yours], now: Self.day), work: known)
        #expect(map.band(of: Self.work(5210)) == .mission(checkout.key))
        #expect(map.item(Self.work(5210))?.workItem == MapWorkItem(ref: Steps.task(5210), isAdded: true))
        #expect(map.item(Self.work(5299))?.workItem == MapWorkItem(ref: Steps.task(5299), isAdded: true, isKnown: false))
        #expect(map.band(of: Self.work(5299)) == .notInAMission)
        #expect(map.everything.filter { $0.workItem != nil }.map(Self.name) == ["5210", "5299"])
        // + Task offers none the Map has, on its own or as its pull requests' cards: not 5103, whose card is !4101's.
        #expect(map.workItemsOnMap == [Steps.task(5103), Steps.task(5150), Steps.task(5210), Steps.task(5299)])
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

    /// At a Glance shows every kind until you hide one, and keeps only the kinds you hid, by name, so that a kind a later
    /// version adds shows; a node says those of the kinds that show, in their order.
    @Test func atAGlanceShowsEveryKindUntilYouHideOne() {
        let defaults = MemorySettings()
        let all = MapGlances.load(from: defaults)
        #expect(MapGlance.Kind.allCases.allSatisfy(all.shows))
        let node = [MapGlance(.conflicts, "Merge conflicts"), MapGlance(.comments, "2 to resolve", count: 2), MapGlance(.draft, "Draft")]
        #expect(all.shown(node) == node)

        let hidden = all.setting(.draft, shown: false).setting(.comments, shown: false).setting(.sprint, shown: false)
        #expect(hidden.shown(node).map(\.kind) == [.conflicts])
        hidden.save(to: defaults)
        #expect(defaults.object(forKey: "order.map.hiddenGlances") as? [String] == ["comments", "draft", "sprint"])
        #expect(MapGlances.load(from: defaults) == hidden)

        defaults.set(["draft", "a later kind"], forKey: MapGlances.defaultsKey)
        #expect(MapGlances.load(from: defaults) == MapGlances(hidden: [.draft]))
        MapGlances.load(from: defaults).setting(.draft, shown: true).save(to: defaults)
        #expect(defaults.object(forKey: MapGlances.defaultsKey) == nil)
    }

    /// Parents: the parent Azure DevOps gives each work item, and that one's, up the chain, is a node of its own, a wave after
    /// what's part of it, which it waits for, joined by a lighter line that stands for no dependency; in the band of what's
    /// part of it. A chain ends at a parent the page doesn't know, and at `mostParents` of them; a line goes through one you
    /// hid to the next one up.
    @Test func parentsAreNodesAfterWhatsPartOfThemUpTheirChains() throws {
        let board = Steps.board([:]).withWork([Steps.work(5150, .toDo), Steps.work(5151, .toDo)], missions: [], stories: [])
        let parents = [
            Steps.task(5150): Steps.task(5180), Steps.task(5151): Steps.task(5180), Steps.task(5180): Steps.task(5190),
            Steps.task(5190): Steps.task(5195), Steps.task(5195): Steps.task(5199),
        ]
        let known: Set<Int> = [5180, 5190, 5195]
        let work = { (ref: ItemRef) -> MapWorkItem? in ref.number.map(known.contains) == true ? MapWorkItem(ref: ref) : nil }
        let map = WorkMap(board, missions: [], work: work, parents: parents)
        let graph = try #require(map.bands.first?.graph)
        #expect(map.hasParents && map.showsParents)
        #expect(graph.columns == [.wave(0), .wave(1), .wave(2), .wave(3)])
        #expect(Self.places(graph) == ["5150 0,0", "5151 0,1", "5180 1,0", "5190 2,0", "5195 3,0"])
        #expect(Self.lines(graph, in: map) == ["5150 > 5180", "5151 > 5180", "5180 > 5190", "5190 > 5195"])
        #expect(graph.lines.allSatisfy { $0.style == .parent })
        #expect(map.item(Self.work(5180))?.workItem == MapWorkItem(ref: Steps.task(5180), isParent: true))
        #expect(map.item(Self.work(5199)) == nil)
        #expect(map.band(of: Self.work(5195)) == .notInAMission)
        #expect(map.waitsFor(Self.work(5180)).isEmpty)
        #expect(map.links(of: WorkMapLine(before: Self.work(5150), after: Self.work(5180), style: .parent)) == nil)
        #expect(map.groups.map { $0.items.map(Self.name) } == [["5150", "5151", "5180", "5190", "5195"]])
        #expect(map.loose.isEmpty)

        let hidden = WorkMap(board, missions: [], hidden: MapHidden([Self.work(5180)]), work: work, parents: parents)
        let through = try #require(hidden.bands.first?.graph)
        #expect(Self.places(through) == ["5150 0,0", "5151 0,1", "5190 1,0", "5195 2,0"])
        #expect(Self.lines(through, in: hidden) == ["5150 > 5190", "5151 > 5190", "5190 > 5195"])
        #expect(hidden.hidden.map(Self.name) == ["5180"])

        var chain = [Steps.task(5150): Steps.task(6001)]
        for id in 6001..<6040 {
            chain[Steps.task(id)] = Steps.task(id + 1)
        }
        let long = WorkMap(board, missions: [], work: { ref in MapWorkItem(ref: ref) }, parents: chain)
        #expect(long.everything.compactMap(\.workItem).count == WorkMap.mostParents)
        #expect(long.item(Self.work(6030)) != nil && long.item(Self.work(6031)) == nil)
    }

    /// Parents off leaves them off the Map, lines and all, though it still knows Azure DevOps gives some, which is what the
    /// switch is for; none it knows, or only one the page doesn't, and there's nothing to switch. On until you turn it off,
    /// remembered.
    @Test func parentsOffLeavesThemOffTheMap() {
        let board = Steps.board([:]).withWork([Steps.work(5150, .toDo), Steps.work(5151, .toDo)], missions: [], stories: [])
        let parents = [Steps.task(5150): Steps.task(5180), Steps.task(5151): Steps.task(5180)]
        let work = { (ref: ItemRef) -> MapWorkItem? in ref == Steps.task(5180) ? MapWorkItem(ref: ref) : nil }
        let off = WorkMap(board, missions: [], work: work, parents: parents, showsParents: false)
        #expect(off.hasParents && !off.showsParents)
        #expect(Self.places(off.bands.first?.graph) == ["5150 0,0", "5151 0,1"])
        #expect(off.bands.first?.graph?.lines.isEmpty == true)
        #expect(off.item(Self.work(5180)) == nil)
        #expect(off.groups.isEmpty && off.loose.map(Self.name) == ["5150", "5151"])
        #expect(!WorkMap(board, missions: []).hasParents)
        #expect(!WorkMap(board, missions: [], work: work, parents: [Steps.task(5150): Steps.task(5199)]).hasParents)

        let defaults = MemorySettings()
        #expect(MapParents.load(from: defaults))
        MapParents.save(false, to: defaults)
        #expect(defaults.object(forKey: "order.map.hidesParents") as? Bool == true)
        #expect(!MapParents.load(from: defaults))
        MapParents.save(true, to: defaults)
        #expect(defaults.object(forKey: "order.map.hidesParents") == nil)
    }

    /// A parent the Board has a card for is that card; one a pull request's card names, or Show Links links to it, is that
    /// card, which is never part of itself; a parent of its own goes in the band of what's part of it. A dependency says
    /// more than a parent: where Azure DevOps links the two, either way, its line is the only one.
    @Test func aParentIsItsCardOrItsPullRequestsAndADependencySaysMore() throws {
        let checkout = Steps.mission([Steps.step(4091, .next, place: 1)])
        let work = [Steps.work(5112, .inProgress, linked: [Steps.linked(4091)]), Steps.work(5150, .toDo), Steps.work(5151, .toDo)]
        let board = Steps.board(Self.open([4091]), missions: [checkout]).withWork(work, missions: [checkout], stories: [])
        let parents = [Steps.task(5112): Steps.task(5180), Steps.task(5180): Steps.task(5190), Steps.task(5150): Steps.task(5151)]
        let known = { (ref: ItemRef) -> MapWorkItem? in ref == Steps.task(5190) ? MapWorkItem(ref: ref) : nil }
        let linked = [Self.pr(4091): [Steps.task(5180)]]
        let map = WorkMap(board, missions: [checkout], linked: linked, work: known, parents: parents)
        #expect(map.bands.map(\.lane.kind) == [.mission(checkout.key), .notInAMission])
        #expect(Self.lines(map.bands.first?.graph, in: map) == ["!4091 > 5190"])
        #expect(Self.lines(map.bands.last?.graph, in: map) == ["5150 > 5151"])
        #expect(Self.places(map.bands.last?.graph) == ["5150 0,0", "5151 1,0"])
        #expect(map.item(Self.work(5180)) == nil)
        #expect(map.band(of: Self.work(5190)) == .mission(checkout.key))

        let linking = WorkMap(board, missions: [checkout], azureDevOps: [.init(Self.work(5150), Self.work(5151))], parents: parents)
        #expect(linking.bands.last?.graph?.lines.map(\.style) == [.azureDevOps])
        #expect(linking.bands.last?.graph?.partOf == [Self.work(5150): [Self.work(5151)]])
        #expect(linking.groups.contains { $0.graph?.partOf == [Self.work(5150): [Self.work(5151)]] })
        let waiting = WorkMap(board, missions: [checkout], azureDevOps: [.init(Self.work(5151), Self.work(5150))], parents: parents)
        let rest = try #require(waiting.bands.last?.graph)
        #expect(Self.lines(rest, in: waiting) == ["5151 > 5150"])
        #expect(rest.lines.map(\.style) == [.azureDevOps])
        #expect(rest.partOf == [Self.work(5150): [Self.work(5151)]])
        #expect(Self.places(rest) == ["5151 0,0", "5150 1,0"])
    }

    /// A parent that what's part of it waits for, through others, has no line from it, which would make a loop where none of
    /// them could go first: the dependencies keep their waves, and it's still part of it. So up a chain of parents too.
    @Test func aParentItsWorkWaitsForThroughOthersMakesNoLoop() throws {
        let work = [Steps.work(5150, .toDo), Steps.work(5151, .toDo), Steps.work(5152, .toDo)]
        let board = Steps.board([:]).withWork(work, missions: [], stories: [])
        let first: Set = [MapEdits.Line(Self.work(5150), Self.work(5151)), MapEdits.Line(Self.work(5151), Self.work(5152))]
        let parents = [Steps.task(5151): Steps.task(5150), Steps.task(5152): Steps.task(5150)]
        let map = WorkMap(board, missions: [], azureDevOps: first, parents: parents)
        let graph = try #require(map.bands.first?.graph)
        #expect(Self.lines(graph, in: map) == ["5150 > 5151", "5151 > 5152"])
        #expect(Self.places(graph) == ["5150 0,0", "5151 1,0", "5152 2,0"])
        #expect(graph.partOf == [Self.work(5151): [Self.work(5150)], Self.work(5152): [Self.work(5150)]])

        let chain = [Steps.task(5152): Steps.task(5151), Steps.task(5151): Steps.task(5150)]
        let up = WorkMap(board, missions: [], azureDevOps: [MapEdits.Line(Self.work(5150), Self.work(5152))], parents: chain)
        let climbing = try #require(up.bands.first?.graph)
        #expect(Self.lines(climbing, in: up) == ["5150 > 5152", "5151 > 5150"])
        #expect(Self.places(climbing) == ["5151 0,0", "5150 1,0", "5152 2,0"])
        #expect(climbing.partOf == [Self.work(5151): [Self.work(5150)], Self.work(5152): [Self.work(5151)]])
    }

    /// Pull requests' cards that each name a task and its story both stand for the story: neither is part of the other, nor
    /// waits for it. One that names only the task is part of the one that names the story.
    @Test func cardsThatEachNameATaskAndItsStoryArentPartOfEachOther() {
        let board = Steps.board(Self.open([4091, 4092]))
        let both = [Steps.task(5112), Steps.task(5180)]
        let parents = [Steps.task(5112): Steps.task(5180)]
        let map = WorkMap(board, missions: [], linked: [Self.pr(4091): both, Self.pr(4092): both], parents: parents)
        #expect(Self.places(map.bands.first?.graph) == ["!4091 0,0", "!4092 0,1"])
        #expect(map.bands.first?.graph?.lines.isEmpty == true)
        #expect(map.groups.isEmpty)

        let one = WorkMap(board, missions: [], linked: [Self.pr(4091): both, Self.pr(4092): [Steps.task(5112)]], parents: parents)
        #expect(Self.lines(one.bands.first?.graph, in: one) == ["!4092 > !4091"])
        #expect(one.bands.first?.graph?.partOf == [Self.node(4092): [Self.node(4091)]])
    }

    /// Others' work counts only others' work items: not a parent of yours, nor one you added.
    @Test func othersWorkCountsNeitherParentsNorWhatYouAdded() {
        let board = Steps.board([:]).withWork([Steps.work(5150, .toDo)], missions: [], stories: [])
        var yours = MapEdits()
        yours.addItem(Steps.task(5210), home: nil, by: .you, at: Self.day)
        let map = WorkMap(
            board, missions: [], state: MapEdits.merged([yours], now: Self.day), azureDevOps: [.init(Self.work(5201), Self.work(5150))],
            work: { MapWorkItem(ref: $0) }, showsOthers: true, parents: [Steps.task(5150): Steps.task(5180)]
        )
        #expect(Set(map.everything.map(Self.name)) == ["5150", "5180", "5201", "5210"])
        #expect(map.othersCount == 1)
    }

    /// An open story whose tasks are all done still has its node, now, after them in Done; with Done off, alone.
    @Test func anOpenParentOfDoneWorkStaysOnTheMap() {
        let board = Steps.board([:]).withWork([Steps.work(5150, .completed), Steps.work(5151, .completed)], missions: [], stories: [])
        let parents = [Steps.task(5150): Steps.task(5180), Steps.task(5151): Steps.task(5180)]
        let work = { (ref: ItemRef) -> MapWorkItem? in ref == Steps.task(5180) ? MapWorkItem(ref: ref) : nil }
        let map = WorkMap(board, missions: [], work: work, parents: parents)
        let graph = map.bands.first?.graph
        #expect(graph?.columns == [.done, .wave(0)])
        #expect(Self.places(graph) == ["5150 0,0", "5151 0,1", "5180 1,0"])
        #expect(Self.lines(graph, in: map) == ["5150 > 5180", "5151 > 5180"])
        let open = WorkMap(board, missions: [], work: work, showsDone: false, parents: parents)
        #expect(Self.places(open.bands.first?.graph) == ["5180 0,0"])
    }

    /// Work items Azure DevOps links as Related sit together in a box, in rows of their own, either way round, with those
    /// related to them through others; one related only to what the Map doesn't have is in none. All groups them, as it
    /// groups what lines join.
    @Test func relatedWorkSitsTogetherInABox() throws {
        let work = [Steps.work(5150, .toDo), Steps.work(5151, .toDo), Steps.work(5152, .toDo), Steps.work(5153, .toDo)]
        let board = Steps.board([:]).withWork(work, missions: [], stories: [])
        let related: Set<MapRelated> = [
            MapRelated(Steps.task(5152), Steps.task(5150)), MapRelated(Steps.task(5153), Steps.task(5999)),
        ]
        #expect(MapRelated(Steps.task(5152), Steps.task(5150)) == MapRelated(Steps.task(5150), Steps.task(5152)))
        let map = WorkMap(board, missions: [], related: related)
        let graph = try #require(map.bands.first?.graph)
        #expect(Self.places(graph) == ["5150 0,0", "5152 0,1", "5151 0,2", "5153 0,3"])
        #expect(graph.boxes == [WorkMapBox(members: [Self.work(5150), Self.work(5152)], columns: 0...0, rows: 0...1)])
        #expect(map.groups.map { $0.items.map(Self.name) } == [["5150", "5152"]])
        #expect(map.groups.first?.graph?.boxes.count == 1)
        #expect(map.loose.map(Self.name) == ["5151", "5153"])
    }

    /// A box goes across the columns of what's in it, keeping its rows to itself in each, which a fold keeps too; a work item
    /// a pull request's card names is related as that card, never to itself. By Mission, a box keeps to a band; All boxes
    /// them across missions.
    @Test func aBoxSpansItsColumnsAndKeepsToItsBand() throws {
        let work = [
            Steps.work(5110, .inProgress, linked: [Steps.linked(4091)]), Steps.work(5112, .inProgress, linked: [Steps.linked(4091)]),
            Steps.work(5160, .toDo), Steps.work(5161, .toDo), Steps.work(5170, .toDo),
        ]
        let board = Steps.board(Self.open([4091])).withWork(work, missions: [], stories: [])
        let related: Set<MapRelated> = [
            MapRelated(Steps.task(5110), Steps.task(5112)), MapRelated(Steps.task(5112), Steps.task(5160)),
            MapRelated(Steps.task(5160), Steps.task(5161)),
        ]
        let map = WorkMap(board, missions: [], azureDevOps: [.init(Self.work(5110), Self.work(5160))], related: related)
        let graph = try #require(map.bands.first?.graph)
        #expect(Self.places(graph) == ["!4091 0,0", "5161 0,1", "5170 0,2", "5160 1,0"])
        #expect(graph.boxes == [WorkMapBox(members: [Self.node(4091), Self.work(5161), Self.work(5160)], columns: 0...1, rows: 0...1)])
        #expect(graph.rows(in: 1..<2) == [0, 1])
        #expect(map.groups.map { $0.items.map(Self.name) } == [["!4091", "5160", "5161"]])

        let retries = Steps.mission([Steps.step(4101, .next, place: 1)])
        let coupons = Steps.mission([Steps.step(4091, .next, place: 1)])
        let linked = [Steps.work(5110, .inProgress, linked: [Steps.linked(4091)]), Steps.work(5160, .inProgress, linked: [Steps.linked(4101)])]
        let missions = Steps.board(Self.open([4101, 4091]), missions: [retries, coupons])
            .withWork(linked, missions: [retries, coupons], stories: [])
        let apart = WorkMap(
            missions, missions: [retries, coupons], azureDevOps: [.init(Self.work(5110), Self.work(5160))],
            related: [MapRelated(Steps.task(5160), Steps.task(5110))]
        )
        #expect(apart.bands.count == 2 && apart.bands.allSatisfy { $0.graph?.boxes.isEmpty == true })
        #expect(apart.groups.first?.graph?.boxes == [WorkMapBox(members: [Self.node(4091), Self.node(4101)], columns: 0...1, rows: 0...0)])
    }

    /// A box keeps its rows from its first column on, so a card that ties with one of its cards goes below it, and what comes
    /// after them swaps to cross no lines; then each rises as far as it can, so that a chain through a box runs straight
    /// along its row, with no row left empty above it.
    @Test func aChainThroughABoxRunsStraightAlongItsRow() throws {
        let work = (5201...5206).map { Steps.work($0, .toDo) }
        let board = Steps.board([:]).withWork(work, missions: [], stories: [])
        let lines = [(5201, 5202), (5201, 5203), (5202, 5205), (5203, 5204), (5205, 5206)]
        let map = WorkMap(
            board, missions: [], azureDevOps: Set(lines.map { MapEdits.Line(Self.work($0.0), Self.work($0.1)) }),
            related: [MapRelated(Steps.task(5201), Steps.task(5202))]
        )
        let graph = try #require(map.bands.first?.graph)
        #expect(Self.places(graph) == ["5201 0,0", "5202 1,0", "5203 1,1", "5205 2,0", "5204 2,1", "5206 3,0"])
        #expect(graph.boxes == [WorkMapBox(members: [Self.work(5201), Self.work(5202)], columns: 0...1, rows: 0...0)])
        #expect(graph.rows == 2)
        #expect(graph.crossings == 0)
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

    /// A step done two weeks ago goes then, as the Map stops showing it, though its name changed since: each side forgets
    /// it by when it was marked done, not by its last change.
    @Test func aStepDoneTwoWeeksAgoGoesThoughRenamedSince() {
        let step = Map.id(1)
        var yours = MapEdits()
        yours.addStep(step, name: "API tests", home: nil, by: .you, at: Map.day - 30 * 86_400)
        yours.setDone(step, true, by: .you, at: Map.day - 20 * 86_400)
        var told = MapEdits()
        told.rename(step, to: "API and contract tests", by: .session(Map.session), at: Map.day - 5 * 86_400)
        #expect(MapEdits.merged([yours, told], now: Map.day).steps.isEmpty)
        let prunedYours = yours.prune(with: told, now: Map.day)
        #expect(prunedYours && yours.steps.isEmpty)
        let prunedTold = told.prune(with: yours, now: Map.day)
        #expect(prunedTold && told.steps.isEmpty)
    }

    /// Past the most steps a side keeps, those it added that changed longest ago go, but never what it said of the other
    /// side's: a step a session added that you deleted doesn't come back.
    @Test func aStepYouDeletedStaysDeletedPastTheMostStepsYouKeep() {
        let step = Map.id(1)
        var told = MapEdits()
        told.addStep(step, name: "Load test", home: nil, by: .session(Map.session), at: Map.day)
        var yours = MapEdits()
        yours.delete(step, by: .you, at: Map.day + 1)
        for number in 0...MapEdits.mostSteps {
            yours.addStep(Map.id(1_000 + number), name: "Step \(number)", home: nil, by: .you, at: Map.day + 2 + Double(number))
        }
        #expect(yours.steps[step]?.deletedAt != nil)
        #expect(yours.steps[Map.id(1_000)] == nil && yours.steps.count == MapEdits.mostSteps + 1)
        let state = MapEdits.merged([yours, told], now: Map.day + 1_000)
        #expect(!state.steps.contains { $0.id == step } && state.steps.count == MapEdits.mostSteps)
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

    /// The work items you add to the Map are kept by reference, with where and when, the latest `mostItems` of them: taken off
    /// with the lines you drew to them, and forgotten as Azure DevOps goes. Others' work stays off until you turn it on.
    @Test func workItemsYouAddAreKeptByReference() {
        var edits = MapEdits()
        let story = LaneOrderKey.story(Steps.task(5101))
        edits.addItem(Steps.task(5210), home: story, by: .you, at: Map.day)
        edits.addItem(Steps.task(5210), home: nil, by: .you, at: Map.day + 5)
        edits.addItem(Map.pr(4101), home: nil, by: .you, at: Map.day)
        edits.set(.init(Map.work(5210), Map.work(5150)), on: true, by: .you, at: Map.day + 1)
        let defaults = MemorySettings()
        edits.save(to: defaults, key: MapEdits.yoursKey)
        let loaded = MapEdits.load(from: defaults, key: MapEdits.yoursKey)
        #expect(loaded == edits)
        #expect(loaded.items == [Steps.task(5210): MapEdits.ItemChange(at: Map.day, by: .you, home: story)])
        #expect(MapEdits.merged([MapEdits(), loaded], now: Map.day).items.keys.sorted() == [Steps.task(5210)])
        edits.removeItem(Steps.task(5210))
        #expect(edits.isEmpty)

        var many = MapEdits()
        for number in 0...MapEdits.mostItems {
            many.addItem(Steps.task(6000 + number), home: nil, by: .you, at: Map.day + Double(number))
        }
        #expect(many.items.count == MapEdits.mostItems && many.items[Steps.task(6000)] == nil)
        let forgot = many.forget([.pullRequest])
        #expect(forgot && many.isEmpty)

        #expect(!MapOthersWork.load(from: defaults))
        MapOthersWork.save(true, to: defaults)
        #expect(MapOthersWork.load(from: defaults))
        MapOthersWork.save(false, to: defaults)
        #expect(defaults.object(forKey: MapOthersWork.defaultsKey) == nil)
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
