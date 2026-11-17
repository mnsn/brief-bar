import Foundation

// My Work's Map: the Board's cards as a graph of what holds what, as By Mission's Map draws a mission's pull requests, with
// your work on the Board too. By Mission, each lane of the Board is a band: a mission's, a story's, or that of what's in no
// mission. All draws each set of cards that lines join as a graph of its own, the one with the Board's first card first, and
// the cards no line joins on one row after them. Its columns are what's done, then what can go now, then what comes after,
// wave by wave; a line goes from a pull request to one that comes after it in an order, and through cards the Map doesn't show
// there, such as those you hid, it's dotted. Only where things go, never how they're drawn: the views draw them.

// MARK: - Your choices

/// What My Work shows under Up Next: the Board, or the Map.
public enum MyWorkView: String, CaseIterable, Sendable {
    case board
    case map

    public static let defaultsKey = "order.myWork.view"

    /// What you chose last, the Board until you choose.
    public static func load(from defaults: some SettingsStorage) -> MyWorkView {
        defaults.string(forKey: defaultsKey).flatMap(MyWorkView.init(rawValue:)) ?? .board
    }

    public func save(to defaults: some SettingsStorage) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    public var title: String {
        switch self {
        case .board: "Board"
        case .map: "Map"
        }
    }
}

/// How My Work's Map puts its cards together: By Mission, a band for each lane of the Board; All, a graph for each set of cards
/// that lines join, whatever their missions.
public enum WorkMapGrouping: String, CaseIterable, Sendable {
    case byMission
    case all

    public static let defaultsKey = "order.map.grouping"

    /// What you chose last, By Mission until you choose.
    public static func load(from defaults: some SettingsStorage) -> WorkMapGrouping {
        defaults.string(forKey: defaultsKey).flatMap(WorkMapGrouping.init(rawValue:)) ?? .byMission
    }

    public func save(to defaults: some SettingsStorage) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    public var title: String {
        switch self {
        case .byMission: "By Mission"
        case .all: "All"
        }
    }
}

/// The cards you hid on My Work's Map, as they're not your focus now: by reference, the one you hid last first, at most
/// `mostCards` of them, in the preferences (`order.map.hidden`), never a title. Hiding one changes only the Map: the Board, Up
/// Next and every count still have it.
public struct MapHidden: Equatable, Sendable {
    public static let defaultsKey = "order.map.hidden"
    /// How many it keeps: past them, the one you hid longest ago shows again.
    public static let mostCards = 300

    /// The one you hid last first.
    public private(set) var refs: [ItemRef]

    /// - Parameter refs: the one you hid last first; each once, the first `mostCards` of them.
    public init(_ refs: [ItemRef] = []) {
        var seen: Set<ItemRef> = []
        self.refs = Array(refs.filter { seen.insert($0).inserted }.prefix(Self.mostCards))
    }

    public var isEmpty: Bool {
        refs.isEmpty
    }

    public func contains(_ ref: ItemRef) -> Bool {
        refs.contains(ref)
    }

    /// Hides a card, the one you hid last now. Whether it wasn't hidden already.
    @discardableResult
    public mutating func hide(_ ref: ItemRef) -> Bool {
        guard !refs.contains(ref) else { return false }
        refs.insert(ref, at: 0)
        if refs.count > Self.mostCards { refs.removeLast(refs.count - Self.mostCards) }
        return true
    }

    /// Shows cards again. Whether any was hidden.
    @discardableResult
    public mutating func show(_ shown: some Sequence<ItemRef>) -> Bool {
        let shown = Set(shown)
        let count = refs.count
        refs.removeAll { shown.contains($0) }
        return refs.count != count
    }

    /// Forgets those of these kinds, as their source goes. Whether any went.
    @discardableResult
    public mutating func forget(_ kinds: Set<ItemRef.Kind>) -> Bool {
        show(refs.filter { kinds.contains($0.kind) })
    }

    /// What the preferences keep, without what this build can't read.
    public static func load(from defaults: some SettingsStorage) -> MapHidden {
        MapHidden(((defaults.object(forKey: defaultsKey) as? [String]) ?? []).compactMap(ItemRef.init))
    }

