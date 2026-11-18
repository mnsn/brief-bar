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
