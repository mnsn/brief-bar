import Foundation

// My Work's Map: the Board's cards as a graph of what holds what, as By Mission's Map draws a mission's pull requests, with
// your work on the Board too, and steps: work with no pull request or work item, such as API tests or enabling it in
// production, which you or a session add on the Map (`MapEdits`). By Mission, each lane of the Board is a band, a mission's,
// a story's, or that of what's in no mission, with the steps added there, and, dimmed, what its cards and steps are joined to
// in other bands. All draws each set of cards and steps that lines join as a graph of its own, the one with the Board's first
// card first, their columns lined up, then those no line joins, in a grid. Its columns are what's done, then what can go now,
// then what comes after, wave by wave. A line goes from what comes first to what waits for it: from a pull request to one that
// comes after it in an order, or as you or a session said on the Map, or as Azure DevOps links two work items, a predecessor
// and its successor; through what the Map doesn't show there, such as what you hid, it's dotted. With Others' work, work
// items the Board doesn't have, such as a teammate's task yours waits for, are nodes too, faded, and so is any you added.
// With Done off, what's done leaves the Map, with no dotted line through it, as it holds nothing back. With Parents, the
// parents Azure DevOps gives your work, a story, its feature, that feature's epic, are nodes too, each after the work that's
// part of it, as it's done once that is, with a lighter line from each. Work items Azure DevOps links as Related go in a box
// together. Where the page is too narrow for a graph's columns, they fold into tiers, one under the other, as text wraps
// (`WorkMapFold`). Only where things go, never how they're drawn: the views draw them.

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

/// Others' work, on My Work's Map: whether it shows the work items that aren't yours that your work waits for, and what those
/// wait for, and those that wait right after yours, faded, with whose they are (`WorkMap(showsOthers:)`). Off until you turn
/// it on, remembered.
public enum MapOthersWork {
    public static let defaultsKey = "order.map.others"

    public static func load(from defaults: some SettingsStorage) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    public static func save(_ shows: Bool, to defaults: some SettingsStorage) {
        if shows {
            defaults.set(true, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }
}

/// Done, on My Work's Map: whether it shows what's done, pull requests that merged or closed, work that's resolved or done,
/// and steps done, in its Done column, or leaves them out, for what's left (`WorkMap(showsDone:)`). On until you turn it off,
/// remembered.
public enum MapDoneWork {
    /// Where it's kept, while it's off.
    public static let defaultsKey = "order.map.hidesDone"

    public static func load(from defaults: some SettingsStorage) -> Bool {
        !defaults.bool(forKey: defaultsKey)
    }

    public static func save(_ shows: Bool, to defaults: some SettingsStorage) {
        if shows {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(true, forKey: defaultsKey)
        }
    }
}

/// Parents, on My Work's Map: whether it shows the parents Azure DevOps gives your work items, a story, its feature, that
/// feature's epic, each a node of its own after the work that's part of it (`WorkMap(showsParents:)`). On until you turn it
/// off, remembered.
public enum MapParents {
    /// Where it's kept, while it's off.
    public static let defaultsKey = "order.map.hidesParents"

    public static func load(from defaults: some SettingsStorage) -> Bool {
        !defaults.bool(forKey: defaultsKey)
    }

    public static func save(_ shows: Bool, to defaults: some SettingsStorage) {
        if shows {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(true, forKey: defaultsKey)
        }
    }
}

/// One thing a node of My Work's Map says at a glance, under its title, in a compartment of its own: a symbol and a few words.
/// Of a pull request, what stands in its way, merge conflicts, comments to resolve, who wants changes or else who approved it,
/// and builds that failed, then whether it's a draft; of a work item, its state, the hours left on it, and the sprint it's in,
/// when that isn't the one going on. A node says only those that apply, in that order (`Kind`), but the kinds you hid
/// (`MapGlances`). Its source works them out; the Map only draws them.
public struct MapGlance: Equatable, Sendable {
    /// What it tells, in the order a node says them.
    public enum Kind: String, CaseIterable, Codable, Sendable {
        /// A pull request's merge conflicts with its target branch.
        case conflicts
        /// How many of its comment threads are still active.
        case comments
        /// Who wants changes, or else who approved it.
        case votes
        /// Its builds and checks that failed or expired.
        case builds
        /// That it's a draft.
        case draft
        /// A work item's state.
        case state
        /// The hours left on it.
        case hours
        /// The sprint it's in, when that isn't the one going on.
        case sprint

        /// Its name in At a Glance's menu: "Merge Conflicts".
        public var title: String {
            switch self {
            case .conflicts: "Merge Conflicts"
            case .comments: "Comments to Resolve"
            case .votes: "Approvals and Changes Requested"
            case .builds: "Build Failures"
            case .draft: "Draft"
            case .state: "State"
            case .hours: "Hours Left"
            case .sprint: "Sprint, When Not the Current One"
            }
        }

        /// Whether a pull request's node says it, rather than a work item's.
        public var isAboutPullRequests: Bool {
            switch self {
            case .conflicts, .comments, .votes, .builds, .draft: true
            case .state, .hours, .sprint: false
            }
        }
    }

    public var kind: Kind
    /// What its node says, in a few words: "Merge conflicts", "2 to resolve", "Priya approved", "Build failed", "3 h left".
    public var words: String
    /// What its node says after its symbol where its words don't fit, how many: 2 comments to resolve, 3 approvals; nil for
    /// its symbol alone.
    public var count: Int?
    /// What it means for you, for its color: something's wrong, it waits on you, or it's done; nil for none of those.
    public var state: ItemState?
    /// Its SF Symbol, before its words; nil for its words alone, as a work item's state, whose node starts with its symbol.
    public var symbol: String?
    /// All it says, for its tooltip and VoiceOver: "2 comments to resolve", "Build failed: shop-web CI · Run unit tests".
    public var sentence: String

    public init(
        _ kind: Kind, _ words: String, count: Int? = nil, state: ItemState? = nil, symbol: String? = nil, sentence: String? = nil
    ) {
        self.kind = kind
        self.words = words
        self.count = count
        self.state = state
        self.symbol = symbol
        self.sentence = sentence ?? words
    }
}

/// At a Glance, over My Work's Map: which of what nodes can say at a glance (`MapGlance`) they say, every kind until you hide
/// it, remembered by the kinds you hid (`order.map.hiddenGlances`), so that a kind a later version adds shows.
public struct MapGlances: Equatable, Sendable {
    public static let defaultsKey = "order.map.hiddenGlances"

    /// The kinds you hid.
    public private(set) var hidden: Set<MapGlance.Kind>

    public init(hidden: Set<MapGlance.Kind> = []) {
        self.hidden = hidden
    }

    public func shows(_ kind: MapGlance.Kind) -> Bool {
        !hidden.contains(kind)
    }

    /// What a node says of these: those of the kinds you didn't hide, in their order.
    public func shown(_ glances: [MapGlance]) -> [MapGlance] {
        glances.filter { shows($0.kind) }
    }

    /// As it is with a kind shown, or hidden.
    public func setting(_ kind: MapGlance.Kind, shown: Bool) -> MapGlances {
        var glances = self
        if shown {
            glances.hidden.remove(kind)
        } else {
            glances.hidden.insert(kind)
        }
        return glances
    }

    /// What you chose last: every kind until you hide one. A name it doesn't know is left out.
    public static func load(from defaults: some SettingsStorage) -> MapGlances {
        let names = defaults.object(forKey: defaultsKey) as? [String] ?? []
        return MapGlances(hidden: Set(names.compactMap(MapGlance.Kind.init(rawValue:))))
    }

    /// Keeps the kinds you hid, by name, in their order; nothing once every kind shows.
    public func save(to defaults: some SettingsStorage) {
        if hidden.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(MapGlance.Kind.allCases.filter(hidden.contains).map(\.rawValue), forKey: Self.defaultsKey)
        }
    }
}

/// The cards and steps you hid on My Work's Map, as they're not your focus now: by reference, the one you hid last first, at
/// most `mostCards` of them, in the preferences (`order.map.hidden`), never a title. Hiding one changes only the Map: the
/// Board, Up Next and every count still have it.
public struct MapHidden: Equatable, Sendable {
    public static let defaultsKey = "order.map.hidden"
    /// How many it keeps: past them, the one you hid longest ago shows again.
    public static let mostCards = 300

    /// The one you hid last first.
    public private(set) var nodes: [MapNodeID]

    /// - Parameter nodes: the one you hid last first; each once, the first `mostCards` of them.
    public init(_ nodes: [MapNodeID] = []) {
        var seen: Set<MapNodeID> = []
        self.nodes = Array(nodes.filter { seen.insert($0).inserted }.prefix(Self.mostCards))
    }

    public var isEmpty: Bool {
        nodes.isEmpty
    }

    public func contains(_ node: MapNodeID) -> Bool {
        nodes.contains(node)
    }

    /// Hides a card or a step, the one you hid last now. Whether it wasn't hidden already.
    @discardableResult
    public mutating func hide(_ node: MapNodeID) -> Bool {
        guard !nodes.contains(node) else { return false }
        nodes.insert(node, at: 0)
        if nodes.count > Self.mostCards { nodes.removeLast(nodes.count - Self.mostCards) }
        return true
    }

    /// Shows cards and steps again. Whether any was hidden.
    @discardableResult
    public mutating func show(_ shown: some Sequence<MapNodeID>) -> Bool {
        let shown = Set(shown)
        let count = nodes.count
        nodes.removeAll { shown.contains($0) }
        return nodes.count != count
    }

