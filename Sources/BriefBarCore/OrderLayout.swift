import Foundation

// Where the order's graph goes in By Mission's two views: List, whose rows have a gutter beside them, and the Map. Only
// where things go, never how they're drawn: the views draw them.

// MARK: - Lines

/// How a line between two pull requests is drawn: solid when the later one is stacked on the earlier, as its branch or a
/// GitHub stack says; dashed when it only merges after it, as its order says.
public enum OrderLineStyle: Hashable, Sendable {
    case solid
    case dashed
}

/// A line from a pull request to one that comes right after it.
public struct OrderLine: Hashable, Sendable {
    public var edge: OrderEdge
    public var style: OrderLineStyle

    public init(edge: OrderEdge, style: OrderLineStyle) {
        self.edge = edge
        self.style = style
    }

    /// The lines into each of these pull requests, from what it comes right after among them, in their order.
    static func between(_ steps: [OrderStep]) -> [OrderLine] {
        let refs = Set(steps.map(\.ref))
        return steps.flatMap { step in
            step.directPrerequisites.filter(refs.contains).map { earlier in
                OrderLine(edge: OrderEdge(earlier, step.ref), style: step.isStacked(on: earlier) ? .solid : .dashed)
            }
        }
    }
}

// MARK: - List's gutter

/// The gutter beside a mission's rows in List, as Sapling's smartlog, Graphite's `gt log` and VS Code's Source Control
/// Graph draw one. Each pull request is a node in a lane on the left of its row. Lines run through the rows' full height,
/// and forks and joins curve between them. It takes at most `maxLanes` lanes. A line that would need more isn't drawn,
/// and the row's capsule still names what it waits for. A pull request that merges any time has a node and no lines.
/// VoiceOver skips the gutter: the rows' words say it all.
public struct OrderGutter: Equatable, Sendable {
    /// Where part of a line ends in a row: at its top edge in a lane, at its node, or at its bottom edge in a lane.
    public enum Point: Hashable, Sendable {
        case top(Int)
        case node
        case bottom(Int)
    }

    /// The part of a line in one row: into its node from above, out of it downward, or through the row in its lane.
    public struct Segment: Hashable, Sendable {
        public var from: Point
        public var to: Point
        public var line: OrderLine
    }

    public struct Row: Equatable, Sendable {
        public var ref: ItemRef
        /// The lane of its node, from 0 on the left.
        public var lane: Int
        public var segments: [Segment]
    }

    public static let maxLanes = 3

    /// In the order they were given.
    public private(set) var rows: [Row]
    /// How many lanes it takes, at most `maxLanes`: how wide it is.
    public private(set) var laneCount: Int
    /// The lines it doesn't draw, for want of lanes.
    public private(set) var hidden: [OrderLine]
    /// Every line between the rows, drawn or not.
    public private(set) var lines: [OrderLine]