    public func save(to defaults: some SettingsStorage) {
        if refs.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(refs.map(\.description), forKey: Self.defaultsKey)
        }
    }
}

// MARK: - A graph

/// A column of the Map: what's done, or a wave of what's left.
public enum WorkMapColumn: Hashable, Sendable {
    /// Pull requests that merged or closed, and work that's resolved or done: what holds nothing back now.
    case done
    /// What's left, wave by wave: 0 can go now, 1 comes after what goes now, and so on.
    case wave(Int)

    /// Its title: "Done", "Now", "Then", "Later"; nil for those after Later, which go under its title.
    public var title: String? {
        switch self {
        case .done: "Done"
        case .wave(0): "Now"
        case .wave(1): "Then"
        case .wave(2): "Later"
        case .wave: nil
        }
    }
}

/// A line of the Map, from a card to one that comes after it.
public struct WorkMapLine: Hashable, Sendable {
    public enum Style: Hashable, Sendable {
        /// Stacked: the later one targets the earlier one's branch, or comes right after it in a GitHub stack.
        case stacked
        /// It comes after it, as an order says.
        case order
        /// It comes after it through these, which the Map doesn't show there, nearest to it last: cards you hid, and pull
        /// requests that aren't on your board, or are in another band.
        case through([ItemRef])
    }

    public var before: ItemRef
    public var after: ItemRef
    public var style: Style
    /// The rows it runs along through the columns between its ends, from left to right: none between neighbouring columns.
    public var rows: [Int]

    public init(before: ItemRef, after: ItemRef, style: Style, rows: [Int] = []) {
        self.before = before
        self.after = after
        self.style = style
        self.rows = rows
    }
}

/// A card of the Map, in its place.
public struct WorkMapNode: Equatable, Sendable, Identifiable {
    public var item: BoardItem
    public var column: Int
    public var row: Int

    public var id: ItemRef { item.ref }
}

/// Cards of the Map as a graph, in columns, from left to right: what's done, then wave by wave. In each column, the cards
/// lines join come first, ordered to cross as few lines as it finds, and each where the lines into it come from, so that a
/// chain runs straight; the cards no line joins go after them. A line that skips columns keeps a row of each to itself, as
/// a layered drawing's long edges do, so that no card sits on it.
public struct WorkMapGraph: Equatable, Sendable {
    public private(set) var columns: [WorkMapColumn]
    /// Column by column, each from the top: as VoiceOver reads them.
    public private(set) var nodes: [WorkMapNode]
    public private(set) var lines: [WorkMapLine]
    /// How many rows it takes.
    public private(set) var rows: Int
    /// How many of its lines cross, as it's laid out.
    public private(set) var crossings: Int

    /// Whether a card counts as done: a pull request that merged or closed, or work that's resolved or done.
    public static func isDone(_ item: BoardItem) -> Bool {
        switch item {
        case .pullRequest(let card): card.step?.status.hasEnded ?? (card.stage == .merged)
        case .work(let task): !task.work.progress.isOpen
        }
    }