    /// Forgets the cards of these kinds, as their source goes. Whether any went.
    @discardableResult
    public mutating func forget(_ kinds: Set<ItemRef.Kind>) -> Bool {
        show(nodes.filter { $0.ref.map { kinds.contains($0.kind) } ?? false })
    }

    /// Forgets the steps that are gone, but these. Whether any went.
    @discardableResult
    public mutating func keep(steps: Set<UUID>) -> Bool {
        show(nodes.filter { $0.stepID.map { !steps.contains($0) } ?? false })
    }

    /// What the preferences keep, without what this build can't read.
    public static func load(from defaults: some SettingsStorage) -> MapHidden {
        MapHidden(((defaults.object(forKey: defaultsKey) as? [String]) ?? []).compactMap(MapNodeID.init))
    }

    public func save(to defaults: some SettingsStorage) {
        if nodes.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(nodes.map(\.description), forKey: Self.defaultsKey)
        }
    }
}

// MARK: - A graph

/// A work item on the Map that the Board doesn't have, by its reference: someone else's that your work waits for, or that
/// waits for yours, with Others' work (`WorkMap(showsOthers:)`); one you added to the Map (`MapEdits.addItem`); or, with
/// Parents, one Azure DevOps gives as the parent of your work, or of one of its parents (`WorkMap(showsParents:)`).
public struct MapWorkItem: Equatable, Sendable, Identifiable {
    public var ref: ItemRef
    /// Resolved, done or removed: it holds nothing back.
    public var isDone: Bool
    /// It's assigned to you, as one of yours outside the sprint can be.
    public var isYours: Bool
    /// You added it to the Map, rather than its lines bringing it there.
    public var isAdded: Bool
    /// The page knows what it is: one you added that it hasn't read yet isn't.
    public var isKnown: Bool
    /// Parents brought it there, as the parent of your work, or of one of its parents.
    public var isParent: Bool

    public init(
        ref: ItemRef, isDone: Bool = false, isYours: Bool = false, isAdded: Bool = false, isKnown: Bool = true, isParent: Bool = false
    ) {
        self.ref = ref
        self.isDone = isDone
        self.isYours = isYours
        self.isAdded = isAdded
        self.isKnown = isKnown
        self.isParent = isParent
    }

    public var id: MapNodeID { .card(ref) }
}

/// Two work items Azure DevOps links as Related, by their references, either way round: on the Map, they go in a box together
/// (`WorkMap(related:)`).
public struct MapRelated: Hashable, Comparable, Sendable {
    /// The one that comes first, by its reference.
    public let first: ItemRef
    public let second: ItemRef

    public init(_ one: ItemRef, _ other: ItemRef) {
        (first, second) = other < one ? (other, one) : (one, other)
    }

    public static func < (lhs: MapRelated, rhs: MapRelated) -> Bool {
        (lhs.first, lhs.second) < (rhs.first, rhs.second)
    }
}

/// What a node of the Map is: a card of the Board, a step, or a work item the Board doesn't have.
public enum WorkMapItem: Equatable, Sendable, Identifiable {
    case card(BoardItem)
    case step(MapStep)
    case workItem(MapWorkItem)

    public var id: MapNodeID {
        switch self {
        case .card(let item): .card(item.ref)
        case .step(let step): .step(step.id)
        case .workItem(let item): item.id
        }
    }

    /// Whether it holds nothing back now: a pull request that merged or closed, work that's resolved or done, a step done.
    public var isDone: Bool {
        switch self {
        case .card(let item): WorkMapGraph.isDone(item)
        case .step(let step): step.isDone
        case .workItem(let item): item.isDone
        }
    }

    public var card: BoardItem? {
        if case .card(let item) = self { return item }
        return nil
    }

    public var step: MapStep? {
        if case .step(let step) = self { return step }
        return nil
    }

    public var workItem: MapWorkItem? {
        if case .workItem(let item) = self { return item }
        return nil
    }
}

/// A column of the Map: what's done, or a wave of what's left.
public enum WorkMapColumn: Hashable, Comparable, Sendable {
    /// Pull requests that merged or closed, work that's resolved or done, and steps done: what holds nothing back now.
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

    public static func < (lhs: WorkMapColumn, rhs: WorkMapColumn) -> Bool {
        switch (lhs, rhs) {
        case (.done, .wave): true
        case (.wave(let left), .wave(let right)): left < right
        default: false
        }
    }
}

/// How the Map knows that one thing waits for another.
public enum WorkMapLink: Hashable, Sendable {
    /// The later pull request targets the earlier one's branch, or comes right after it in a GitHub stack.
    case stacked
    /// It comes after it in an order: a session's, a story's, or as you changed a mission.
    case order
    /// Azure DevOps links their work items: the earlier one is the later one's predecessor.
    case azureDevOps
    /// You, or a session, said so on the Map.
    case said(MapAuthor)
}

/// A line of the Map, from a card or step to one that waits for it.
public struct WorkMapLine: Hashable, Sendable {
    public enum Style: Hashable, Sendable {
        /// Stacked: the later one targets the earlier one's branch, or comes right after it in a GitHub stack.
        case stacked
        /// It comes after it, as an order says.
        case order
        /// Azure DevOps links their work items, a predecessor and its successor.
        case azureDevOps
        /// You, or a session, said it waits for it, on the Map.
        case said(MapAuthor)
        /// It waits for it through these, which the Map doesn't show there, nearest to it last: what you hid, pull requests
        /// that aren't on your board, and, By Mission, what's in another band.
        case through([MapNodeID])
        /// It's part of it: Azure DevOps gives the later one as its parent, or as a parent of its parent where the Map doesn't
        /// show those between. The parent waits for it, as it's done once its children are.
        case parent
    }

    public var before: MapNodeID
    public var after: MapNodeID
    public var style: Style
    /// The rows it runs along through the columns between its ends, from left to right: none between neighbouring columns.
    public var rows: [Int]

    public init(before: MapNodeID, after: MapNodeID, style: Style, rows: [Int] = []) {
        self.before = before
        self.after = after
        self.style = style
        self.rows = rows
    }
}

/// A card or step of the Map, in its place.
public struct WorkMapNode: Equatable, Sendable, Identifiable {
    public var item: WorkMapItem
    public var column: Int
    public var row: Int
    /// By Mission, for one of another band that this band's are joined to, shown dimmed: that band's lane. Nil for the band's
    /// own, and with All.
    public var elsewhere: BoardLane.Kind?

    public var id: MapNodeID { item.id }
}

/// Cards and work items Azure DevOps links as Related, on the Map: a box round them, across these columns and rows, which
/// nothing else of the graph is in.
public struct WorkMapBox: Equatable, Sendable {
    /// Its cards and work items, column by column, each from the top.
    public var members: [MapNodeID]
    public var columns: ClosedRange<Int>
    public var rows: ClosedRange<Int>

    public init(members: [MapNodeID], columns: ClosedRange<Int>, rows: ClosedRange<Int>) {
        self.members = members
        self.columns = columns
        self.rows = rows
    }
}

/// Cards and steps of the Map as a graph, in columns, from left to right: what's done, then wave by wave. In each column, those
/// lines join come first, ordered to cross as few lines as it finds, and each where the lines into it come from, so that a
/// chain runs straight; those no line joins go after them. A line that skips columns keeps a row of each to itself, as a
/// layered drawing's long edges do, so that no card sits on it. Those Azure DevOps links as Related sit together, in rows of
/// their own across their columns, in a box (`WorkMapBox`).
public struct WorkMapGraph: Equatable, Sendable {
    public private(set) var columns: [WorkMapColumn]
    /// Column by column, each from the top: as VoiceOver reads them.
    public private(set) var nodes: [WorkMapNode]
    public private(set) var lines: [WorkMapLine]
    /// How many rows it takes.
    public private(set) var rows: Int
    /// How many of its lines cross, as it's laid out.
    public private(set) var crossings: Int
    /// The boxes round those Azure DevOps links as Related, in the order their first ones come.
    public private(set) var boxes: [WorkMapBox]

    /// Whether a card counts as done: a pull request that merged or closed, or work that's resolved or done.
    public static func isDone(_ item: BoardItem) -> Bool {
        switch item {
        case .pullRequest(let card): card.step?.status.hasEnded ?? (card.stage == .merged)
        case .work(let task): !task.work.progress.isOpen
        }
    }

    /// The columns each line goes from and to, in their order.
    public var spans: [ClosedRange<Int>] {
        let column = Dictionary(nodes.map { ($0.id, $0.column) }, uniquingKeysWith: { first, _ in first })
        return lines.map { line in
            let from = column[line.before] ?? 0
            return from...max(from, column[line.after] ?? from)
        }
    }

    /// The rows its cards, steps, lines and boxes take in these columns, from the top: all a tier of a fold has
    /// (`WorkMapFold`), so that it's no taller than they are.
    public func rows(in columns: Range<Int>) -> [Int] {
        let column = Dictionary(nodes.map { ($0.id, $0.column) }, uniquingKeysWith: { first, _ in first })
        var taken = Set(nodes.filter { columns.contains($0.column) }.map(\.row))
        for line in lines {
            guard let from = column[line.before] else { continue }
            for (offset, row) in line.rows.enumerated() where columns.contains(from + 1 + offset) {
                taken.insert(row)
            }
        }
        for box in boxes where box.columns.overlaps(columns) {
            taken.formUnion(box.rows)
        }
        return taken.sorted()
    }

