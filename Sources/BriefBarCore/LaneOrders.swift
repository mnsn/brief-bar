import Foundation

// Your order on My Work's Board: in each lane, the cards of To start and In progress in the order you put them in, by
// dragging one within its column, or with Move Up, Move Down and Move to Top, ⌘↑ and ⌘↓. One order a lane, across both
// columns, so that a task keeps its place as it starts. A lane keeps the Board's own order until you move a card there:
// that move puts all its cards in To start and In progress in your order as they show, and work that comes later goes to
// the bottom of its column, in the Board's order, until you move it. A move only swaps places within its column, so the
// other column's cards, and those Show doesn't show now, keep theirs. Kept by BriefBar only, for you, by reference: nothing
// goes to Azure DevOps, whose backlog keeps its order, and no stage, slot, count or agent's answer changes for it.

/// Whose order a lane's is: a story's, for the story's own lane and for the lane of a mission for that story, so that its
/// work keeps your order once its first pull request makes it a mission; a mission's; that of the lane of what's in no
/// mission; or, with Lanes: None, that of the one lane.
public enum LaneOrderKey: Hashable, Sendable, CustomStringConvertible {
    case story(ItemRef)
    case mission(MissionKey)
    case notInAMission
    case all

    /// The key of a lane's order.
    /// - Parameter missions: the missions, as By Mission lists them, for the story a mission is for.
    public init(_ lane: BoardLane.Kind, missions: [OrderMission]) {
        switch lane {
        case .mission(.story(let ref)): self = .story(ref)
        case .mission(let key): self = missions.first { $0.key == key }?.story.map { .story($0.ref) } ?? .mission(key)
        case .story(let ref): self = .story(ref)
        case .notInAMission: self = .notInAMission
        case .all: self = .all
        }
    }

    /// `story/workItem/contoso/5101`, `mission/plan/<id>`, `none`, `all`: what the preferences keep. A work item's and a
    /// pull request's carry their organization, as their numbers are unique only within it.
    public var description: String {
        switch self {
        case .story(let ref): "story/\(ref.description)"
        case .mission(let key): "mission/\(key.description)"
        case .notInAMission: "none"
        case .all: "all"
        }
    }

    /// The key a description names, checked as when it was made: nil for anything else.
    public init?(_ description: String) {
        switch description {
        case "none": self = .notInAMission
        case "all": self = .all
        default:
            if description.hasPrefix("story/"), let ref = ItemRef(String(description.dropFirst("story/".count))),
               ref.kind == .workItem {
                self = .story(ref)
            } else if description.hasPrefix("mission/"), let key = MissionKey(String(description.dropFirst("mission/".count))) {
                // A story's mission is the story's own order.
                if case .story(let ref) = key { self = .story(ref) } else { self = .mission(key) }
            } else {
                return nil
            }
        }
    }

    /// Whether it's about a thing of these kinds, which goes as their source does: a story's work item, or what a mission
    /// is made of.
    func isAbout(_ kinds: Set<ItemRef.Kind>) -> Bool {
        switch self {
        case .story(let ref): kinds.contains(ref.kind)
        case .mission(let key): !key.kinds.isDisjoint(with: kinds)
        case .notInAMission, .all: false
        }
    }
}

/// A move of a card within its column of a lane, as you make it.
public enum LaneMove: Equatable, Sendable {
    /// Above the card before it.
    case up
    /// Below the card after it.
    case down
    /// Above every other card in its column.
    case toTop
    /// To this place in its column, from 0, as a drop puts it: before as many of the others.
    case to(Int)
}

/// Your order of the work in the Board's lanes, on My Work: for each lane you put in your order, its cards in To start and
/// In progress, by reference, as you put them, and those it showed that you didn't move, around them. Kept in the
/// preferences (`order.laneOrders`), never a title: the lanes you changed last, `mostLanes` of them, each with the cards it
/// showed and as many of the rest as fit in `mostCards`.
public struct LaneOrders: Equatable, Sendable {
    /// Where it's kept: a list of lanes, the one you changed last first, each a dictionary of its key ("lane") and its cards'
    /// references ("refs").
    public static let defaultsKey = "order.laneOrders"
    /// How many lanes it keeps, those you changed last.
    public static let mostLanes = 50
    /// How many cards it keeps of a lane: those it shows, however many, then as many of the rest as fit.
    public static let mostCards = 200