    /// The gutter of these rows, as they show from the top: a mission's steps, without the merged ones while they're
    /// folded, and only those of the page's source. A line goes only down, from a row to one below it.
    public init(_ steps: [OrderStep], maxLanes: Int = OrderGutter.maxLanes) {
        let lanes = max(1, maxLanes)
        let index = Dictionary(steps.map(\.ref).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func span(_ line: OrderLine) -> (source: Int, target: Int) {
            (index[line.edge.before] ?? 0, index[line.edge.after] ?? 0)
        }
        let lines = OrderLine.between(steps).filter { line in
            guard let source = index[line.edge.before], let target = index[line.edge.after] else { return false }
            return source < target
        }
        // The lines it draws: the shortest first, solid before dashed, as long as there are lanes for them.
        let candidates = lines.sorted { lhs, rhs in
            let (left, right) = (span(lhs), span(rhs))
            if left.target - left.source != right.target - right.source {
                return left.target - left.source < right.target - right.source
            }
            if lhs.style != rhs.style { return lhs.style == .solid }
            return (left.target, left.source) < (right.target, right.source)
        }
        var kept: [OrderLine] = []
        var hidden: [OrderLine] = []
        for line in candidates {
            if Self.fits(kept + [line], rows: steps.count, lanes: lanes, span: span) {
                kept.append(line)
            } else {
                hidden.append(line)
            }
        }
        // Their lanes, from the top: a node in the leftmost lane of the lines that come into it, else in the leftmost free
        // lane; a line out of it in its node's lane while that's free, else in the leftmost free one, to its end.
        var lane: [OrderLine: Int] = [:]
        var rows: [Row] = []
        var used = 0
        for (row, step) in steps.enumerated() {
            let incoming = kept.filter { span($0).target == row }.sorted { (lane[$0] ?? 0) < (lane[$1] ?? 0) }
            let passing = kept.filter { span($0).source < row && row < span($0).target }.sorted { (lane[$0] ?? 0) < (lane[$1] ?? 0) }
            let outgoing = kept.filter { span($0).source == row }.sorted { span($0).target < span($1).target }
            var taken = Set(passing.compactMap { lane[$0] })
            let node = incoming.compactMap { lane[$0] }.min() ?? (0..<lanes).first { !taken.contains($0) } ?? 0
            for line in outgoing {
                let free = taken.contains(node) ? (0..<lanes).first { !taken.contains($0) } ?? node : node
                lane[line] = free
                taken.insert(free)
            }
            var segments = incoming.map { Segment(from: .top(lane[$0] ?? node), to: .node, line: $0) }
            segments += passing.map { line in Segment(from: .top(lane[line] ?? 0), to: .bottom(lane[line] ?? 0), line: line) }
            segments += outgoing.map { Segment(from: .node, to: .bottom(lane[$0] ?? node), line: $0) }
            used = max(used, node + 1, (taken.max() ?? -1) + 1)
            rows.append(Row(ref: step.ref, lane: node, segments: segments))
        }
        self.rows = rows
        laneCount = used
        self.hidden = hidden.sorted { (span($0).target, span($0).source) < (span($1).target, span($1).source) }
        self.lines = lines
    }

    /// Whether these lines fit in the lanes: across each boundary between rows, no more lines than lanes; and through each
    /// row, a lane left for its node.
    static func fits(_ lines: [OrderLine], rows: Int, lanes: Int, span: (OrderLine) -> (source: Int, target: Int)) -> Bool {
        let spans = lines.map(span)
        for boundary in 0..<max(rows - 1, 0) where spans.filter({ $0.source <= boundary && boundary < $0.target }).count > lanes {
            return false
        }
        for row in 0..<rows where spans.filter({ $0.source < row && row < $0.target }).count + 1 > lanes {
            return false
        }
        return true
    }

    /// What hovering a row highlights: the row, what goes before it, and what comes after it, directly or through others,
    /// by every line between the rows, drawn or not. The rest of the card's gutter dims.
    public func highlighted(by ref: ItemRef) -> Set<ItemRef> {
        func reach(_ step: (OrderEdge) -> (from: ItemRef, to: ItemRef)) -> Set<ItemRef> {
            var reached: Set<ItemRef> = []
            var pending = [ref]
            while let current = pending.popLast() {
                for line in lines {
                    let (from, to) = step(line.edge)
                    if from == current, reached.insert(to).inserted { pending.append(to) }
                }
            }
            return reached
        }
        return reach { ($0.after, $0.before) }.union(reach { ($0.before, $0.after) }).union([ref])
    }

    /// Whether hovering a row highlights a line: it joins two of what that highlights.
    public func highlights(_ line: OrderLine, hovering ref: ItemRef) -> Bool {
        let highlighted = highlighted(by: ref)
        return highlighted.contains(line.edge.before) && highlighted.contains(line.edge.after)
    }
}

// MARK: - Map

/// The Map: each mission a band, a graph from left to right in merge waves, as GitHub Actions' visualization graph and
/// Airflow's grid lay runs out. Its columns are what merged, then what can merge now, then what comes after, wave by
/// wave. Its lanes are the sessions that opened its pull requests, each labelled, with the pull requests no session is
/// known to have opened last. Only lines from a pull request to one that comes right after it join them: none for
/// sessions or tasks. A mission with more than `mostPullRequests` shows as its list instead, since node-link diagrams
/// of more than about twenty nodes stop being read except to follow a path.
public struct OrderMap: Equatable, Sendable {
    public enum Column: Hashable, Sendable {
        /// What merged, or closed without merging.
        case ended
        /// A merge wave: 0 merges now, 1 then, and so on.
        case wave(Int)
    }