    /// Lays out cards, in the order they come, and the lines between them, which come into one that's still to do.
    /// - Parameters:
    ///   - waits: those of the cards that wait for something it doesn't show, such as a pull request in another mission:
    ///     each goes at least one wave on.
    init(_ items: [BoardItem], lines: [WorkMapLine], waits: Set<ItemRef> = []) {
        let refs = items.map(\.ref)
        let index = Dictionary(refs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let done = Set(items.filter(Self.isDone).map(\.ref))
        let lines = lines.filter { index[$0.before] != nil && index[$0.after] != nil && !done.contains($0.after) }

        // Each card still to do comes a wave after the last of what comes into it, and one that waits for something it
        // doesn't show at least one wave on. The cards of a loop of lines, where none can go first, share a wave, as far on
        // as what came into any of them, and what comes after the loop comes after that.
        let open = lines.filter { !done.contains($0.before) }
        let loops = Self.loops(refs.filter { !done.contains($0) }, lines: open)
        let loopOf = Dictionary(loops.enumerated().flatMap { number, loop in loop.map { ($0, number) } }, uniquingKeysWith: { first, _ in first })
        var loopWave = loops.map { loop in loop.contains(where: waits.contains) ? 1 : 0 }
        var waitingFor = Array(repeating: 0, count: loops.count)
        var after = Array(repeating: [Int](), count: loops.count)
        for line in open {
            guard let from = loopOf[line.before], let to = loopOf[line.after], from != to else { continue }
            after[from].append(to)
            waitingFor[to] += 1
        }
        var ready = loops.indices.filter { waitingFor[$0] == 0 }
        while !ready.isEmpty {
            let loop = ready.removeFirst()
            for later in after[loop] {
                loopWave[later] = max(loopWave[later], loopWave[loop] + 1)
                waitingFor[later] -= 1
                if waitingFor[later] == 0 { ready.append(later) }
            }
        }
        var wave: [ItemRef: Int] = [:]
        for (ref, loop) in loopOf { wave[ref] = loopWave[loop] }
        let waves = Set(wave.values).sorted()
        columns = (done.isEmpty ? [] : [.done]) + waves.map(WorkMapColumn.wave)
        let columnOf = Dictionary(refs.map { ref in
            (ref, done.contains(ref) ? 0 : (done.isEmpty ? 0 : 1) + (waves.firstIndex(of: wave[ref] ?? 0) ?? 0))
        }, uniquingKeysWith: { first, _ in first })

        // A line that skips columns passes through a slot of each between its ends.
        var layout = Layout(columns: columns.count)
        for ref in refs {
            layout.add(.card(ref), in: columnOf[ref] ?? 0)
        }
        var forwards: [WorkMapLine] = []
        for line in lines {
            guard let from = columnOf[line.before], let to = columnOf[line.after], from < to else { continue }
            forwards.append(line)
            var previous = Slot.card(line.before)
            for column in (from + 1)..<to {
                let passing = Slot.passing(forwards.count - 1, column)
                layout.add(passing, in: column)
                layout.join(previous, passing)
                previous = passing
            }
            layout.join(previous, .card(line.after))
        }
        layout.arrange()

        rows = layout.height
        crossings = layout.crossings()
        nodes = items.map { item in
            WorkMapNode(item: item, column: columnOf[item.ref] ?? 0, row: layout.row[.card(item.ref)] ?? 0)
        }.sorted { ($0.column, $0.row) < ($1.column, $1.row) }
        self.lines = forwards.enumerated().map { number, line in
            var line = line
            let from = columnOf[line.before] ?? 0, to = columnOf[line.after] ?? 0
            line.rows = to - from > 1 ? ((from + 1)..<to).map { layout.row[.passing(number, $0)] ?? 0 } : []
            return line
        }
    }

    /// What takes a row in a column: a card, or a line passing through it.
    enum Slot: Hashable {
        case card(ItemRef)
        /// The line of that number, as `init` counts those it draws, in that column.
        case passing(Int, Int)
    }

    /// The loops among these cards, by these lines, each a card alone where it's in none, in the order their first cards
    /// come, each in that order: their strongly connected components, as Tarjan finds them.
    static func loops(_ refs: [ItemRef], lines: [WorkMapLine]) -> [[ItemRef]] {
        let members = Set(refs)
        var next: [ItemRef: [ItemRef]] = [:]
        for line in lines where members.contains(line.before) && members.contains(line.after) {
            next[line.before, default: []].append(line.after)
        }
        var counter = 0
        var number: [ItemRef: Int] = [:]
        var lowest: [ItemRef: Int] = [:]
        var stack: [ItemRef] = []
        var onStack: Set<ItemRef> = []
        var found: [[ItemRef]] = []
        func visit(_ ref: ItemRef) {
            number[ref] = counter
            lowest[ref] = counter
            counter += 1
            stack.append(ref)
            onStack.insert(ref)
            for later in next[ref] ?? [] {
                if number[later] == nil {
                    visit(later)
                    lowest[ref] = min(lowest[ref] ?? 0, lowest[later] ?? 0)
                } else if onStack.contains(later) {
                    lowest[ref] = min(lowest[ref] ?? 0, number[later] ?? 0)
                }
            }
            guard lowest[ref] == number[ref] else { return }
            var loop: [ItemRef] = []
            while let top = stack.popLast() {
                onStack.remove(top)
                loop.append(top)
                if top == ref { break }
            }
            found.append(loop)
        }
        for ref in refs where number[ref] == nil {
            visit(ref)
        }
        let place = Dictionary(refs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return found.map { loop in loop.sorted { (place[$0] ?? 0) < (place[$1] ?? 0) } }
            .sorted { (place[$0[0]] ?? 0) < (place[$1[0]] ?? 0) }
    }

    /// Where each slot goes: its column, its order there, and its row.
    struct Layout {
        var columns: [[Slot]]
        var predecessors: [Slot: [Slot]] = [:]
        var successors: [Slot: [Slot]] = [:]
        var row: [Slot: Int] = [:]

        init(columns count: Int) {
            columns = Array(repeating: [], count: max(count, 1))
        }

        mutating func add(_ slot: Slot, in column: Int) {
            columns[column].append(slot)
        }

        mutating func join(_ before: Slot, _ after: Slot) {
            successors[before, default: []].append(after)
            predecessors[after, default: []].append(before)
        }

        var height: Int {
            (row.values.max() ?? -1) + 1
        }

        /// Whether any line joins a slot.
        func isJoined(_ slot: Slot) -> Bool {
            !(predecessors[slot] ?? []).isEmpty || !(successors[slot] ?? []).isEmpty
        }

        /// Orders each column, the slots lines join first, by where their neighbours are, a few times each way; then gives
        /// each a row: where the lines into it come from, as far as the slots above it let it; then swaps neighbours while
        /// that crosses fewer lines.
        mutating func arrange() {
            columns = columns.map { slots in slots.filter { isJoined($0) } + slots.filter { !isJoined($0) } }
            for _ in 0..<4 {
                for column in columns.indices.dropFirst() { sort(column, by: predecessors) }
                for column in columns.indices.dropLast().reversed() { sort(column, by: successors) }
            }
            for column in columns.indices { place(column) }
            var improved = true
            var passes = 0
            var best = crossings()
            while improved, passes < 8 {
                improved = false
                passes += 1
                for column in columns.indices {
                    for at in columns[column].indices.dropLast() {
                        let (upper, lower) = (columns[column][at], columns[column][at + 1])
                        guard isJoined(upper), isJoined(lower) else { continue }
                        swapRows(upper, lower, column: column, at: at)
                        let count = crossings()
                        if count < best {
                            best = count
                            improved = true
                        } else {
                            swapRows(lower, upper, column: column, at: at)
                        }
                    }
                }
            }
        }

        /// Orders a column's slots that lines join by the average place of their neighbours on one side, keeping their order
        /// where they have none there, or the same; those no line joins stay last.
        private mutating func sort(_ column: Int, by neighbours: [Slot: [Slot]]) {
            var place: [Slot: Double] = [:]
            for slots in columns {
                for (index, slot) in slots.enumerated() { place[slot] = Double(index) }
            }
            let keyed = columns[column].enumerated().map { index, slot -> (slot: Slot, key: Double, index: Int) in
                let around = (neighbours[slot] ?? []).compactMap { place[$0] }
                return (slot, around.isEmpty ? Double(index) : around.reduce(0, +) / Double(around.count), index)
            }
            let joined = keyed.filter { isJoined($0.slot) }.sorted { ($0.key, $0.index) < ($1.key, $1.index) }
            columns[column] = joined.map(\.slot) + keyed.filter { !isJoined($0.slot) }.map(\.slot)
        }

        /// Gives a column's slots their rows, in their order: each where the middle of the lines into it come from, but below
        /// the slot above it.
        private mutating func place(_ column: Int) {
            var last = -1
            for slot in columns[column] {
                let from = (predecessors[slot] ?? []).compactMap { row[$0] }.sorted()
                let wanted = from.isEmpty ? last + 1 : from[(from.count - 1) / 2]
                let at = max(wanted, last + 1)
                row[slot] = at
                last = at
            }
        }

        private mutating func swapRows(_ upper: Slot, _ lower: Slot, column: Int, at index: Int) {
            let (top, bottom) = (row[upper] ?? 0, row[lower] ?? 0)
            row[upper] = bottom
            row[lower] = top
            columns[column].swapAt(index, index + 1)
        }

        /// How many of the lines between neighbouring columns cross: two cross where their order at one column is the other
        /// way round at the next. Lines from the same slot, or into it, don't.
        func crossings() -> Int {
            var count = 0
            for column in columns.indices.dropLast() {
                let segments = columns[column].flatMap { from in
                    (successors[from] ?? []).compactMap { to in row[to].map { (from, to, row[from] ?? 0, $0) } }
                }
                for (index, first) in segments.enumerated() {
                    for second in segments[(index + 1)...] where first.0 != second.0 && first.1 != second.1 {
                        if (first.2 - second.2) * (first.3 - second.3) < 0 { count += 1 }
                    }
                }
            }
            return count
        }
    }
}

// MARK: - The Map

/// My Work's Map, as the Board has its cards now: a band for each of its lanes, By Mission; and, for All, a graph for each set
/// of cards lines join, and those no line joins. A graph has no more than `mostCards` cards: past them it's too many to read
/// but to follow a path, and the Board shows them.
public struct WorkMap: Equatable, Sendable {
    /// A band By Mission: a lane of the Board, its cards as a graph.
    public struct Band: Equatable, Sendable, Identifiable {
        /// Its lane, whose header it has.
        public var lane: BoardLane
        /// The cards it shows, but those you hid, as a graph; nil with none, or more than `mostCards`.
        public var graph: WorkMapGraph?
        /// How many cards it shows.
        public var count: Int
        /// Its cards you hid, in its order.
        public var hidden: [BoardItem]

        public var id: BoardLane.Kind { lane.kind }
    }

    /// A set of cards that lines join, for All: as a graph, with the lanes of the Board its cards are in.
    public struct Group: Equatable, Sendable, Identifiable {
        /// Its cards as a graph; nil past `mostCards`.
        public var graph: WorkMapGraph?
        /// Its cards, in the Board's order.
        public var items: [BoardItem]
        /// The lanes of the Board its cards are in, in its order: what it's about.
        public var lanes: [BoardLane.Kind]

        public var id: ItemRef { items[0].ref }
    }

    public static let mostCards = 40

    /// By Mission: a band for each lane of the Board, in its order, but for one with no card, such as one kept only for an
    /// Undo line.
    public private(set) var bands: [Band]
    /// All: each set of cards that lines join, the one with the Board's first card first.
    public private(set) var groups: [Group]
    /// All: the cards no line joins, in the Board's order.
    public private(set) var loose: [BoardItem]
    /// All: the cards you hid, in the Board's order.
    public private(set) var hidden: [BoardItem]

    /// The Map of a board with a lane for each mission, and its sprint work when it has it.
    /// - Parameters:
    ///   - missions: the missions, as By Mission lists them: their orders draw the lines.
    ///   - hidden: the cards you hid.
    public init(_ board: PullRequestBoard, missions: [OrderMission], hidden: MapHidden = MapHidden()) {
        let edges = Edges(missions)
        let hiddenRefs = Set(hidden.refs)
        bands = board.lanes.compactMap { lane in
            let items = Self.items(of: lane)
            guard !items.isEmpty else { return nil }
            let shown = items.filter { !hiddenRefs.contains($0.ref) }
            let graph = shown.isEmpty || shown.count > Self.mostCards ? nil : edges.graph(of: shown)
            return Band(lane: lane, graph: graph, count: shown.count, hidden: items.filter { hiddenRefs.contains($0.ref) })
        }

        var seen: Set<ItemRef> = []
        var all: [BoardItem] = []
        var lanesOf: [ItemRef: [BoardLane.Kind]] = [:]
        for band in bands {
            for item in Self.items(of: band.lane) {
                lanesOf[item.ref, default: []].append(band.lane.kind)
                if seen.insert(item.ref).inserted { all.append(item) }
            }
        }
        let shown = all.filter { !hiddenRefs.contains($0.ref) }
        let lines = edges.lines(among: shown.map(\.ref))
        // Which set of joined cards each is in: the first card of its set, in the Board's order.
        var root = Dictionary(shown.map { ($0.ref, $0.ref) }, uniquingKeysWith: { first, _ in first })
        func find(_ ref: ItemRef) -> ItemRef {
            var ref = ref
            while let parent = root[ref], parent != ref { ref = parent }
            return ref
        }
        let place = Dictionary(shown.enumerated().map { ($1.ref, $0) }, uniquingKeysWith: { first, _ in first })
        for line in lines {
            let (left, right) = (find(line.before), find(line.after))
            guard left != right else { continue }
            if (place[left] ?? 0) < (place[right] ?? 0) { root[right] = left } else { root[left] = right }
        }
        var members: [ItemRef: [BoardItem]] = [:]
        for item in shown { members[find(item.ref), default: []].append(item) }
        var groups: [Group] = []
        var loose: [BoardItem] = []
        for item in shown where find(item.ref) == item.ref {
            let items = members[item.ref] ?? [item]
            guard items.count > 1 else {
                loose.append(item)
                continue
            }
            var kinds: [BoardLane.Kind] = []
            for kind in items.flatMap({ lanesOf[$0.ref] ?? [] }) where !kinds.contains(kind) {
                kinds.append(kind)
            }
            let graph = items.count > Self.mostCards ? nil : edges.graph(of: items)
            groups.append(Group(graph: graph, items: items, lanes: kinds))
        }
        self.groups = groups
        self.loose = loose
        self.hidden = all.filter { hiddenRefs.contains($0.ref) }
    }

    /// A lane's cards, in the order its graph takes them: its pull requests in their mission's order, as By Mission lists
    /// them, then those it doesn't list, as the Board's columns have them; then its work items' own cards, in the Board's
    /// order.
    public static func items(of lane: BoardLane) -> [BoardItem] {
        let cards = lane.cards.enumerated().sorted { lhs, rhs in
            (lhs.element.listIndex ?? .max, lhs.offset) < (rhs.element.listIndex ?? .max, rhs.offset)
        }.map(\.element)
        var seen: Set<ItemRef> = []
        return (cards.map(BoardItem.pullRequest) + lane.tasks.map(BoardItem.work)).filter { seen.insert($0.ref).inserted }
    }

    /// What comes right before what, in every mission's order, with whether it's stacked on it, and what BriefBar knows of
    /// each pull request's status: what the lines between cards are drawn from.
    struct Edges {
        /// What comes right before each, in any mission, and whether it's stacked on it there.
        var before: [ItemRef: [ItemRef: Bool]] = [:]
        var status: [ItemRef: OrderStatus] = [:]

        init(_ missions: [OrderMission]) {
            let steps = missions.flatMap { $0.steps + $0.attached + $0.sameStory }
            // What a pull request's own step says of it first, then what another's prerequisite does.
            for step in steps where status[step.ref] == nil {
                status[step.ref] = step.status
            }
            for step in steps {
                for prerequisite in step.prerequisites where prerequisite.ref != step.ref {
                    let stacked = prerequisite.origins.contains(where: \.isStacked)
                    before[step.ref, default: [:]][prerequisite.ref] = (before[step.ref]?[prerequisite.ref] ?? false) || stacked
                    if status[prerequisite.ref] == nil { status[prerequisite.ref] = prerequisite.status }
                }
            }
        }

        /// What comes before a card, anywhere: what comes right before it, and before those, and so on.
        func ancestors(of ref: ItemRef) -> Set<ItemRef> {
            var reached: Set<ItemRef> = []
            var pending = Array((before[ref] ?? [:]).keys)
            while let next = pending.popLast() {
                guard reached.insert(next).inserted else { continue }
                pending += (before[next] ?? [:]).keys
            }
            return reached
        }

        /// The lines into each of these cards from the nearest of them that come before it: right before it, or through cards
        /// that aren't among them, but for one that another of them comes after, which says it already: not where the two
        /// are in a loop, where neither comes first, nor where that one is done and this one isn't, as it holds nothing then.
        func lines(among refs: [ItemRef]) -> [WorkMapLine] {
            let shown = Set(refs)
            var lines: [WorkMapLine] = []
            for ref in refs {
                // Back from it, breadth first, through what isn't shown, to the nearest of what is, with the way there.
                var way: [ItemRef: [ItemRef]] = [:]
                var found: [ItemRef] = []
                var pending: [(ItemRef, [ItemRef])] = (before[ref] ?? [:]).keys.sorted().map { ($0, []) }
                var visited: Set<ItemRef> = [ref]
                while !pending.isEmpty {
                    let (next, through) = pending.removeFirst()
                    guard visited.insert(next).inserted else { continue }
                    if shown.contains(next) {
                        way[next] = through
                        found.append(next)
                    } else {
                        pending += (before[next] ?? [:]).keys.sorted().map { ($0, [next] + through) }
                    }
                }
                let ancestry = Dictionary(found.map { ($0, ancestors(of: $0)) }, uniquingKeysWith: { first, _ in first })
                // One that another of them comes after says it already, through that one: but not one in a loop with it,
                // where neither comes first, nor one still open that a done one comes after, which no longer holds anything.
                func says(_ later: ItemRef, _ earlier: ItemRef) -> Bool {
                    guard later != earlier, ancestry[later]?.contains(earlier) == true, ancestry[earlier]?.contains(later) != true
                    else { return false }
                    return !isEnded(later) || isEnded(earlier)
                }
                for earlier in found where !found.contains(where: { says($0, earlier) }) {
                    let through = way[earlier] ?? []
                    let style: WorkMapLine.Style = if !through.isEmpty {
                        .through(through)
                    } else {
                        before[ref]?[earlier] == true ? .stacked : .order
                    }
                    lines.append(WorkMapLine(before: earlier, after: ref, style: style))
                }
            }
            return lines
        }

        /// Whether a pull request merged or closed, as BriefBar knows it.
        func isEnded(_ ref: ItemRef) -> Bool {
            status[ref]?.hasEnded ?? false
        }

        /// Whether a card waits for a pull request still open that isn't among these, before reaching one that is: it goes at
        /// least one wave on.
        func waits(_ ref: ItemRef, among shown: Set<ItemRef>) -> Bool {
            var pending = Array((before[ref] ?? [:]).keys)
            var visited: Set<ItemRef> = [ref]
            while let next = pending.popLast() {
                guard visited.insert(next).inserted, !shown.contains(next) else { continue }
                if !(status[next]?.hasEnded ?? false) { return true }
                pending += (before[next] ?? [:]).keys
            }
            return false
        }

        /// These cards as a graph.
        func graph(of items: [BoardItem]) -> WorkMapGraph {
            let refs = items.map(\.ref)
            let shown = Set(refs)
            let waiting = Set(items.filter { !WorkMapGraph.isDone($0) && waits($0.ref, among: shown) }.map(\.ref))
            return WorkMapGraph(items, lines: lines(among: refs), waits: waiting)
        }
    }
}

// MARK: - Words

extension OrderText {
    /// Why a band or a graph of My Work's Map shows no graph: "These 52 cards are too many to draw clearly. The Board shows
    /// them."
    public static func tooManyCards(_ count: Int) -> String {
        "These \(count) cards are too many to draw clearly. The Board shows them."
    }

    /// What a dotted line on My Work's Map goes through, from its start: "Through !4103", "Through !4103 and !4105"; and
    /// where you hid them, "Through !4103, which you hid", "Through !4103 and !4105, one of which you hid".
    /// - Parameter hidden: the cards you hid.
    public static func through(_ refs: [ItemRef], hidden: Set<ItemRef>) -> String {
        let names = refs.map(\.shortOrderLabel)
        let list = names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        let hid = refs.filter(hidden.contains).count
        switch hid {
        case 0: return "Through \(list)"
        case refs.count: return "Through \(list), which you hid"
        case 1: return "Through \(list), one of which you hid"
        default: return "Through \(list), \(hid) of which you hid"
        }
    }
}