    private struct Lane: Equatable, Sendable {
        var key: LaneOrderKey
        var refs: [ItemRef]
    }

    /// The one you changed last first.
    private var lanes: [Lane]

    public init() {
        lanes = []
    }

    /// Lanes' orders, the one you changed last first.
    public init(_ orders: [(LaneOrderKey, [ItemRef])]) {
        lanes = []
        for (key, refs) in orders.reversed() {
            set(refs, for: key)
        }
    }

    public var isEmpty: Bool {
        lanes.isEmpty
    }

    /// The keys of the lanes it has, the one you changed last first.
    public var keys: [LaneOrderKey] {
        lanes.map(\.key)
    }

    /// A lane's order: nil for one you haven't put in your order.
    public subscript(key: LaneOrderKey) -> [ItemRef]? {
        lanes.first { $0.key == key }?.refs
    }

    /// A lane's order, as you changed it last: each card once, and the lanes you changed least lately go past
    /// `mostLanes`. None for a lane takes its order away. It keeps every card it's given, which `moving` keeps to
    /// `mostCards`, but for those the lane shows.
    public mutating func set(_ refs: [ItemRef], for key: LaneOrderKey) {
        lanes.removeAll { $0.key == key }
        var seen: Set<ItemRef> = []
        let refs = refs.filter { seen.insert($0).inserted }
        guard !refs.isEmpty else { return }
        lanes.insert(Lane(key: key, refs: refs), at: 0)
        if lanes.count > Self.mostLanes { lanes.removeLast(lanes.count - Self.mostLanes) }
    }

    /// Reset Order: the lane goes back to the Board's own order. Whether it had an order of yours.
    @discardableResult
    public mutating func reset(_ key: LaneOrderKey) -> Bool {
        let count = lanes.count
        lanes.removeAll { $0.key == key }
        return lanes.count != count
    }

    /// Forgets what's about things of these kinds, as their source goes: their places in every lane, and the lanes about
    /// them, or left with none. Whether anything went.
    @discardableResult
    public mutating func forget(_ kinds: Set<ItemRef.Kind>) -> Bool {
        let before = lanes
        lanes = lanes.compactMap { lane in
            guard !lane.key.isAbout(kinds) else { return nil }
            let refs = lane.refs.filter { !kinds.contains($0.kind) }
            return refs.isEmpty ? nil : Lane(key: lane.key, refs: refs)
        }
        return lanes != before
    }

    /// What you put in order, as the preferences keep it; what they hold that this build doesn't know, it leaves out.
    public static func load(from defaults: some SettingsStorage) -> LaneOrders {
        guard let kept = defaults.object(forKey: defaultsKey) as? [[String: Any]] else { return LaneOrders() }
        var orders: [(LaneOrderKey, [ItemRef])] = []
        for lane in kept {
            guard let key = (lane["lane"] as? String).flatMap(LaneOrderKey.init), let refs = lane["refs"] as? [String],
                  !orders.contains(where: { $0.0 == key }) else { continue }
            orders.append((key, refs.compactMap(ItemRef.init)))
        }
        return LaneOrders(orders)
    }