    public struct Lane: Equatable, Sendable {
        /// The session whose pull requests it holds; nil for those no session is known to have opened.
        public var session: ItemRef?
        /// Its first row in the band.
        public var row: Int
        /// How many rows it takes: as many pull requests as it has in one column, at most.
        public var height: Int
    }

    public struct Node: Equatable, Sendable {
        public var ref: ItemRef
        public var column: Int
        public var lane: Int
        /// Its row in the band.
        public var row: Int
    }

    /// Where a node is, for counting crossings: its column, and its row.
    struct Place: Equatable {
        var x: Double
        var y: Double
    }

    /// The pull requests in a lane's column: a cell.
    private struct Cell: Hashable, Comparable {
        var lane: Int
        var column: Int

        static func < (lhs: Cell, rhs: Cell) -> Bool {
            (lhs.lane, lhs.column) < (rhs.lane, rhs.column)
        }
    }

    public static let mostPullRequests = 30

    public private(set) var columns: [Column]
    /// From the top.
    public private(set) var lanes: [Lane]
    /// In merge order, as VoiceOver reads them, each a button.
    public private(set) var nodes: [Node]
    public private(set) var lines: [OrderLine]
    /// How many lines cross, as it's laid out: as few as it found.
    public private(set) var crossings: Int

    /// The Map of a mission; nil for one with more than `mostPullRequests` pull requests, or none.
    public init?(_ mission: OrderMission, mostPullRequests: Int = OrderMap.mostPullRequests) {
        let steps = mission.steps
        guard !steps.isEmpty, steps.count <= mostPullRequests else { return nil }

        // Each that hasn't merged or closed comes one wave after the last of what it waits for.
        var wave: [ItemRef: Int] = [:]
        for step in steps where !step.status.hasEnded {
            let earlier = step.prerequisites.filter { !$0.status.hasEnded }.compactMap { wave[$0.ref] }
            wave[step.ref] = earlier.max().map { $0 + 1 } ?? 0
        }
        let hasEnded = steps.contains { $0.status.hasEnded }
        let columns = (hasEnded ? [Column.ended] : []) + (0..<((wave.values.max() ?? -1) + 1)).map(Column.wave)
        func column(of step: OrderStep) -> Int {
            step.status.hasEnded ? 0 : (hasEnded ? 1 : 0) + (wave[step.ref] ?? 0)
        }

        // A lane for each session, as each first comes in merge order; the pull requests without one last.
        var sessions: [ItemRef?] = []
        for step in steps where !sessions.contains(step.session) {
            sessions.append(step.session)
        }
        if let none = sessions.firstIndex(of: nil) { sessions.append(sessions.remove(at: none)) }
        var cells: [Cell: [ItemRef]] = [:]
        var laneOf: [ItemRef: Int] = [:]
        for step in steps {
            let lane = sessions.firstIndex(of: step.session) ?? 0
            laneOf[step.ref] = lane
            cells[Cell(lane: lane, column: column(of: step)), default: []].append(step.ref)
        }
        let lines = OrderLine.between(steps)
        var order = Array(sessions.indices)

        func height(of lane: Int) -> Int {
            max(1, columns.indices.map { cells[Cell(lane: lane, column: $0)]?.count ?? 0 }.max() ?? 1)
        }
        func places() -> [ItemRef: Place] {
            var places: [ItemRef: Place] = [:]
            var top = 0
            for lane in order {
                for (cell, refs) in cells where cell.lane == lane {
                    for (slot, ref) in refs.enumerated() {
                        places[ref] = Place(x: Double(cell.column), y: Double(top + slot))
                    }
                }
                top += height(of: lane)
            }
            return places
        }
        var best = Self.crossings(lines, at: places())

        // Fewer crossings: neighbouring lanes swapped, while that crosses fewer lines.
        var improved = true
        var passes = 0
        while improved, passes < 8 {
            improved = false
            passes += 1
            for index in order.indices.dropLast() {
                order.swapAt(index, index + 1)
                let crossings = Self.crossings(lines, at: places())
                if crossings < best {
                    best = crossings
                    improved = true
                } else {
                    order.swapAt(index, index + 1)
                }
            }
        }
        // Then, in each cell, its pull requests by the rows of those they're joined to, and neighbours swapped, while that
        // crosses no more lines, and fewer.
        var neighbours: [ItemRef: [ItemRef]] = [:]
        for line in lines {
            neighbours[line.edge.before, default: []].append(line.edge.after)
            neighbours[line.edge.after, default: []].append(line.edge.before)
        }
        for cell in cells.keys.sorted() {
            guard let refs = cells[cell], refs.count > 1 else { continue }
            let rows = places()
            func centre(_ ref: ItemRef) -> Double {
                let ys = neighbours[ref, default: []].compactMap { rows[$0]?.y }
                return ys.isEmpty ? rows[ref]?.y ?? 0 : ys.reduce(0, +) / Double(ys.count)
            }
            cells[cell] = refs.enumerated().sorted { lhs, rhs in
                let (left, right) = (centre(lhs.element), centre(rhs.element))
                return left != right ? left < right : lhs.offset < rhs.offset
            }.map(\.element)
            let crossings = Self.crossings(lines, at: places())
            if crossings <= best { best = crossings } else { cells[cell] = refs }
            var swapped = true
            while swapped {
                swapped = false
                for index in (cells[cell] ?? []).indices.dropLast() {
                    cells[cell]?.swapAt(index, index + 1)
                    let crossings = Self.crossings(lines, at: places())
                    if crossings < best {
                        best = crossings
                        swapped = true
                    } else {
                        cells[cell]?.swapAt(index, index + 1)
                    }
                }
            }
        }

        let placed = places()
        let laneIndex = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var lanes: [Lane] = []
        var top = 0
        for lane in order {
            lanes.append(Lane(session: sessions[lane], row: top, height: height(of: lane)))
            top += height(of: lane)
        }
        self.columns = columns
        self.lanes = lanes
        nodes = steps.map { step in
            Node(
                ref: step.ref, column: column(of: step), lane: laneIndex[laneOf[step.ref] ?? 0] ?? 0,
                row: Int(placed[step.ref]?.y ?? 0)
            )
        }
        self.lines = lines
        crossings = best
    }

