import BriefBarCore
import Foundation
import SwiftUI
import Testing
@testable import BriefBarUI

/// My Work's Map's canvas, where a graph's columns don't all fit across the page, as with a card's details beside it: they
/// fold into tiers, one under the other, each only as tall as its own rows, and a line from one tier to the next wraps
/// round, past the first's end, under it, and into the next from its start; the grid has as many columns as fit.
@MainActor
@Suite struct WorkMapCanvasTests {
    static let day = Date(timeIntervalSince1970: 1_800_000_000)
    static let metrics = WorkMapMetrics(scale: 1)

    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    static func step(_ number: Int) -> MapNodeID {
        .step(id(number))
    }

    /// Steps 1 to `chain`, each waiting for the one before, then `loose` more, all in Not in a mission, with these lines too.
    static func map(chain: Int, loose: Int = 0, lines more: [(Int, Int)] = []) -> WorkMap {
        var edits = MapEdits()
        for number in 1...(chain + loose) {
            edits.addStep(id(number), name: "Step \(number)", home: nil, by: .you, at: day)
        }
        var lines: [(Int, Int)] = (1..<max(chain, 1)).map { ($0, $0 + 1) }
        lines += more
        for (before, after) in lines {
            edits.set(MapEdits.Line(step(before), step(after)), on: true, by: .you, at: day)
        }
        return WorkMap(PullRequestBoard(), missions: [], state: MapEdits.merged([edits], now: day))
    }

    /// Where a band's graph goes on its canvas, `width` wide, or as wide as it takes.
    static func geometry(_ graph: WorkMapGraph, width: CGFloat?) -> WorkMapCanvas.Geometry {
        WorkMapCanvas.Geometry(
            blocks: [WorkMapCanvas.Block(id: "band", graph: graph)], columns: graph.columns, grid: [], width: width, gridColumns: 4,
            metrics: metrics
        )
    }

    /// Seven steps, a wave each, on a page four columns wide: the last three go on under the first four, from the start,
    /// and the line from the fourth to the fifth wraps round, past the fourth, under its tier and into the fifth from its
    /// left; nothing's wider than the page. Until the page knows its width, they stay in one row.
    @Test func columnsThatDontFitFoldAndTheLineBetweenWrapsRound() throws {
        let graph = try #require(Self.map(chain: 7).bands.first?.graph)
        #expect(graph.columns.count == 7)
        let wide = Self.geometry(graph, width: nil)
        #expect(wide.fold.tiers == 1 && Set(wide.nodes.map(\.frame.minY)).count == 1)
        #expect(wide.titles.map(\.text) == ["Now", "Then", "Later"])

        let narrow = Self.geometry(graph, width: 950)
        #expect(narrow.fold.starts == [0, 4])
        #expect(narrow.size.width <= 950 && narrow.nodes.allSatisfy { $0.frame.minX > 0 && $0.frame.maxX < narrow.size.width })
        #expect(narrow.titles.map(\.text) == ["Now", "Then", "Later"])
        let first = try #require(narrow.frames[Self.step(1)])
        let fourth = try #require(narrow.frames[Self.step(4)])
        let fifth = try #require(narrow.frames[Self.step(5)])
        #expect(fifth.minY > fourth.maxY && fifth.minX == first.minX)
        let wrapped = try #require(narrow.lines.first { $0.line.before == Self.step(4) })
        #expect(wrapped.end == CGPoint(x: fifth.minX, y: fifth.midY))
        let bounds = wrapped.path.boundingRect
        #expect(bounds.maxX > fourth.maxX && bounds.minX < fifth.minX)
        #expect(wrapped.middle.y > fourth.maxY && wrapped.middle.y < fifth.minY)
    }

    /// A tier is only as tall as its own rows: two more steps in the first column, and one whose line goes on to the sixth,
    /// make the first tier four rows tall, and the second still two. The two lines that wrap round together keep a lane
    /// each: the one outermost past the first tier's end is innermost before the second's start, so that they don't cross.
    @Test func aTierIsOnlyAsTallAsItsRowsAndLinesThatWrapTogetherKeepALaneEach() throws {
        let m = Self.metrics
        let graph = try #require(Self.map(chain: 7, loose: 3, lines: [(8, 6)]).bands.first?.graph)
        let narrow = Self.geometry(graph, width: 950)
        #expect(narrow.fold.starts == [0, 4])
        let block = try #require(narrow.blocks.first)
        let second = [5, 6, 7].compactMap { narrow.frames[Self.step($0)] }
        let gap = m.laneGap(of: 2)
        #expect(second.map(\.minY).min() == block.top + m.y(4) - m.rowGap + 2 * m.foldGap + gap)
        #expect(block.height == m.y(4) - m.rowGap + 2 * m.foldGap + gap + m.y(2) - m.rowGap)

        let chained = try #require(narrow.lines.first { $0.line.before == Self.step(4) }).path.boundingRect
        let skipping = try #require(narrow.lines.first { $0.line.before == Self.step(8) }).path.boundingRect
        #expect(abs(chained.maxX - skipping.maxX) == gap && abs(chained.minX - skipping.minX) == gap)
        #expect((chained.maxX > skipping.maxX) == (chained.minX > skipping.minX))
        #expect(narrow.size.width <= 950)
    }