    public func save(to defaults: some SettingsStorage) {
        if lanes.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(
                lanes.map { ["lane": $0.key.description, "refs": $0.refs.map(\.description)] as [String: Any] }, forKey: Self.defaultsKey
            )
        }
    }

    /// A lane's order once you move a card within its column: what it kept, but for cards that merged or completed, then
    /// those it shows that it didn't have, as they show, which places them all; then the column's cards take its places
    /// among them in their new order, so that no other card moves: the other column's, nor those Show doesn't show now.
    /// Past `mostCards`, those it doesn't show go, from the bottom, what you'd do last first; those it shows all stay. Nil
    /// where the card doesn't move, as at the top for Move Up, or isn't in the column.
    /// - Parameters:
    ///   - column: the cards of its column in that lane, as they show.
    ///   - shown: the lane's cards in To start and In progress, as they show: In progress's, then To start's.
    ///   - kept: the lane's order as it's kept; nil for none yet.
    ///   - done: the lane's cards that merged or completed, which leave its order.
    public static func moving(
        _ ref: ItemRef, _ move: LaneMove, column: [ItemRef], shown: [ItemRef], kept: [ItemRef]?, done: Set<ItemRef> = []
    ) -> [ItemRef]? {
        guard let from = column.firstIndex(of: ref) else { return nil }
        let to: Int = switch move {
        case .up: from - 1
        case .down: from + 1
        case .toTop: 0
        case .to(let place): min(max(place, 0), column.count - 1)
        }
        guard column.indices.contains(to), to != from else { return nil }
        var moved = column
        moved.remove(at: from)
        moved.insert(ref, at: to)

        var seen: Set<ItemRef> = []
        var order = (kept ?? []).filter { !done.contains($0) && seen.insert($0).inserted }
        order += shown.filter { seen.insert($0).inserted }
        let inColumn = Set(column)
        let places = order.indices.filter { inColumn.contains(order[$0]) }
        for (place, ref) in zip(places, moved) {
            order[place] = ref
        }
        if order.count > mostCards {
            let showing = Set(shown)
            var over = order.count - mostCards
            for index in order.indices.reversed() where over > 0 && !showing.contains(order[index]) {
                order.remove(at: index)
                over -= 1
            }
        }
        return order
    }
}

// MARK: - On the Board

/// A card on the Board, in a lane's column: a pull request's, or a work item's own, on My Work with your sprint work.
public enum BoardItem: Equatable, Sendable, Identifiable {
    case pullRequest(BoardCard)
    case work(BoardTask)

    public var ref: ItemRef {
        switch self {
        case .pullRequest(let card): card.ref
        case .work(let task): task.ref
        }
    }

    public var id: ItemRef { ref }
}

/// Where a card you moved within its column is now, for VoiceOver to say: its place, from 1, of how many.
public struct LanePlace: Equatable, Sendable {
    public var position: Int
    public var count: Int

    public init(position: Int, count: Int) {
        self.position = position
        self.count = count
    }
}

extension BoardColumn {
    /// Whether you put its cards in your order, on My Work: To start's and In progress's, the work you do yourself.
    public var takesYourOrder: Bool {
        self == .toStart || self == .stage(.inProgress)
    }
}

