import Foundation
import Testing
@testable import BriefBarCore

/// My Work's Map: the Board's cards as graphs, by mission or all together, in waves, with the lines between them, through
/// what it doesn't show; and the cards you hid.
@Suite struct WorkMapTests {
    private typealias Steps = NextStepsTests

    static func pr(_ number: Int) -> ItemRef { Steps.pr(number) }

    /// Where each card of a graph is: its number, column and row, as VoiceOver reads them.
    static func places(_ graph: WorkMapGraph?) -> [String] {
        (graph?.nodes ?? []).map { "\($0.item.ref.shortOrderLabel) \($0.column),\($0.row)" }
    }

    static func waits(on numbers: [Int]) -> OrderStanding {
        .waiting(open: numbers.map(pr), unknown: [])
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
            WorkMapLine(before: Self.pr(4100), after: Self.pr(4101), style: .stacked),
            WorkMapLine(before: Self.pr(4101), after: Self.pr(4102), style: .order),
            WorkMapLine(before: Self.pr(4102), after: Self.pr(4103), style: .order),
        ])
        #expect(graph.rows == 1)
        #expect(graph.crossings == 0)
    }

    /// A card you hide leaves its band, which lists it, and a dotted line goes through it, which says so; what comes after it
    /// comes a wave after what's drawn before it, but no sooner than one wave on, as it still waits for the hidden one.
    @Test func aLineGoesDottedThroughACardYouHid() throws {
        let hidden = MapHidden([Self.pr(4102)])
        let map = WorkMap(Steps.board(Self.chainStages, missions: [Self.chain]), missions: [Self.chain], hidden: hidden)
        let band = try #require(map.bands.first)
        let graph = try #require(band.graph)
        #expect(band.hidden.map(\.ref) == [Self.pr(4102)])
        #expect(band.count == 3)
        #expect(graph.columns == [.done, .wave(0), .wave(1)])
        #expect(Self.places(graph) == ["!4100 0,0", "!4101 1,0", "!4103 2,0"])
        #expect(graph.lines.last == WorkMapLine(before: Self.pr(4101), after: Self.pr(4103), style: .through([Self.pr(4102)])))
        #expect(OrderText.through([Self.pr(4102)], hidden: Set(hidden.refs)) == "Through !4102, which you hid")
        #expect(OrderText.through([Self.pr(4102), Self.pr(4105)], hidden: []) == "Through !4102 and !4105")
        #expect(OrderText.through([Self.pr(4102), Self.pr(4105)], hidden: [Self.pr(4105)])
            == "Through !4102 and !4105, one of which you hid")
        // All, too: the hidden card is listed, and the line goes through it.
        #expect(map.hidden.map(\.ref) == [Self.pr(4102)])
        #expect(map.groups.first?.graph?.lines.last?.style == .through([Self.pr(4102)]))
    }

    /// One that waits for a pull request in another mission goes a wave on in its band, with no line there; All joins them.
    @Test func aCardThatWaitsForAnotherMissionsGoesAWaveOnAndAllJoinsThem() throws {
        let first = Steps.mission([Steps.step(4101, .next, place: 1)])
        let second = Steps.mission([Steps.step(4201, Self.waits(on: [4101]), place: 1, after: [4101])])
        let stages: [Int: StageReading] = [
            4101: Steps.reading(.inProgress, .draft, at: 1),
            4201: Steps.reading(.waits, .waitsFor([Self.pr(4101)], words: "After !4101"), at: 2),
        ]
        let map = WorkMap(Steps.board(stages, missions: [first, second]), missions: [first, second])
        #expect(map.bands.map { Self.places($0.graph) } == [["!4101 0,0"], ["!4201 0,0"]])
        #expect(map.bands.last?.graph?.columns == [.wave(1)])
        #expect(map.bands.last?.graph?.lines == [])

        let group = try #require(map.groups.first)
        #expect(map.groups.count == 1)
        #expect(group.lanes == [.mission(first.key), .mission(second.key)])
        #expect(Self.places(group.graph) == ["!4101 0,0", "!4201 1,0"])
        #expect(group.graph?.lines == [WorkMapLine(before: Self.pr(4101), after: Self.pr(4201), style: .order)])
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

        // All: the order's cards are a graph; the rest no line joins.
        #expect(map.groups.map { $0.items.map(\.ref) } == [[Self.pr(4101), Self.pr(4102)]])
        #expect(map.loose.map(\.ref) == [5103, 5104, 5106].map(Steps.task))
    }

    /// Cards are ordered in each column to cross as few lines as they can, and a line that skips a column keeps a row of it to
    /// itself, so that no card sits on it.
    @Test func linesCrossAsLittleAsTheyCanAndKeepARowOfEachColumnTheySkip() throws {
        let crossed = Steps.mission([
            Steps.step(4101, .next, place: 1), Steps.step(4102, .next, place: 2),
            Steps.step(4103, Self.waits(on: [4102]), place: 3, after: [4102]), Steps.step(4104, Self.waits(on: [4101]), place: 4, after: [4101]),
        ])
        let stages = Dictionary(uniqueKeysWithValues: [4101, 4102, 4103, 4104].map { ($0, Steps.reading(.inProgress, .draft, at: 1)) })
        let graph = try #require(WorkMap(Steps.board(stages, missions: [crossed]), missions: [crossed]).bands.first?.graph)
        #expect(Self.places(graph) == ["!4101 0,0", "!4102 0,1", "!4104 1,0", "!4103 1,1"])
        #expect(graph.crossings == 0)

        let skipping = Steps.mission([
            Steps.step(4100, .merged, status: .merged, place: 1), Steps.step(4101, .next, place: 2),
            Steps.step(4102, Self.waits(on: [4101]), place: 3, after: [4100, 4101]),
        ])
        let skipped = try #require(WorkMap(Steps.board(Self.chainStages, missions: [skipping]), missions: [skipping]).bands.first?.graph)
        #expect(Self.places(skipped) == ["!4100 0,0", "!4101 1,0", "!4102 2,0"])
        #expect(skipped.lines.first { $0.before == Self.pr(4100) }?.rows == [1])
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
        #expect(graph.lines.contains(WorkMapLine(before: Self.pr(4101), after: Self.pr(4103), style: .order)))
    }

    /// Cards in a loop of lines, where none can go first, share a wave, and what comes after the loop comes a wave after it,
    /// with its line, wherever the Board puts it.
    @Test func aLoopSharesAWaveAndWhatComesAfterItFollows() throws {
        let mission = Steps.mission([
            Steps.step(4203, Self.waits(on: [4202]), place: 1, after: [4202]),
            Steps.step(4201, Self.waits(on: [4202]), place: 2, after: [4202]),
            Steps.step(4202, Self.waits(on: [4201]), place: 3, after: [4201]),
        ])
        let stages = Dictionary(uniqueKeysWithValues: [4201, 4202, 4203].map { ($0, Steps.reading(.inProgress, .draft, at: 1)) })
        let graph = try #require(WorkMap(Steps.board(stages, missions: [mission]), missions: [mission]).bands.first?.graph)
        #expect(graph.columns == [.wave(0), .wave(1)])
        #expect(Self.places(graph) == ["!4202 0,0", "!4201 0,1", "!4203 1,0"])
        #expect(graph.lines == [WorkMapLine(before: Self.pr(4202), after: Self.pr(4203), style: .order)])
        #expect(WorkMapGraph.loops([4203, 4201, 4202].map(Self.pr), lines: [
            WorkMapLine(before: Self.pr(4202), after: Self.pr(4203), style: .order),
            WorkMapLine(before: Self.pr(4202), after: Self.pr(4201), style: .order),
            WorkMapLine(before: Self.pr(4201), after: Self.pr(4202), style: .order),
        ]) == [[Self.pr(4203)], [Self.pr(4201), Self.pr(4202)]])
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
        let map = WorkMap(board, missions: [Self.chain, other], hidden: MapHidden([Self.pr(4202)]))
        #expect(map.groups.map { $0.items.map(\.ref.shortOrderLabel) } == [["!4100", "!4101", "!4102", "!4103"]])
        #expect(map.loose.map(\.ref.shortOrderLabel) == ["!4201", "5150"])
        #expect(map.hidden.map(\.ref.shortOrderLabel) == ["!4202"])
        #expect(map.bands.map(\.lane.kind) == [.mission(Self.chain.key), .mission(other.key), .notInAMission])
    }

    /// A graph of more cards than the Map draws clearly has none: the Board shows them.
    @Test func tooManyCardsHaveNoGraph() {
        let steps = (1...41).map { Steps.step(4100 + $0, place: $0) }
        let mission = Steps.mission(steps)
        let stages = Dictionary(uniqueKeysWithValues: (1...41).map { (4100 + $0, Steps.reading(.inProgress, .draft, at: 1)) })
        let map = WorkMap(Steps.board(stages, missions: [mission]), missions: [mission])
        #expect(map.bands.first?.graph == nil)
        #expect(map.bands.first?.count == 41)
        #expect(OrderText.tooManyCards(41) == "These 41 cards are too many to draw clearly. The Board shows them.")
        let fewer = WorkMap(Steps.board(stages, missions: [mission]), missions: [mission], hidden: MapHidden([Self.pr(4141)]))
        #expect(fewer.bands.first?.graph != nil)
    }

    /// The cards you hid: the one you hid last first, each once, at most `mostCards`; shown again one by one, all at once, or
    /// as their source goes; kept by reference.
    @Test func hiddenCardsAreKeptByReference() {
        var hidden = MapHidden()
        let hidFirst = hidden.hide(Self.pr(4101))
        let hidSecond = hidden.hide(Steps.task(5104))
        let hidAgain = hidden.hide(Self.pr(4101))
        #expect(hidFirst && hidSecond && !hidAgain)
        #expect(hidden.refs == [Steps.task(5104), Self.pr(4101)])
        let shown = hidden.show([Self.pr(4101)])
        let shownAgain = hidden.show([Self.pr(4101)])
        #expect(shown && !shownAgain)
        #expect(hidden.refs == [Steps.task(5104)])

        let defaults = MemorySettings()
        hidden.hide(Self.pr(4102))
        hidden.save(to: defaults)
        #expect(defaults.object(forKey: "order.map.hidden") as? [String] == ["pullRequest/contoso/4102", "workItem/contoso/5104"])
        #expect(MapHidden.load(from: defaults) == hidden)
        let forgot = hidden.forget([.workItem])
        #expect(forgot)
        #expect(hidden.refs == [Self.pr(4102)])
        MapHidden().save(to: defaults)
        #expect(defaults.object(forKey: "order.map.hidden") == nil)

        var full = MapHidden((1...MapHidden.mostCards).map { Self.pr(5000 + $0) })
        full.hide(Self.pr(4101))
        #expect(full.refs.count == MapHidden.mostCards)
        #expect(full.refs.first == Self.pr(4101))
        #expect(!full.contains(Self.pr(5000 + MapHidden.mostCards)))

        // What My Work shows, and how the Map groups: the Board and By Mission until you choose.
        #expect(MyWorkView.load(from: defaults) == .board)
        MyWorkView.map.save(to: defaults)
        #expect(MyWorkView.load(from: defaults) == .map)
        #expect(WorkMapGrouping.load(from: defaults) == .byMission)
        WorkMapGrouping.all.save(to: defaults)
        #expect(WorkMapGrouping.load(from: defaults) == .all)
    }
}