    /// Two lines that wrap round together run closer than a click's give, yet a click on either picks that one, the nearest,
    /// for Take Away to take away the line you meant.
    @Test func aClickOnALineThatWrapsBesideAnotherPicksThatOne() throws {
        let graph = try #require(Self.map(chain: 7, loose: 3, lines: [(8, 6)]).bands.first?.graph)
        let narrow = Self.geometry(graph, width: 950)
        let wrapped = [Self.step(4), Self.step(8)].compactMap { before in narrow.lines.first { $0.line.before == before } }
        #expect(wrapped.count == 2)
        let tracks = wrapped.map { Self.track(of: $0.path) }
        #expect(abs(tracks[0].y - tracks[1].y) < 4.5)
        for (drawn, track) in zip(wrapped, tracks) {
            #expect(narrow.line(at: track, within: 4.5) == drawn.id)
        }
        #expect(narrow.line(at: CGPoint(x: tracks[0].x, y: max(tracks[0].y, tracks[1].y) + 9), within: 4.5) == nil)
    }

    /// Where one column fits but not the room its wrapping lines need beside it, they squeeze closer to it: nothing is wider
    /// than the page.
    @Test func oneColumnThatFitsSqueezesItsLanesRatherThanOverflow() throws {
        let m = Self.metrics
        let graph = try #require(Self.map(chain: 2).bands.first?.graph)
        let width = m.nodeWidth + m.margin(for: 1)
        let narrow = Self.geometry(graph, width: width)
        #expect(narrow.fold.starts == [0, 1])
        #expect(narrow.size.width <= width)
        #expect(narrow.nodes.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= width })
        let wrapped = try #require(narrow.lines.first).path.boundingRect
        #expect(wrapped.minX >= 0 && wrapped.maxX <= width)
        #expect(wrapped.minX < narrow.nodes[0].frame.minX && wrapped.maxX > narrow.nodes[0].frame.maxX)
    }

    /// A selected line's card stays on the canvas, as wide as it is where that's narrower than the card, as one column is;
    /// on a wider canvas it's 340 points wide, at the line's middle, as it was.
    @Test func aSelectedLinesCardStaysOnACanvasOfOneColumn() throws {
        let m = Self.metrics
        let graph = try #require(Self.map(chain: 2).bands.first?.graph)
        let narrow = Self.geometry(graph, width: m.nodeWidth + m.margin(for: 1))
        let card = narrow.card(for: try #require(narrow.lines.first), metrics: m)
        #expect(card.minX == 0 && card.maxX == narrow.size.width)

        let wide = Self.geometry(try #require(Self.map(chain: 4).bands.first?.graph), width: nil)
        let middle = try #require(wide.lines.first { $0.line.before == Self.step(2) })
        let centered = wide.card(for: middle, metrics: m)
        #expect(centered.width == 340 && centered.midX == middle.middle.x && centered.midY == middle.middle.y)
    }

    /// The middle of a path's longest straight piece: for a line that wraps round, its track under its tier.
    static func track(of path: Path) -> CGPoint {
        var current = CGPoint.zero
        var longest: (length: CGFloat, middle: CGPoint) = (-1, .zero)
        path.forEach { element in
            switch element {
            case .move(let to):
                current = to
            case .line(let to):
                let length = hypot(to.x - current.x, to.y - current.y)
                if length > longest.length {
                    longest = (length, CGPoint(x: (current.x + to.x) / 2, y: (current.y + to.y) / 2))
                }
                current = to
            case .quadCurve(let to, _), .curve(let to, _, _):
                current = to
            case .closeSubpath:
                break
            }
        }
        return longest.middle
    }

    /// The grid has as many columns as fit the page, at least one, and as many as it's given until the page knows its width.
    @Test func theGridHasAsManyColumnsAsFit() {
        let loose = Self.map(chain: 1, loose: 4).loose
        #expect(loose.count == 5)
        let narrow = WorkMapCanvas.Geometry(blocks: [], columns: [], grid: loose, width: 500, gridColumns: 4, metrics: Self.metrics)
        #expect(Set(narrow.nodes.map(\.frame.minX)).count == 2 && narrow.size.width <= 500)
        let unknown = WorkMapCanvas.Geometry(blocks: [], columns: [], grid: loose, width: nil, gridColumns: 4, metrics: Self.metrics)
        #expect(Set(unknown.nodes.map(\.frame.minX)).count == 4)
    }
}