    /// How many of these lines cross, each drawn straight from the pull request it starts at to the one it ends at, left
    /// to right. Lines that share an end don't count.
    static func crossings(_ lines: [OrderLine], at places: [ItemRef: Place]) -> Int {
        let drawn = lines.compactMap { line -> (edge: OrderEdge, from: Place, to: Place)? in
            guard let from = places[line.edge.before], let to = places[line.edge.after], from.x < to.x else { return nil }
            return (line.edge, from, to)
        }
        func y(_ line: (edge: OrderEdge, from: Place, to: Place), at x: Double) -> Double {
            line.from.y + (line.to.y - line.from.y) * (x - line.from.x) / (line.to.x - line.from.x)
        }
        var count = 0
        for (index, first) in drawn.enumerated() {
            for second in drawn[(index + 1)...] {
                let ends: Set<ItemRef> = [first.edge.before, first.edge.after]
                guard !ends.contains(second.edge.before), !ends.contains(second.edge.after) else { continue }
                let low = max(first.from.x, second.from.x)
                let high = min(first.to.x, second.to.x)
                guard low < high else { continue }
                if (y(first, at: low) - y(second, at: low)) * (y(first, at: high) - y(second, at: high)) < 0 { count += 1 }
            }
        }
        return count
    }
}

// MARK: - Words

extension OrderText {
    /// A Map column's title: "Merged", "Now", "Then", "Later"; nil for the columns after Later, which go under its title.
    public static func title(of column: OrderMap.Column) -> String? {
        switch column {
        case .ended: return "Merged"
        case .wave(0): return "Now"
        case .wave(1): return "Then"
        case .wave(2): return "Later"
        case .wave: return nil
        }
    }

    /// Why a mission's band in the Map shows its list instead.
    public static func tooManyToDraw(_ count: Int) -> String {
        "This mission has \(count) pull requests, too many to draw clearly, so it shows as a list."
    }

    /// Under the Map, which draws only missions: "3 pull requests aren't in a mission. List shows them."
    public static func notInAMission(_ count: Int) -> String {
        count == 1 ? "1 pull request isn't in a mission. List shows it." : "\(count) pull requests aren't in a mission. List shows them."
    }
}