    /// Lays out cards and steps, in the order they come, and the lines between them, which come into one that's still to do.
    /// - Parameters:
    ///   - waits: those that wait for something it doesn't show, such as a pull request in another mission: each goes at
    ///     least one wave on.
    ///   - elsewhere: By Mission, those of other bands, with their bands.
    ///   - boxes: those Azure DevOps links as Related, each set of them in a box.
    ///   - shared: the columns it has, as All's graphs share them, so that they line up; nil for those its own take.
    init(
        _ items: [WorkMapItem], lines: [WorkMapLine], waits: Set<MapNodeID> = [], elsewhere: [MapNodeID: BoardLane.Kind] = [:],
        boxes: [Set<MapNodeID>] = [], columns shared: [WorkMapColumn]? = nil
    ) {
        let ids = items.map(\.id)
        let index = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let done = Set(items.filter(\.isDone).map(\.id))
        let lines = lines.filter { index[$0.before] != nil && index[$0.after] != nil && !done.contains($0.after) }
        let place = Self.places(items, lines: lines, waits: waits)
        columns = shared ?? Set(place.values).sorted()
        let columnIndex = Dictionary(columns.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let columnOf = Dictionary(ids.map { ($0, place[$0].flatMap { columnIndex[$0] } ?? 0) }, uniquingKeysWith: { first, _ in first })

        // A line that skips columns passes through a slot of each between its ends, in the box its ends are both in.
        var layout = Layout(columns: columns.count)
        for id in ids {
            layout.add(.node(id), in: columnOf[id] ?? 0)
        }
        let boxed = boxes.map { $0.filter { index[$0] != nil } }.filter { $0.count > 1 }
        for (number, box) in boxed.enumerated() {
            for id in box { layout.boxOf[.node(id)] = number }
        }
        var forwards: [WorkMapLine] = []
        for line in lines {
            guard let from = columnOf[line.before], let to = columnOf[line.after], from < to else { continue }
            forwards.append(line)
            let box = layout.boxOf[.node(line.before)].flatMap { layout.boxOf[.node(line.after)] == $0 ? $0 : nil }
            var previous = Slot.node(line.before)
            for column in (from + 1)..<to {
                let passing = Slot.passing(forwards.count - 1, column)
                layout.add(passing, in: column)
                layout.boxOf[passing] = box
                layout.join(previous, passing)
                previous = passing
            }
            layout.join(previous, .node(line.after))
        }
        layout.arrange()

        rows = layout.height
        crossings = layout.crossings()
        nodes = items.map { item in
            WorkMapNode(item: item, column: columnOf[item.id] ?? 0, row: layout.row[.node(item.id)] ?? 0, elsewhere: elsewhere[item.id])
        }.sorted { ($0.column, $0.row) < ($1.column, $1.row) }
        self.lines = forwards.enumerated().map { number, line in
            var line = line
            let from = columnOf[line.before] ?? 0, to = columnOf[line.after] ?? 0
            line.rows = to - from > 1 ? ((from + 1)..<to).map { layout.row[.passing(number, $0)] ?? 0 } : []
            return line
        }
        let placed = nodes
        self.boxes = boxed.indices.compactMap { number -> WorkMapBox? in
            guard let span = layout.boxes[number] else { return nil }
            let members = placed.filter { layout.boxOf[.node($0.id)] == number }.map(\.id)
            return WorkMapBox(members: members, columns: span.columns, rows: span.rows)
        }
    }

    /// Where each goes: Done, for what's done; else a wave after the last of what comes into it, and, for one that waits for
    /// something it doesn't show, at least one wave on. Those in a loop of lines, where none can go first, share a wave, as
    /// far on as what came into any of them, and what comes after the loop comes after that.
    static func places(_ items: [WorkMapItem], lines: [WorkMapLine], waits: Set<MapNodeID>) -> [MapNodeID: WorkMapColumn] {
        let ids = items.map(\.id)
        let members = Set(ids)
        let done = Set(items.filter(\.isDone).map(\.id))
        let open = lines.filter {
            members.contains($0.before) && members.contains($0.after) && !done.contains($0.before) && !done.contains($0.after)
        }
        let loops = Self.loops(ids.filter { !done.contains($0) }, lines: open)
        let loopOf = Dictionary(
            loops.enumerated().flatMap { number, loop in loop.map { ($0, number) } }, uniquingKeysWith: { first, _ in first }
        )
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
        var place: [MapNodeID: WorkMapColumn] = [:]
        for id in ids {
            place[id] = done.contains(id) ? .done : .wave(loopOf[id].map { loopWave[$0] } ?? 0)
        }
        return place
    }

    /// What takes a row in a column: a card or step, or a line passing through it.
    enum Slot: Hashable {
        case node(MapNodeID)
        /// The line of that number, as `init` counts those it draws, in that column.
        case passing(Int, Int)
    }

    /// The loops among these, by these lines, each one alone where it's in none, in the order their first ones come, each in
    /// that order: their strongly connected components, as Tarjan finds them.
    static func loops(_ ids: [MapNodeID], lines: [WorkMapLine]) -> [[MapNodeID]] {
        let members = Set(ids)
        var next: [MapNodeID: [MapNodeID]] = [:]
        for line in lines where members.contains(line.before) && members.contains(line.after) {
            next[line.before, default: []].append(line.after)
        }
        var counter = 0
        var number: [MapNodeID: Int] = [:]
        var lowest: [MapNodeID: Int] = [:]
        var stack: [MapNodeID] = []
        var onStack: Set<MapNodeID> = []
        var found: [[MapNodeID]] = []
        func visit(_ id: MapNodeID) {
            number[id] = counter
            lowest[id] = counter
            counter += 1
            stack.append(id)
            onStack.insert(id)
            for later in next[id] ?? [] {
                if number[later] == nil {
                    visit(later)
                    lowest[id] = min(lowest[id] ?? 0, lowest[later] ?? 0)
                } else if onStack.contains(later) {
                    lowest[id] = min(lowest[id] ?? 0, number[later] ?? 0)
                }
            }
            guard lowest[id] == number[id] else { return }
            var loop: [MapNodeID] = []
            while let top = stack.popLast() {
                onStack.remove(top)
                loop.append(top)
                if top == id { break }
            }
            found.append(loop)
        }
        for id in ids where number[id] == nil {
            visit(id)
        }
        let place = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return found.map { loop in loop.sorted { (place[$0] ?? 0) < (place[$1] ?? 0) } }
            .sorted { (place[$0[0]] ?? 0) < (place[$1[0]] ?? 0) }
    }

    /// Where each slot goes: its column, its order there, and its row.
    struct Layout {
        var columns: [[Slot]]
        var predecessors: [Slot: [Slot]] = [:]
        var successors: [Slot: [Slot]] = [:]
        var row: [Slot: Int] = [:]
        /// The box each slot is in, by its number: a card or step Azure DevOps links as Related, or a line passing between two
        /// of the same box.
        var boxOf: [Slot: Int] = [:]
        /// The columns and rows each box keeps to itself, by its number, once it has them.
        private(set) var boxes: [Int: Kept] = [:]

        /// The columns and rows a box keeps.
        struct Kept {
            var columns: ClosedRange<Int>
            var rows: ClosedRange<Int>
        }

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

        /// Whether a line joins a slot, or it's in a box: those its column orders.
        func isTied(_ slot: Slot) -> Bool {
            isJoined(slot) || boxOf[slot] != nil
        }

        /// Orders each column, the slots lines join or boxes keep first, by where their neighbours are, a few times each way,
        /// a box's together; then gives each a row: where the lines into it come from, as far as the slots above it and the
        /// boxes let it; then swaps neighbours while that crosses fewer lines, but never into or out of a box; then raises
        /// each as far as it can go, as a swap or a box can leave free rows above it. Each swap weighs only the lines it
        /// changes, rather than counting every crossing again, as a graph with many long lines has many slots.
        mutating func arrange() {
            columns = columns.map { slots in slots.filter { isTied($0) } + slots.filter { !isTied($0) } }
            var order: [Slot: Double] = [:]
            for column in columns.indices { sort(column, by: [:], order: &order) }
            for _ in 0..<4 {
                for column in columns.indices.dropFirst() { sort(column, by: predecessors, order: &order) }
                for column in columns.indices.dropLast().reversed() { sort(column, by: successors, order: &order) }
            }
            placeAll()
            var improved = true
            var passes = 0
            while improved, passes < 8 {
                improved = false
                passes += 1
                for column in columns.indices {
                    for at in columns[column].indices.dropLast() {
                        let (upper, lower) = (columns[column][at], columns[column][at + 1])
                        guard isJoined(upper), isJoined(lower), boxOf[upper] == boxOf[lower] else { continue }
                        guard crossingsGained(swapping: upper, lower) < 0 else { continue }
                        swapRows(upper, lower, column: column, at: at)
                        improved = true
                    }
                }
            }
            raise()
        }

        /// Moves each slot no box keeps up, column by column, in their order, as far as where the lines into it come from, the
        /// slot above it and the boxes let it: a slot that a box pushed down, or that swapped rows with one, can have free rows
        /// above it that it wanted, and what comes after it follows it up. Each stays below the slot above it, so every column
        /// keeps its order, and as many lines cross.
        private mutating func raise() {
            for column in columns.indices {
                var last = -1
                for slot in columns[column] {
                    guard let at = row[slot] else { continue }
                    if boxOf[slot] == nil {
                        let from = (predecessors[slot] ?? []).compactMap { row[$0] }.sorted()
                        let wanted = from.isEmpty ? last + 1 : from[(from.count - 1) / 2]
                        row[slot] = min(at, free(from: max(wanted, last + 1), height: 1, columns: column...column))
                    }
                    last = row[slot] ?? at
                }
            }
        }

        /// Orders a column's slots that lines join or boxes keep by the average place of their neighbours on one side,
        /// keeping their order where they have none there, or the same; a box's together, where theirs are on average; the
        /// rest stay last. `order` has each slot's place in its column, which this keeps for the column it orders.
        private mutating func sort(_ column: Int, by neighbours: [Slot: [Slot]], order: inout [Slot: Double]) {
            let slots = columns[column]
            var keys: [Double] = []
            for (index, slot) in slots.enumerated() {
                let around = (neighbours[slot] ?? []).compactMap { order[$0] }
                keys.append(around.isEmpty ? Double(index) : around.reduce(0, +) / Double(around.count))
            }
            var total: [Int: Double] = [:]
            var count: [Int: Int] = [:]
            for (index, slot) in slots.enumerated() {
                guard let box = boxOf[slot] else { continue }
                total[box, default: 0] += keys[index]
                count[box, default: 0] += 1
            }
            var tied: [(slot: Slot, key: (Double, Int, Double, Int))] = []
            var rest: [Slot] = []
            for (index, slot) in slots.enumerated() {
                let key = keys[index]
                if let box = boxOf[slot] {
                    let mean = (total[box] ?? key) / Double(count[box] ?? 1)
                    tied.append((slot, (mean, box + 1, key, index)))
                } else if isJoined(slot) {
                    tied.append((slot, (key, 0, key, index)))
                } else {
                    rest.append(slot)
                }
            }
            tied.sort { $0.key < $1.key }
            columns[column] = tied.map(\.slot) + rest
            for (index, slot) in columns[column].enumerated() { order[slot] = Double(index) }
        }

        /// How many more lines would cross, fewer below zero, were two neighbours of a column, `upper` right above `lower`,
        /// to swap rows: only lines into or out of both change, each two on the same side crossing where they didn't, or the
        /// other way round, but two that share their other end, which never cross; as `crossings()` counts them.
        private func crossingsGained(swapping upper: Slot, _ lower: Slot) -> Int {
            var gained = 0
            for neighbours in [predecessors, successors] {
                for first in neighbours[upper] ?? [] {
                    for second in neighbours[lower] ?? [] where first != second {
                        // They cross now where the upper one's other end is below the lower one's.
                        gained += (row[first] ?? 0) > (row[second] ?? 0) ? -1 : 1
                    }
                }
            }
            return gained
        }

        /// Gives every slot its row, column by column, in their order: each where the middle of the lines into it come from,
        /// but below the slot above it. A box keeps rows to itself across its columns, as many as it has slots in any one,
        /// from where its first one wants them, below the slots above it and clear of other boxes; its slots go in those, in
        /// their order, and nothing else does.
        private mutating func placeAll() {
            let spans = boxSpans()
            for column in columns.indices {
                var last = -1
                var previous: [Int: Int] = [:]
                var left: [Int: Int] = [:]
                for slot in columns[column] {
                    if let box = boxOf[slot] { left[box, default: 0] += 1 }
                }
                for slot in columns[column] {
                    let from = (predecessors[slot] ?? []).compactMap { row[$0] }.sorted()
                    let wanted = from.isEmpty ? last + 1 : from[(from.count - 1) / 2]
                    let at: Int
                    if let box = boxOf[slot], let span = spans[box] {
                        let rows = boxes[box]?.rows ?? keep(box, span: span, from: max(wanted, last + 1))
                        left[box, default: 1] -= 1
                        let lowest = (previous[box] ?? rows.lowerBound - 1) + 1
                        at = min(max(wanted, lowest), rows.upperBound - (left[box] ?? 0))
                        previous[box] = at
                    } else {
                        at = free(from: max(wanted, last + 1), height: 1, columns: column...column)
                    }
                    row[slot] = at
                    last = max(last, at)
                }
                columns[column].sort { (row[$0] ?? 0) < (row[$1] ?? 0) }
            }
        }

        /// Each box's columns, from its first slot's to its last's, and how many rows it needs: as many as it has slots in
        /// any one of them.
        private func boxSpans() -> [Int: (columns: ClosedRange<Int>, height: Int)] {
            var counts: [Int: [Int: Int]] = [:]
            for (column, slots) in columns.enumerated() {
                for slot in slots {
                    if let box = boxOf[slot] { counts[box, default: [:]][column, default: 0] += 1 }
                }
            }
            return counts.compactMapValues { perColumn -> (columns: ClosedRange<Int>, height: Int)? in
                guard let first = perColumn.keys.min(), let last = perColumn.keys.max() else { return nil }
                return (first...last, perColumn.values.max() ?? 1)
            }
        }

        /// Gives a box the first rows it needs from `start` on that no other box keeps in its columns.
        private mutating func keep(_ box: Int, span: (columns: ClosedRange<Int>, height: Int), from start: Int) -> ClosedRange<Int> {
            let first = free(from: start, height: span.height, columns: span.columns)
            let rows = first...(first + span.height - 1)
            boxes[box] = Kept(columns: span.columns, rows: rows)
            return rows
        }

        /// The first of `height` rows from `start` on that no box keeps in any of these columns: the lowest, whichever order
        /// it meets them in, as each it moves past is one those rows can't start before.
        private func free(from start: Int, height: Int, columns span: ClosedRange<Int>) -> Int {
            var at = start
            var moved = true
            while moved {
                moved = false
                for kept in boxes.values where kept.columns.overlaps(span) && kept.rows.overlaps(at...(at + height - 1)) {
                    at = kept.rows.upperBound + 1
                    moved = true
                }
            }
            return at
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

// MARK: - Folding

/// How a canvas of the Map folds its columns where they don't all fit across the page, as with a card's details beside it:
/// into tiers, one under the other, as text wraps, each with as many columns as fit, from the left. A line from a tier to a
/// later one wraps round, down and back to the start of the next. It folds where the fewest lines cross, so that as few as
/// it can wrap, and, of those, the first tiers as full as they can be.
public struct WorkMapFold: Equatable, Sendable {
    /// How many columns it folds.
    public let columns: Int
    /// The column each tier starts at, from the top: [0] for one tier, as when they all fit.
    public let starts: [Int]

    /// Columns that all fit across: one tier.
    public init(columns: Int) {
        self.columns = columns
        starts = [0]
    }

    /// - Parameters:
    ///   - columns: how many columns there are.
    ///   - across: how many fit across, at least one: it folds into as few tiers as that takes.
    ///   - spans: the columns each line goes from and to, of every graph on the canvas, as they share its columns.
    public init(columns: Int, across: Int, spans: [ClosedRange<Int>]) {
        let across = max(across, 1)
        self.columns = columns
        guard columns > across else {
            starts = [0]
            return
        }
        // How many lines a fold before each column cuts: those from a column before it to it or one after it.
        var cut = Array(repeating: 0, count: columns + 1)
        for span in spans where span.lowerBound < span.upperBound && span.lowerBound < columns {
            for column in (span.lowerBound + 1)...min(span.upperBound, columns) {
                cut[column] += 1
            }
        }
        // fewest[t][c]: the fewest lines that folding the columns from c on into t tiers cuts; next[t][c]: where the first of
        // its folds goes, the furthest along of those that cut as few.
        let tiers = (columns + across - 1) / across
        let none = Int.max / 2
        var fewest = Array(repeating: Array(repeating: none, count: columns + 1), count: tiers + 1)
        var next = Array(repeating: Array(repeating: columns, count: columns + 1), count: tiers + 1)
        for column in 0..<columns where columns - column <= across {
            fewest[1][column] = 0
        }
        if tiers > 1 {
            for tier in 2...tiers {
                for column in 0..<columns {
                    let furthest = min(column + across, columns - 1)
                    for fold in stride(from: furthest, through: column + 1, by: -1) where fewest[tier - 1][fold] < none {
                        let cuts = cut[fold] + fewest[tier - 1][fold]
                        if cuts < fewest[tier][column] {
                            fewest[tier][column] = cuts
                            next[tier][column] = fold
                        }
                    }
                }
            }
        }
        var starts = [0]
        for tier in stride(from: tiers, to: 1, by: -1) {
            starts.append(next[tier][starts[starts.count - 1]])
        }
        self.starts = starts
    }

    public var tiers: Int {
        starts.count
    }

    /// The tier a column is in.
    public func tier(of column: Int) -> Int {
        starts.lastIndex { $0 <= column } ?? 0
    }

    /// A tier's columns.
    public func columns(ofTier tier: Int) -> Range<Int> {
        starts[tier]..<(tier + 1 < starts.count ? starts[tier + 1] : columns)
    }

    /// Whether a line wraps round into a tier: it goes from a tier before it to that one or one after it.
    public func wraps(_ span: ClosedRange<Int>, into tier: Int) -> Bool {
        tier > 0 && tier < starts.count && span.lowerBound < starts[tier] && starts[tier] <= span.upperBound
    }
}

// MARK: - The Map

/// My Work's Map, as the Board has its cards now, with the steps and lines you and sessions added: a band for each of its lanes,
/// By Mission; and, for All, a graph for each set of cards and steps that lines join, or Azure DevOps links as Related, and
/// those nothing joins. A graph has no more than `mostCards` of its own: past them it's too many to read but to follow a path,
/// and the Board shows them.
public struct WorkMap: Equatable, Sendable {
    /// A band By Mission: a lane of the Board, its cards and the steps added there as a graph, with what they're joined to in
    /// other bands, dimmed.
    public struct Band: Equatable, Sendable, Identifiable {
        /// Its lane, whose header it has.
        public var lane: BoardLane
        /// The key of its lane's order, which a step added in it keeps as where it was added.
        public var key: LaneOrderKey
        /// Its cards and steps, but those you hid, as a graph, with what they're joined to elsewhere; nil with none, or more
        /// than `mostCards`.
        public var graph: WorkMapGraph?
        /// How many of its own it shows.
        public var count: Int
        /// Its cards and steps you hid, in its order.
        public var hidden: [WorkMapItem]

        public var id: BoardLane.Kind { lane.kind }
    }

    /// A set of cards and steps that lines join, or Azure DevOps links as Related, for All: as a graph, with the lanes of the
    /// Board they're in.
    public struct Group: Equatable, Sendable, Identifiable {
        /// Its cards and steps as a graph; nil past `mostCards`.
        public var graph: WorkMapGraph?
        /// Its cards and steps, in the Board's order, each band's steps after its cards.
        public var items: [WorkMapItem]
        /// The lanes of the Board they're in, in its order: what it's about.
        public var lanes: [BoardLane.Kind]

        public var id: MapNodeID { items[0].id }
    }

    public static let mostCards = 60
    /// How many of other bands a band shows, at most, dimmed.
    public static let mostElsewhere = 12

    /// By Mission: a band for each lane of the Board, in its order, but for one with nothing on the Map, such as one kept
    /// only for an Undo line, or one whose cards and steps are all done while Done is off; then Not in a mission, for steps
    /// joined to no card, when the Board has no such lane.
    public private(set) var bands: [Band]
    /// All: each set of cards and steps that lines join, or Related links, the one with the Board's first card first.
    public private(set) var groups: [Group]
    /// All: the columns its graphs share, so that they line up.
    public private(set) var columns: [WorkMapColumn]
    /// All: the cards and steps nothing joins, those still to do first, each in the Board's order.
    public private(set) var loose: [WorkMapItem]
    /// All: the cards and steps you hid, in the Board's order, but what's done while Done is off.
    public private(set) var hidden: [WorkMapItem]
    /// Every card, work item and step, hidden or not, in the Board's order, each band's work items and steps after its
    /// cards: what menus list.
    public private(set) var everything: [WorkMapItem]
    /// The work items it has, hidden or not: those with a node of their own, and those with none whose pull requests'
    /// cards stand for them, as what's said of them is said of those cards. + Task offers none of them.
    public private(set) var workItemsOnMap: Set<ItemRef>
    /// Of those, the ones Done leaves out while it's off: those that are done, on their own, or as their pull requests'
    /// cards, all of them done. None while it shows what's done.
    public private(set) var workItemsLeftOut: Set<ItemRef>
    /// Whether it shows what's done, in its Done column (`MapDoneWork`).
    public let showsDone: Bool
    /// How many of its cards, work items and steps are done, but those you hid: what Done shows, or leaves out.
    public private(set) var doneCount: Int
    /// Whether it shows the parents Azure DevOps gives your work items, and theirs (`MapParents`).
    public let showsParents: Bool
    /// Whether Azure DevOps gives any of its work items a parent, shown or not: what Parents is for.
    public private(set) var hasParents: Bool
    private let edges: Edges
    private let byID: [MapNodeID: WorkMapItem]
    /// The band each card and step is in, a card's first.
    private let bandOf: [MapNodeID: BoardLane.Kind]
    /// The lines All draws, between all that shows.
    private let lines: [WorkMapLine]
    /// The dependencies Azure DevOps links between work items, by their references.
    private let azureDevOps: Set<MapEdits.Line>
    /// The work items of yours each pull request's card names (`PullRequestBoard.workOfPullRequests`).
    private let workOfPullRequests: [ItemRef: [ItemRef]]

    /// The Map of a board with a lane for each mission, and its sprint work when it has it.
    /// - Parameters:
    ///   - missions: the missions, as By Mission lists them: their orders draw lines.
    ///   - state: the steps and lines you and sessions added, or took away, and the work items you added
    ///     (`MapEdits.merged`).
    ///   - hidden: the cards and steps you hid.
    ///   - done: the cards that are done on the whole board, while a search shows only some of it (`done(on:)`): what came
    ///     before one it leaves out holds nothing back through it.
    ///   - linked: the work items Show Links links to each pull request on the board, whatever Show shows: what's said of
    ///     one with no card of its own is said of those pull requests' cards, as of those the cards name.
    ///   - azureDevOps: the dependencies Azure DevOps links between work items, each from a predecessor to its successor,
    ///     which waits for it, by their references: what's said of one with no card of its own is said of its pull requests'
    ///     cards, as with what you and sessions said.
    ///   - work: what the page knows of a work item the Board doesn't have, such as a teammate's: whether it's done, and
    ///     whether it's yours; nil for one it doesn't know.
    ///   - showsOthers: Others' work: the work items the Board doesn't have that are still open and that what the Map has
    ///     waits for, and what those wait for, and those that wait right after what it has, are nodes too, at most
    ///     `mostOthers`, the nearest first.
    ///   - showsDone: Done: what's done, in its Done column; off, what's done is off the Map, as what you hid is, but listed
    ///     nowhere, and, as it holds nothing back, with no dotted line through it.
    ///   - parents: the parent Azure DevOps gives each work item it knows one for, by their references.
    ///   - related: the work items Azure DevOps links as Related, two by two: those on the Map go in a box together, with
    ///     those they're related to through others, By Mission only those of the same band.
    ///   - showsParents: Parents: the parents of its work items, and theirs, up their chains, are nodes too, at most
    ///     `mostParents` of them, of those the page knows, each joined by a lighter line to the nearest of what's part of it,
    ///     which it waits for; a pull request's card standing for a work item it names, as with lines.
    public init(
        _ board: PullRequestBoard, missions: [OrderMission], state: MapState = MapState(), hidden: MapHidden = MapHidden(),
        done: Set<ItemRef> = [], linked: [ItemRef: [ItemRef]] = [:], azureDevOps: Set<MapEdits.Line> = [],
        work: (ItemRef) -> MapWorkItem? = { _ in nil }, showsOthers: Bool = false, showsDone: Bool = true,
        parents: [ItemRef: ItemRef] = [:], related: Set<MapRelated> = [], showsParents: Bool = true
    ) {
        // Every card, once, with the lanes it's in.
        var cards: [BoardItem] = []
        var lanesOf: [MapNodeID: [BoardLane.Kind]] = [:]
        var seen: Set<ItemRef> = []
        for lane in board.lanes {
            for item in Self.items(of: lane) {
                lanesOf[.card(item.ref), default: []].append(lane.kind)
                if seen.insert(item.ref).inserted { cards.append(item) }
            }
        }
        var byID = Dictionary(cards.map { (MapNodeID.card($0.ref), WorkMapItem.card($0)) }, uniquingKeysWith: { first, _ in first })
        for step in state.steps {
            byID[.step(step.id)] = .step(step)
        }
        // What's said of a work item with no card of its own is said of the cards of its pull requests: those whose cards name
        // it and, whatever Show shows, those Show Links links it to, so that a line a session told of a task stays with Show.
        var aliases: [ItemRef: [ItemRef]] = [:]
        let named = board.workOfPullRequests.merging(linked) { named, linked in named + linked }
        for (pullRequest, work) in named.sorted(by: { $0.key < $1.key }) where seen.contains(pullRequest) {
            for ref in work where !seen.contains(ref) && aliases[ref]?.contains(pullRequest) != true {
                aliases[ref, default: []].append(pullRequest)
            }
        }
        // The work items you added that the Board doesn't have, nor a pull request's card for them, in the order you added
        // them: as the page knows them, else by their references alone, still to do, until it does.
        var items: [MapWorkItem] = []
        for (ref, _) in state.items.sorted(by: { ($0.value.at, $0.key) < ($1.value.at, $1.key) }) {
            guard !seen.contains(ref), aliases[ref] == nil else { continue }
            var item = work(ref) ?? MapWorkItem(ref: ref, isKnown: false)
            item.isAdded = true
            items.append(item)
            byID[item.id] = .workItem(item)
        }
        // With Parents, each work item's parents up its chain, from your work's, the hidden and the done too: an open story
        // whose tasks are all done still has its node.
        let starts = cards.map(\.ref).filter { $0.kind == .workItem } + items.map(\.ref) + aliases.keys.sorted()
        let climbed = Self.climb(from: starts, parents: parents, items: byID, aliases: aliases, work: work)
        if showsParents {
            for item in climbed.added {
                items.append(item)
                byID[item.id] = .workItem(item)
            }
        }
        // Of the work items the Board doesn't have that lines name, those the page knows are done hold nothing back.
        var known = done
        for ref in Self.workItems(named: state, azureDevOps) where !seen.contains(ref) && work(ref)?.isDone == true {
            known.insert(ref)
        }
        let edges = Edges(
            missions, state: state, items: byID, aliases: aliases, done: known, azureDevOps: azureDevOps,
            parents: showsParents ? climbed.up : [:]
        )
        if showsOthers {
            for item in Self.others(waitingWith: byID, edges: edges, work: work) {
                items.append(item)
                byID[item.id] = .workItem(item)
            }
        }
        // What Azure DevOps links as Related, of a work item a card names as of that card, but a card with itself.
        let nodesOf = { (ref: ItemRef) -> [MapNodeID] in
            byID[.card(ref)] != nil ? [.card(ref)] : (aliases[ref] ?? []).map(MapNodeID.card)
        }
        var relatedNodes: [(MapNodeID, MapNodeID)] = []
        for pair in related.sorted() {
            for one in nodesOf(pair.first) {
                for other in nodesOf(pair.second) where one != other {
                    relatedNodes.append((one, other))
                }
            }
        }

        // Each step, and each work item the Board doesn't have, goes in the band it was added in; else that of the nearest
        // cards it's joined to; else Not in a mission.
        var bandOf = lanesOf.compactMapValues(\.first)
        let keys = Dictionary(board.lanes.map { (LaneOrderKey($0.kind, missions: missions), $0.kind) }, uniquingKeysWith: { first, _ in first })
        let homes: [(MapNodeID, LaneOrderKey?)] = state.steps.map { (MapNodeID.step($0.id), $0.home) }
            + items.map { ($0.id, state.items[$0.ref]?.home) }
        for (node, home) in homes {
            guard let home else { continue }
            if let kind = keys[home] {
                bandOf[node] = kind
            } else if home == .notInAMission {
                // Added in Not in a mission, it stays there, joined to a mission's card or not, though the Board has no
                // such lane.
                bandOf[node] = .notInAMission
            }
        }
        for (node, _) in homes where bandOf[node] == nil {
            bandOf[node] = edges.nearest(node, in: bandOf, order: board.lanes.map(\.kind)) ?? .notInAMission
        }
        var lanes = board.lanes
        if homes.contains(where: { bandOf[$0.0] == .notInAMission }), !lanes.contains(where: { $0.kind == .notInAMission }) {
            lanes.append(BoardLane(kind: .notInAMission, columns: [:]))
        }
        let itemsOf = Dictionary(lanes.map { lane -> (BoardLane.Kind, [WorkMapItem]) in
            let cards: [WorkMapItem] = Self.items(of: lane).map(WorkMapItem.card)
            let work: [WorkMapItem] = items.filter { bandOf[$0.id] == lane.kind }.map(WorkMapItem.workItem)
            let steps: [WorkMapItem] = state.steps.filter { bandOf[.step($0.id)] == lane.kind }.map(WorkMapItem.step)
            return (lane.kind, cards + work + steps)
        }, uniquingKeysWith: { first, _ in first })

        var everything: [WorkMapItem] = []
        var added: Set<MapNodeID> = []
        for lane in lanes {
            for item in itemsOf[lane.kind] ?? [] where added.insert(item.id).inserted {
                everything.append(item)
            }
        }
        let isHidden = Set(hidden.nodes)
        // What's done, while Done is off, is off the Map as what you hid is, but listed nowhere.
        let isLeftOut = { (item: WorkMapItem) in !showsDone && item.isDone }
        let shown = everything.filter { !isHidden.contains($0.id) && !isLeftOut($0) }
        let shownIDs = Set(shown.map(\.id))
        // The lines All draws, between all that shows: those that leave a band bring in, dimmed, what they're joined to.
        let lines = edges.lines(among: shown.map(\.id))

        bands = lanes.compactMap { lane in
            let items = (itemsOf[lane.kind] ?? []).filter { !isLeftOut($0) }
            guard !items.isEmpty else { return nil }
            let own = items.filter { !isHidden.contains($0.id) }
            let ownIDs = Set(own.map(\.id))
            var elsewhere: [MapNodeID: BoardLane.Kind] = [:]
            var others: [WorkMapItem] = []
            for line in lines where ownIDs.contains(line.before) != ownIDs.contains(line.after) {
                let other = ownIDs.contains(line.before) ? line.after : line.before
                guard elsewhere[other] == nil, others.count < Self.mostElsewhere, let item = byID[other] else { continue }
                elsewhere[other] = bandOf[other] ?? .notInAMission
                others.append(item)
            }
            let graph = own.isEmpty || own.count > Self.mostCards
                ? nil
                : edges.graph(of: own + others, elsewhere: elsewhere, boxes: Self.boxes(among: own.map(\.id), related: relatedNodes))
            return Band(
                lane: lane, key: LaneOrderKey(lane.kind, missions: missions), graph: graph, count: own.count,
                hidden: items.filter { isHidden.contains($0.id) }
            )
        }

        // All: which set of joined ones each is in, by lines or as Related, the first of its set in the Board's order.
        var root = Dictionary(shown.map { ($0.id, $0.id) }, uniquingKeysWith: { first, _ in first })
        func find(_ id: MapNodeID) -> MapNodeID {
            var id = id
            while let parent = root[id], parent != id { id = parent }
            return id
        }
        let place = Dictionary(shown.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        func join(_ one: MapNodeID, _ other: MapNodeID) {
            let (left, right) = (find(one), find(other))
            guard left != right else { return }
            if (place[left] ?? 0) < (place[right] ?? 0) { root[right] = left } else { root[left] = right }
        }
        for line in lines {
            join(line.before, line.after)
        }
        for (one, other) in relatedNodes where shownIDs.contains(one) && shownIDs.contains(other) {
            join(one, other)
        }
        var members: [MapNodeID: [WorkMapItem]] = [:]
        for item in shown {
            members[find(item.id), default: []].append(item)
        }
        var sets: [[WorkMapItem]] = []
        var single: [WorkMapItem] = []
        for item in shown where find(item.id) == item.id {
            let items = members[item.id] ?? [item]
            if items.count > 1 { sets.append(items) } else { single.append(item) }
        }
        // Their graphs share their columns, so that what can go now lines up across them, and so on.
        typealias Laid = (items: [WorkMapItem], lines: [WorkMapLine], waits: Set<MapNodeID>, boxes: [Set<MapNodeID>])
        let laidOut = sets.map { items -> Laid? in
            guard items.count <= Self.mostCards else { return nil }
            let ids = Set(items.map(\.id))
            let waits = Set(items.filter { !$0.isDone && edges.waits($0.id, among: shownIDs) }.map(\.id))
            let boxes = Self.boxes(among: items.map(\.id), related: relatedNodes)
            return (items, lines.filter { ids.contains($0.before) && ids.contains($0.after) }, waits, boxes)
        }
        let shared = Set(laidOut.compactMap { $0 }.flatMap { WorkMapGraph.places($0.items, lines: $0.lines, waits: $0.waits).values })
            .sorted()
        columns = shared
        groups = zip(sets, laidOut).map { items, laid in
            var kinds: [BoardLane.Kind] = []
            for item in items {
                let lanes = lanesOf[item.id] ?? (bandOf[item.id].map { [$0] } ?? [])
                for kind in lanes where !kinds.contains(kind) {
                    kinds.append(kind)
                }
            }
            let graph = laid.map { WorkMapGraph($0.items, lines: $0.lines, waits: $0.waits, boxes: $0.boxes, columns: shared) }
            return Group(graph: graph, items: items, lanes: kinds)
        }
        loose = single.filter { !$0.isDone } + single.filter(\.isDone)
        self.hidden = everything.filter { isHidden.contains($0.id) && !isLeftOut($0) }
        self.everything = everything
        self.showsDone = showsDone
        doneCount = everything.filter { $0.isDone && !isHidden.contains($0.id) }.count
        self.showsParents = showsParents
        hasParents = !climbed.up.isEmpty
        self.edges = edges
        self.byID = byID
        self.bandOf = bandOf
        self.lines = lines
        self.azureDevOps = azureDevOps
        workOfPullRequests = board.workOfPullRequests
        let nodes = byID.keys.compactMap(\.ref).filter { $0.kind == .workItem }
        workItemsOnMap = Set(nodes).union(aliases.keys)
        let isDoneCard = { (ref: ItemRef) in byID[.card(ref)]?.isDone == true }
        workItemsLeftOut = showsDone ? [] : Set(nodes.filter(isDoneCard))
            .union(aliases.filter { !$0.value.isEmpty && $0.value.allSatisfy(isDoneCard) }.keys)
    }

    /// At most how many of others' work the Map shows (`init(showsOthers:)`).
    public static let mostOthers = 30
    /// At most how many parents the Map adds nodes for (`init(showsParents:)`).
    public static let mostParents = 30

    /// The parents Azure DevOps gives these work items, and theirs, up their chains, breadth first, and which nodes each of
    /// them and those is part of: each parent as its own card, else as the pull requests' cards that name it, else as a node
    /// added for it, if the page knows it, at most `mostParents` of those; a chain ends at one it doesn't. A card is never
    /// part of itself, as a pull request's that names a task and its story.
    static func climb(
        from starts: [ItemRef], parents: [ItemRef: ItemRef], items: [MapNodeID: WorkMapItem], aliases: [ItemRef: [ItemRef]],
        work: (ItemRef) -> MapWorkItem?
    ) -> (added: [MapWorkItem], up: [MapNodeID: Set<MapNodeID>]) {
        var added: [MapWorkItem] = []
        var has = Set(items.keys)
        func nodes(of ref: ItemRef) -> [MapNodeID] {
            has.contains(.card(ref)) ? [.card(ref)] : (aliases[ref] ?? []).map(MapNodeID.card)
        }
        var up: [MapNodeID: Set<MapNodeID>] = [:]
        var climbed: Set<ItemRef> = []
        var pending = starts
        var next = 0
        while next < pending.count {
            let child = pending[next]
            next += 1
            guard climbed.insert(child).inserted, let parent = parents[child], parent != child else { continue }
            var above = nodes(of: parent)
            if above.isEmpty {
                guard added.count < mostParents, var item = work(parent) else { continue }
                item.isParent = true
                added.append(item)
                has.insert(item.id)
                above = [item.id]
            }
            for node in nodes(of: child) {
                for later in above where later != node {
                    up[node, default: []].insert(later)
                }
            }
            pending.append(parent)
        }
        return (added, up)
    }

    /// The sets of these that Azure DevOps links as Related, each to another of them, or through others of them, each to go in
    /// a box, in the order their first ones come.
    static func boxes(among ids: [MapNodeID], related: [(MapNodeID, MapNodeID)]) -> [Set<MapNodeID>] {
        let place = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var root = Dictionary(ids.map { ($0, $0) }, uniquingKeysWith: { first, _ in first })
        func find(_ id: MapNodeID) -> MapNodeID {
            var id = id
            while let parent = root[id], parent != id { id = parent }
            return id
        }
        for (one, other) in related where place[one] != nil && place[other] != nil {
            let (left, right) = (find(one), find(other))
            guard left != right else { continue }
            if (place[left] ?? 0) < (place[right] ?? 0) { root[right] = left } else { root[left] = right }
        }
        var members: [MapNodeID: Set<MapNodeID>] = [:]
        for id in ids {
            members[find(id), default: []].insert(id)
        }
        return ids.filter { find($0) == $0 }.compactMap { members[$0] }.filter { $0.count > 1 }
    }

    /// The work items these name: those lines join, Azure DevOps' and what you and sessions said, and those you added.
    static func workItems(named state: MapState, _ azureDevOps: Set<MapEdits.Line>) -> Set<ItemRef> {
        let lines = Array(state.lines.keys) + Array(azureDevOps)
        let ends = lines.flatMap { [$0.before.ref, $0.after.ref] }.compactMap { $0 }
        return Set(ends.filter { $0.kind == .workItem } + Array(state.items.keys))
    }

    /// Others' work: the work items the Board doesn't have, still open, that the page knows, that what the Map has and is
    /// still open waits for, and what those wait for, back to the nearest of what's done or isn't a work item, the nearest
    /// first; then those that wait right after what the Map has: at most `mostOthers` of them.
    static func others(
        waitingWith items: [MapNodeID: WorkMapItem], edges: Edges, work: (ItemRef) -> MapWorkItem?
    ) -> [MapWorkItem] {
        var found: [MapWorkItem] = []
        var met = Set(items.keys)
        /// One that's others' work, met for the first time.
        func other(_ node: MapNodeID) -> MapWorkItem? {
            guard found.count < mostOthers, !met.contains(node), let ref = node.ref, ref.kind == .workItem,
                  let item = work(ref), !item.isDone
            else { return nil }
            met.insert(node)
            found.append(item)
            return item
        }
        let open = items.values.filter { !$0.isDone }.map(\.id).sorted()
        var pending = open.flatMap { edges.predecessors($0) }
        while !pending.isEmpty {
            let next = pending.removeFirst()
            if other(next) != nil { pending += edges.predecessors(next) }
        }
        for node in open {
            for later in edges.successors(node) { _ = other(later) }
        }
        return found
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

    /// The cards that are done on a board: what `init`'s `done` takes, from the board a search hasn't narrowed.
    public static func done(on board: PullRequestBoard) -> Set<ItemRef> {
        Set(board.lanes.flatMap(items(of:)).filter(WorkMapGraph.isDone).map(\.ref))
    }

    // MARK: What menus need

    /// A card or step on the Map, hidden or not.
    public func item(_ node: MapNodeID) -> WorkMapItem? {
        byID[node]
    }

    /// The band a card or step is in, By Mission: a card's first.
    public func band(of node: MapNodeID) -> BoardLane.Kind? {
        bandOf[node]
    }

    /// What a card or step waits for right before it, as the orders and the Map's lines say, with how: cards and steps on the
    /// Map, and pull requests and work items that aren't, in order.
    public func waitsFor(_ node: MapNodeID) -> [(node: MapNodeID, link: WorkMapLink)] {
        (edges.before[node] ?? [:]).sorted { $0.key < $1.key }.map { (node: $0.key, link: $0.value) }
    }

    /// What waits for a card or step right after it, in order.
    public func waitingFor(_ node: MapNodeID) -> [MapNodeID] {
        edges.successors(node)
    }

    /// Whether `after` waiting for `before` closes a loop: `before` waits for `after` already, directly or through others,
    /// done or not.
    public func wouldLoop(before: MapNodeID, after: MapNodeID) -> Bool {
        before == after || edges.reaches(before, back: after)
    }

    // MARK: In Azure DevOps

    /// The work items a node stands for in Azure DevOps: a work item's own card, or one the Board doesn't have, that work
    /// item; a pull request's card, the work items of yours it names (`PullRequestBoard.workOfPullRequests`), which it names
    /// only with your sprint work on the Board; none for a step.
    public func workItems(of node: MapNodeID) -> [ItemRef] {
        guard let ref = node.ref else { return [] }
        if ref.kind == .workItem { return [ref] }
        return workOfPullRequests[ref] ?? []
    }

    /// What a line of the Map stands for in Azure DevOps (`MapLineLinks`): a dependency of each work item its later end
    /// stands for on each its earlier end does, in the same organization, never of one on itself; where Azure DevOps links
    /// it, or you or a session said it, only between the work items it was said of. Nil for one that stands for none: a
    /// dotted one, through what the Map doesn't show, one to a parent, one with a step, or with a pull request that names no
    /// work item of yours.
    public func links(of line: WorkMapLine) -> MapLineLinks? {
        if case .through = line.style { return nil }
        if line.style == .parent { return nil }
        let said = edges.facts[MapEdits.Line(line.before, line.after)] ?? []
        let ends = said.isEmpty ? [MapEdits.Line(line.before, line.after)] : said.sorted()
        var pairs: Set<MapEdits.Line> = []
        for end in ends {
            for earlier in workItems(of: end.before) {
                for later in workItems(of: end.after) where earlier != later && earlier.scope == later.scope {
                    pairs.insert(MapEdits.Line(.card(earlier), .card(later)))
                }
            }
        }
        guard !pairs.isEmpty else { return nil }
        return MapLineLinks(pairs: pairs.sorted(), linked: pairs.intersection(azureDevOps))
    }

    /// The lines the Map draws now, between what shows, that stand for dependencies Azure DevOps doesn't link yet, in the
    /// Map's order: what Link All links.
    public var unlinked: [(line: WorkMapLine, links: MapLineLinks)] {
        lines.compactMap { line in
            guard let links = links(of: line), !links.isLinked else { return nil }
            return (line, links)
        }
    }

    /// What comes right before what, in every mission's order, as Azure DevOps links work items and as you and sessions said
    /// on the Map, a work item a pull request's card names standing for that card, and whether each is done: what the lines
    /// are drawn from.
    struct Edges: Equatable, Sendable {
        /// What comes right before each, and how.
        var before: [MapNodeID: [MapNodeID: WorkMapLink]] = [:]
        /// What comes right after each.
        var after: [MapNodeID: Set<MapNodeID>] = [:]
        /// What holds nothing back now: cards and steps that are done, and pull requests the orders say merged or closed.
        var done: Set<MapNodeID> = []
        /// What each line was said of, where Azure DevOps links it, or you or a session said it: between what each was said
        /// of, before a work item a card names stood for that card. A line an order draws alone is said of its cards.
        var facts: [MapEdits.Line: Set<MapEdits.Line>] = [:]
        /// What each is part of, as Azure DevOps gives its parent, with Parents.
        var up: [MapNodeID: Set<MapNodeID>] = [:]
        /// What's part of each.
        var down: [MapNodeID: Set<MapNodeID>] = [:]

        init(
            _ missions: [OrderMission], state: MapState, items: [MapNodeID: WorkMapItem], aliases: [ItemRef: [ItemRef]],
            done known: Set<ItemRef> = [], azureDevOps: Set<MapEdits.Line> = [], parents up: [MapNodeID: Set<MapNodeID>] = [:]
        ) {
            self.up = up
            for (child, parents) in up {
                for parent in parents {
                    down[parent, default: []].insert(child)
                }
            }
            var status: [ItemRef: OrderStatus] = [:]
            let steps = missions.flatMap { $0.steps + $0.attached + $0.sameStory }
            // What a pull request's own step says of it first, then what another's prerequisite does.
            for step in steps where status[step.ref] == nil {
                status[step.ref] = step.status
            }
            for step in steps {
                for prerequisite in step.prerequisites where prerequisite.ref != step.ref {
                    let (earlier, later) = (MapNodeID.card(prerequisite.ref), MapNodeID.card(step.ref))
                    let stacked = prerequisite.origins.contains(where: \.isStacked) || before[later]?[earlier] == .stacked
                    before[later, default: [:]][earlier] = stacked ? .stacked : .order
                    if status[prerequisite.ref] == nil { status[prerequisite.ref] = prerequisite.status }
                }
            }
            func nodes(_ node: MapNodeID) -> [MapNodeID] {
                guard items[node] == nil, let ref = node.ref, let cards = aliases[ref], !cards.isEmpty else { return [node] }
                return cards.map(MapNodeID.card)
            }
            // What Azure DevOps links, of a work item a card names as of that card: where an order has it already, it keeps
            // the order's look.
            for line in azureDevOps.sorted() {
                for earlier in nodes(line.before) {
                    for later in nodes(line.after) where earlier != later {
                        if before[later]?[earlier] == nil { before[later, default: [:]][earlier] = .azureDevOps }
                        facts[MapEdits.Line(earlier, later), default: []].insert(line)
                    }
                }
            }
            // What you and sessions said, the latest of what's said of each line winning, of a work item a card names as of
            // that card: one added where an order, or Azure DevOps, has it already keeps its look, and one taken away goes,
            // on the Map only.
            var said: [MapEdits.Line: MapEdits.LineChange] = [:]
            for (line, change) in state.lines.sorted(by: { $0.key < $1.key }) {
                for earlier in nodes(line.before) {
                    for later in nodes(line.after) where earlier != later {
                        let key = MapEdits.Line(earlier, later)
                        if said[key].map({ $0.at < change.at }) ?? true { said[key] = change }
                        if change.isOn { facts[key, default: []].insert(line) }
                    }
                }
            }
            for (line, change) in said {
                if change.isOn {
                    if before[line.after]?[line.before] == nil { before[line.after, default: [:]][line.before] = .said(change.by) }
                } else {
                    before[line.after]?[line.before] = nil
                }
            }
            for (later, earlier) in before {
                for node in earlier.keys {
                    after[node, default: []].insert(later)
                }
            }
            done = Set(items.filter { $0.value.isDone }.keys).union(known.map(MapNodeID.card))
            for (ref, status) in status where items[.card(ref)] == nil && status.hasEnded {
                done.insert(.card(ref))
            }
        }

        func predecessors(_ node: MapNodeID) -> [MapNodeID] {
            (before[node] ?? [:]).keys.sorted()
        }

        func successors(_ node: MapNodeID) -> [MapNodeID] {
            (after[node] ?? []).sorted()
        }

        /// What a card or step waits for, anywhere: what comes right before it, and before those, and so on, but not past
        /// what's done, which holds nothing back, nor what's before it, and not through `besides`.
        func ancestors(of node: MapNodeID, besides excluded: MapNodeID? = nil) -> Set<MapNodeID> {
            var reached: Set<MapNodeID> = []
            var pending = predecessors(node)
            while let next = pending.popLast() {
                guard next != excluded, reached.insert(next).inserted else { continue }
                if !done.contains(next) { pending += predecessors(next) }
            }
            return reached
        }

        /// Whether `node` comes after `earlier`, directly or through others, done or not.
        func reaches(_ node: MapNodeID, back earlier: MapNodeID) -> Bool {
            var reached: Set<MapNodeID> = []
            var pending = predecessors(node)
            while let next = pending.popLast() {
                if next == earlier { return true }
                guard reached.insert(next).inserted else { continue }
                pending += predecessors(next)
            }
            return false
        }

        /// The band of the nearest cards and steps joined to one, either way, by lines or as parts and parents, that have one: of
        /// those as near, the band most of them are in, the first of those in `order`.
        func nearest(_ node: MapNodeID, in bands: [MapNodeID: BoardLane.Kind], order: [BoardLane.Kind]) -> BoardLane.Kind? {
            var visited: Set<MapNodeID> = [node]
            var frontier = [node]
            while !frontier.isEmpty {
                var next: [MapNodeID] = []
                var counts: [BoardLane.Kind: Int] = [:]
                for current in frontier {
                    let family = (up[current] ?? []).sorted() + (down[current] ?? []).sorted()
                    for neighbour in predecessors(current) + successors(current) + family where visited.insert(neighbour).inserted {
                        if let kind = bands[neighbour] { counts[kind, default: 0] += 1 }
                        next.append(neighbour)
                    }
                }
                if let most = counts.values.max() {
                    return order.first { counts[$0] == most } ?? counts.first { $0.value == most }?.key
                }
                frontier = next
            }
            return nil
        }

        /// The lines into each of these from the nearest of them it waits for: right before it, or through ones that aren't
        /// among them and aren't done, as a done one holds nothing back, nor does what's before it; but for one that another
        /// of them waits for, which says it already: not where the two are in a loop, where neither comes first, nor where the
        /// other is done, which holds nothing back.
        func lines(among nodes: [MapNodeID]) -> [WorkMapLine] {
            let shown = Set(nodes)
            var lines: [WorkMapLine] = []
            for node in nodes {
                // Back from it, breadth first, through what isn't shown, to the nearest of what is, with the way there.
                var way: [MapNodeID: [MapNodeID]] = [:]
                var found: [MapNodeID] = []
                var pending: [(MapNodeID, [MapNodeID])] = predecessors(node).map { ($0, []) }
                var visited: Set<MapNodeID> = [node]
                while !pending.isEmpty {
                    let (next, through) = pending.removeFirst()
                    guard visited.insert(next).inserted else { continue }
                    if shown.contains(next) {
                        way[next] = through
                        found.append(next)
                    } else if !done.contains(next) {
                        pending += predecessors(next).map { ($0, [next] + through) }
                    }
                }
                // Not through this one: one in a loop with it would say all it waits for already. Nor does one in a loop with
                // it say anything, as what comes into the loop comes into each of them.
                let ancestry = Dictionary(found.map { ($0, ancestors(of: $0, besides: node)) }, uniquingKeysWith: { first, _ in first })
                let inLoop = Set(found.filter { ancestors(of: $0).contains(node) })
                func says(_ later: MapNodeID, _ earlier: MapNodeID) -> Bool {
                    later != earlier && !done.contains(later) && !inLoop.contains(later) && ancestry[later]?.contains(earlier) == true
                        && ancestry[earlier]?.contains(later) != true
                }
                for earlier in found where !found.contains(where: { says($0, earlier) }) {
                    let through = way[earlier] ?? []
                    let style = through.isEmpty ? Self.style(of: before[node]?[earlier] ?? .order) : .through(through)
                    lines.append(WorkMapLine(before: earlier, after: node, style: style))
                }
            }
            // Then a lighter one from each to the nearest of them it's part of, up its parents, which waits for it: but where a
            // line joins the two already, either way, which says more.
            var joined = Set(lines.flatMap { [MapEdits.Line($0.before, $0.after), MapEdits.Line($0.after, $0.before)] })
            for node in nodes {
                for parent in parents(of: node, among: shown) where joined.insert(MapEdits.Line(node, parent)).inserted {
                    joined.insert(MapEdits.Line(parent, node))
                    lines.append(WorkMapLine(before: node, after: parent, style: .parent))
                }
            }
            return lines
        }

        /// The nearest of these one is part of, up its parents, breadth first, through those that aren't among them.
        func parents(of node: MapNodeID, among shown: Set<MapNodeID>) -> [MapNodeID] {
            var found: [MapNodeID] = []
            var visited: Set<MapNodeID> = [node]
            var pending = (up[node] ?? []).sorted()
            var next = 0
            while next < pending.count {
                let current = pending[next]
                next += 1
                guard visited.insert(current).inserted else { continue }
                if shown.contains(current) {
                    found.append(current)
                } else {
                    pending += (up[current] ?? []).sorted()
                }
            }
            return found
        }

        static func style(of link: WorkMapLink) -> WorkMapLine.Style {
            switch link {
            case .stacked: .stacked
            case .order: .order
            case .azureDevOps: .azureDevOps
            case .said(let author): .said(author)
            }
        }

        /// Whether one waits for something still to do that isn't among these, right before it: it goes at least one wave on.
        func waits(_ node: MapNodeID, among shown: Set<MapNodeID>) -> Bool {
            predecessors(node).contains { !shown.contains($0) && !done.contains($0) }
        }

        /// These as a graph, with the boxes of those Related.
        func graph(
            of items: [WorkMapItem], elsewhere: [MapNodeID: BoardLane.Kind] = [:], boxes: [Set<MapNodeID>] = []
        ) -> WorkMapGraph {
            let ids = items.map(\.id)
            let shown = Set(ids)
            let waiting = Set(items.filter { !$0.isDone && waits($0.id, among: shown) }.map(\.id))
            return WorkMapGraph(items, lines: lines(among: ids), waits: waiting, elsewhere: elsewhere, boxes: boxes)
        }
    }
}

// MARK: - In Azure DevOps

/// What a line of My Work's Map stands for in Azure DevOps (`WorkMap.links(of:)`): dependencies between work items, each from
/// the earlier to the later, which waits for it, as Azure DevOps links a predecessor and its successor, by their references;
/// and those it links already.
public struct MapLineLinks: Equatable, Sendable {
    public var pairs: [MapEdits.Line]
    public var linked: Set<MapEdits.Line>

    public init(pairs: [MapEdits.Line], linked: Set<MapEdits.Line> = []) {
        self.pairs = pairs
        self.linked = linked
    }

    /// Those Azure DevOps doesn't link yet: what Link in Azure DevOps links.
    public var missing: [MapEdits.Line] {
        pairs.filter { !linked.contains($0) }
    }

    /// Azure DevOps links every one of them: Unlink in Azure DevOps takes them away.
    public var isLinked: Bool {
        missing.isEmpty
    }
}

// MARK: - Words

extension OrderText {
    /// Why a band or a graph of My Work's Map shows no graph: "These 72 cards are too many to draw clearly. The Board shows
    /// them."
    public static func tooManyCards(_ count: Int) -> String {
        "These \(count) cards are too many to draw clearly. The Board shows them."
    }

    /// Dependencies between work items, each later one with what it waits for, by what each is called: "Task 5106 waits for
    /// Task 5104", "Task 5160 waits for Task 5110 and Task 5112".
    public static func dependencies(_ pairs: [MapEdits.Line], name: (MapNodeID) -> String) -> [String] {
        let byLater = Dictionary(grouping: pairs, by: \.after)
        return byLater.keys.sorted().map { later in
            let earlier = (byLater[later] ?? []).map(\.before).sorted().map(name)
            return "\(name(later)) waits for \(MapEdits.list(earlier))"
        }
    }

    /// What a dotted line on My Work's Map goes through, from its start: "Through !4103", "Through !4103 and API tests"; and
    /// where you hid them, "Through !4103, which you hid", "Through !4103 and !4105, one of which you hid".
    /// - Parameters:
    ///   - names: what each is called, "!4103", a step's name.
    ///   - hidden: how many of them you hid.
    public static func through(_ names: [String], hidden: Int) -> String {
        let list = names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        switch hidden {
        case 0: return "Through \(list)"
        case names.count: return "Through \(list), which you hid"
        case 1: return "Through \(list), one of which you hid"
        default: return "Through \(list), \(hidden) of which you hid"
        }
    }
}