extension BoardLane {
    /// Its cards in a column, pull requests' and work items' own, in the order they show: in To start and In progress, on
    /// My Work, those you put in your order as you did, then the rest in the Board's order (`yourOrder`); elsewhere, its
    /// pull requests' first, then its work items', each as they come.
    public func items(in column: BoardColumn) -> [BoardItem] {
        let items = cards(in: column).map(BoardItem.pullRequest) + tasks.filter { BoardColumn($0.column) == column }.map(BoardItem.work)
        guard column.takesYourOrder, let order = yourOrder else { return items }
        let places = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return items.enumerated().sorted { lhs, rhs in
            switch (places[lhs.element.ref], places[rhs.element.ref]) {
            case let (left?, right?): left < right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// Whether you can put a column's cards in your order here: To start's and In progress's, on My Work.
    public func takesYourOrder(in column: BoardColumn) -> Bool {
        orderKey != nil && column.takesYourOrder
    }

    /// The column a card of yours to put in order is in: To start or In progress; nil for any other, or where it isn't.
    public func orderColumn(of ref: ItemRef) -> BoardColumn? {
        guard orderKey != nil else { return nil }
        return [BoardColumn.stage(.inProgress), .toStart].first { column in items(in: column).contains { $0.ref == ref } }
    }

    /// Its order once you move one of its cards within its column, To start or In progress, with where it is then: nil
    /// where it doesn't move, as at the top for Move Up, or for a card in no such column.
    public func moving(_ ref: ItemRef, _ move: LaneMove) -> (order: [ItemRef], place: LanePlace)? {
        guard let column = orderColumn(of: ref) else { return nil }
        let refs = items(in: column).map(\.ref)
        let shown = items(in: .stage(.inProgress)).map(\.ref) + items(in: .toStart).map(\.ref)
        let done = Set(cards(in: .merged).map(\.ref) + tasks.filter { $0.column == .merged || $0.column == .completed }.map(\.ref))
        guard let order = LaneOrders.moving(ref, move, column: refs, shown: shown, kept: yourOrder, done: done) else { return nil }
        let inColumn = Set(refs)
        let moved = order.filter(inColumn.contains)
        return moved.firstIndex(of: ref).map { (order, LanePlace(position: $0 + 1, count: moved.count)) }
    }
}

extension PullRequestBoard {
    /// The board in your order, on My Work: each lane's key (`LaneOrderKey`), and in To start and In progress, the order you
    /// put it in, where you have.
    /// - Parameter missions: the missions, as By Mission lists them, for the story a mission's lane is for.
    public func inYourOrder(_ orders: LaneOrders, missions: [OrderMission]) -> PullRequestBoard {
        var board = self
        board.isInYourOrder = true
        for index in board.lanes.indices {
            let key = LaneOrderKey(board.lanes[index].kind, missions: missions)
            board.lanes[index].orderKey = key
            board.lanes[index].yourOrder = orders[key]
        }
        return board
    }

    /// Work items in To start, in the backlog's order, each lane's in your order instead, in the places its work holds:
    /// between lanes, the backlog's order still decides. A later sprint's work, which Start next puts last however you put
    /// it, swaps places only with the lane's other later work, so that it takes none of the rest's.
    func inLanesOrder(_ toStart: [BoardTask]) -> [BoardTask] {
        struct Queue: Hashable {
            var lane: Int
            var isLater: Bool
        }
        var queueOf: [ItemRef: Queue] = [:]
        var queues: [Queue: [BoardTask]] = [:]
        for (index, lane) in lanes.enumerated() {
            for item in lane.items(in: .toStart) {
                guard case .work(let task) = item else { continue }
                let queue = Queue(lane: index, isLater: task.work.laterSprint != nil)
                queueOf[task.ref] = queue
                queues[queue, default: []].append(task)
            }
        }
        return toStart.map { task in
            guard let queue = queueOf[task.ref], let next = queues[queue]?.first else { return task }
            queues[queue]?.removeFirst()
            return next
        }
    }
}

// MARK: - Words

extension BoardText {
    /// Moves a card above the one before it in its column.
    public static let moveUp = "Move Up"
    /// Moves a card below the one after it in its column.
    public static let moveDown = "Move Down"
    /// Moves a card above every other in its column.
    public static let moveToTop = "Move to Top"
    /// Takes a lane's order away, back to the Board's own.
    public static let resetOrder = "Reset Order"
    /// The header of those in a card's menu.
    public static let yourOrder = "Your Order"

    /// Where a card is in its column once you moved it, as VoiceOver says it: "2 of 5 in To start".
    public static func place(_ place: LanePlace, in column: BoardColumn) -> String {
        "\(place.position) of \(place.count) in \(column.spokenTitle)"
    }

    /// What VoiceOver says once a lane's order is reset: the whole lane's, In progress's too, whose pull requests go back to
    /// BriefBar's order rather than the backlog's.
    public static let orderReset = "The lane is back in the Board's order"

    /// How to move a card within its column, for its tooltip on My Work's To start and In progress.
    public static let reorderHelp = "Drag it up or down in its column, or click it and press ⌘↑ or ⌘↓, to put your work in your order"
}
