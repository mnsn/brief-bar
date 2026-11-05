import Foundation

// Your changes to missions, as you make them By Mission: which pull request merges next, what one merges after, and which
// mission one is in. A layer over what BriefBar sees and what sessions tell it (`DeclaredOrders`), kept by pull request and
// never written into an order or to a source, so that sessions go on telling theirs. Each change keeps the place its orders
// gave the pull request when you made it: an order that changes that place afterwards shows instead, as the latest change
// wins, until you put yours back. Kept in the preferences as references, codes and dates, never titles; for a pull request
// listed only because someone sent it in a chat, in memory only (`PullRequestOrder`).

// MARK: - A change

/// Where you put a pull request with Move to Mission.
public enum OrderPlacement: Hashable, Sendable, CustomStringConvertible {
    /// Into a mission, named by what lasts: an order by its ID, a GitHub stack by its number, a chain of branches by one of
    /// its pull requests, the pull requests opened under a session by that session, a mission of your own by its ID.
    case into(MissionKey)
    /// Not in a Mission.
    case outside

    public var mission: MissionKey? {
        if case .into(let key) = self { return key }
        return nil
    }

    /// `none`, or the mission's key: what the preferences keep.
    public var description: String {
        switch self {
        case .into(let key): return key.description
        case .outside: return "none"
        }
    }

    public init?(_ description: String) {
        if description == "none" {
            self = .outside
        } else if let key = MissionKey(description) {
            self = .into(key)
        } else {
            return nil
        }
    }
}

/// Where the orders sessions told put a pull request at one moment: each order that names it, by its ID, with what it
/// merges after there.
public struct OrderPlace: Equatable, Sendable {
    public var orders: [UUID: Set<ItemRef>]

    public init(orders: [UUID: Set<ItemRef>] = [:]) {
        self.orders = orders
    }

    /// Where they put it now.
    public init(of ref: ItemRef, in declared: DeclaredOrders) {
        var orders: [UUID: Set<ItemRef>] = [:]
        for plan in declared.plans {
            if let entry = plan.entry(for: ref) { orders[plan.id] = Set(entry.after) }
        }
        self.orders = orders
    }
}

/// Your change to one pull request's place: set as next to merge, what it merges after or no longer does, and the mission
/// you moved it to. It holds while its orders put it where they did when you changed it (`holds(in:)`).
public struct OrderChange: Equatable, Sendable {
    public var ref: ItemRef
    /// Set as Next to Merge: it merges first in its mission, and what waits for nothing there waits for it.
    public var isFirst: Bool
    /// What you put it after, in the order you checked them.
    public var after: [ItemRef]
    /// What an order, or the one you set as next, put it after that you took away.
    public var notAfter: [ItemRef]
    /// Where you moved it; nil while it's where BriefBar or its order puts it.
    public var placement: OrderPlacement?
    /// The mission you moved it from, for what it says.
    public var from: MissionKey?
    /// When you last changed it, or put it back.
    public var changedAt: Date
    /// Where its orders put it then: what your change replaced.
    public var replaced: OrderPlace

    public init(
        ref: ItemRef, isFirst: Bool = false, after: [ItemRef] = [], notAfter: [ItemRef] = [], placement: OrderPlacement? = nil,
        from: MissionKey? = nil, changedAt: Date, replaced: OrderPlace = OrderPlace()
    ) {
        self.ref = ref
        self.isFirst = isFirst
        self.after = after
        self.notAfter = notAfter
        self.placement = placement
        self.from = from
        self.changedAt = changedAt
        self.replaced = replaced
    }

    /// Nothing's left of it.
    public var isEmpty: Bool {
        !isFirst && after.isEmpty && notAfter.isEmpty && placement == nil
    }

    /// Whether it holds: every order that named the pull request when you changed it, and that BriefBar still keeps, names
    /// it with what it merged after then, and no other order names it. An order that changed that since, revision after
    /// revision, or started or stopped naming it, changed its place after you did: it shows instead, until you put yours
    /// back. Telling the same order again changes nothing, and an order forgotten since is no change.
    public func holds(in orders: DeclaredOrders) -> Bool {
        orders.plans.allSatisfy { plan in
            replaced.orders[plan.id] == plan.entry(for: ref).map { Set($0.after) }
        }
    }

    /// The orders that changed its place since you did, the latest first.
    public func changedBy(in orders: DeclaredOrders) -> [OrderPlan] {
        orders.plans.filter { plan in replaced.orders[plan.id] != plan.entry(for: ref).map { Set($0.after) } }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Whether it would still change anything over where its orders put it now: not one that only took away what they no
    /// longer say.
    public func changesAnything(in orders: DeclaredOrders) -> Bool {
        if isFirst || !after.isEmpty || placement != nil { return true }
        return orders.plans(with: ref).contains { plan in
            plan.entry(for: ref)?.after.contains(where: notAfter.contains) == true
        }
    }

    /// The latest order that changed its place after you did, and how, while that would change anything (`changesAnything`);
    /// nil while it holds.
    public func overridden(in orders: DeclaredOrders) -> OrderOverride? {
        guard changesAnything(in: orders), let plan = changedBy(in: orders).first else { return nil }
        let now: OrderOverride.Now = if let entry = plan.entry(for: ref) {
            entry.after.isEmpty ? .anyTime : .after(entry.after)
        } else {
            .out
        }
        let yours: OrderOverride.Yours = if isFirst {
            .next
        } else if placement != nil {
            .moved
        } else if !after.isEmpty {
            .after(after)
        } else {
            .tookAway(notAfter)
        }
        return OrderOverride(by: plan.declaredBy, at: plan.updatedAt, now: now, yours: yours)
    }

    /// The pull requests it's about: it, and what it merges after or no longer does. It goes once every one of them ended
    /// a while ago (`OrderChanges.removeFinished`).
    public var subjects: Set<ItemRef> {
        Set([ref] + after + notAfter)
    }

    /// Every pull request it names, the chains it names a mission by included: kept in memory when one was only sent to
    /// you in a chat.
    public var named: Set<ItemRef> {
        var refs = subjects
        for key in [placement?.mission, from].compactMap({ $0 }) {
            if case .chain(let anchor) = key { refs.insert(anchor) }
        }
        for after in replaced.orders.values { refs.formUnion(after) }
        return refs
    }
}

/// Why BriefBar didn't make a change you asked for, in words for you. A refused change changes nothing.
public enum OrderChangeError: Error, Equatable, CustomStringConvertible {
    /// BriefBar keeps `OrderChanges.mostChanges`, and removes none to make room.
    case full
    /// That one waits for it already, through your changes or a stacked branch.
    case waitsForIt(ItemRef)
    /// It's stacked on one that hasn't merged, so it can't merge before it.
    case stacked(on: ItemRef)
    /// It isn't in a mission, or not in that one.
    case notInAMission
    /// It merged or closed.
    case ended

    public var description: String {
        switch self {
        case .full:
            return "BriefBar keeps \(OrderChanges.mostChanges) of your changes: undo some first."
        case .waitsForIt(let other):
            return "\(other.shortOrderLabel) waits for it, so it can't merge after \(other.shortOrderLabel)."
        case .stacked(let other):
            return "Stacked on \(other.shortOrderLabel): it can't merge before it unless you retarget it."
        case .notInAMission:
            return "It isn't in a mission: move it to one first."
        case .ended:
            return "It merged or closed."
        }
    }
}

// MARK: - Your changes

/// Your changes to missions, by pull request: each a layer over what its orders and BriefBar say of it, for as long as it
/// holds. BriefBar keeps at most `mostChanges`, refusing more rather than forgetting one, and forgets one `finishedFor` after
/// it saw every pull request it's about merge or close.
public struct OrderChanges: Equatable, Sendable {
    public static let defaultsKey = "order.changes"
    /// The most changes BriefBar keeps: it refuses more, rather than forget one.
    public static let mostChanges = 500
    /// How long a change stays once BriefBar saw the last of the pull requests it's about merge or close, as a finished
    /// order does.
    public static let finishedFor: TimeInterval = DeclaredOrders.finishedFor

    public private(set) var changes: [ItemRef: OrderChange]

    /// - Parameter changes: the first for each pull request wins; empty ones, and those about anything but a pull request,
    ///   are left out.
    public init(_ changes: [OrderChange] = []) {
        var byRef: [ItemRef: OrderChange] = [:]
        for change in changes where change.ref.kind.isPullRequest && !change.isEmpty && byRef[change.ref] == nil {
            byRef[change.ref] = change
        }
        self.changes = byRef
    }

    public subscript(ref: ItemRef) -> OrderChange? {
        changes[ref]
    }

    public var isEmpty: Bool { changes.isEmpty }
    public var count: Int { changes.count }

    /// In reference order.
    public var all: [OrderChange] {
        changes.values.sorted { $0.ref < $1.ref }
    }

    /// Keeps a pull request's change, or forgets it once nothing's left of it. One more than `mostChanges` is refused.
    public mutating func set(_ change: OrderChange) throws {
        guard change.ref.kind.isPullRequest else { return }
        if change.isEmpty {
            changes[change.ref] = nil
            return
        }
        if changes[change.ref] == nil, changes.count >= Self.mostChanges { throw OrderChangeError.full }
        changes[change.ref] = change
    }

    public mutating func remove(_ ref: ItemRef) {
        changes[ref] = nil
    }

    /// Those that hold now (`OrderChange.holds`).
    public func holding(in orders: DeclaredOrders) -> [ItemRef: OrderChange] {
        changes.filter { $0.value.holds(in: orders) }
    }

    /// Every pull request they're about, for BriefBar to keep what it sees become of them.
    public var subjects: Set<ItemRef> {
        Set(changes.values.flatMap(\.subjects))
    }

    /// The missions of your own they put pull requests in, by ID.
    public var ownMissions: Set<UUID> {
        Set(changes.values.compactMap { change in
            if case .into(.mine(let id))? = change.placement { return id }
            return nil
        })
    }

    /// Both, this one's wherever both have a change.
    public func merging(_ other: OrderChanges) -> OrderChanges {
        var merged = self
        for (ref, change) in other.changes where merged.changes[ref] == nil {
            merged.changes[ref] = change
        }
        return merged
    }

    /// Those `isKept` keeps, and the rest.
    public func split(_ isKept: (OrderChange) -> Bool) -> (kept: OrderChanges, rest: OrderChanges) {
        var kept = OrderChanges()
        var rest = OrderChanges()
        for (ref, change) in changes {
            if isKept(change) {
                kept.changes[ref] = change
            } else {
                rest.changes[ref] = change
            }
        }
        return (kept, rest)
    }

    // MARK: Forgetting

    /// Forgets the things of the sources you turned off, as each source forgets what it kept: changes to their pull
    /// requests, what others merge after of theirs, and placements in their missions: a GitHub stack, a chain of their pull
    /// requests, or the pull requests opened under a Copilot session. True when that forgot something.
    @discardableResult
    public mutating func forget(_ kinds: Set<ItemRef.Kind>) -> Bool {
        guard !kinds.isEmpty else { return false }
        let before = changes
        func isForgotten(_ key: MissionKey?) -> Bool {
            switch key {
            case .stack?: return kinds.contains(.gitHubPullRequest)
            case .chain(let anchor)?: return kinds.contains(anchor.kind)
            case .family(let session)?: return kinds.contains(session.kind)
            case .plan?, .mine?, nil: return false
            }
        }
        var kept: [ItemRef: OrderChange] = [:]
        for (ref, change) in changes where !kinds.contains(ref.kind) {
            var change = change
            change.after.removeAll { kinds.contains($0.kind) }
            change.notAfter.removeAll { kinds.contains($0.kind) }
            if isForgotten(change.placement?.mission) { change.placement = nil }
            if isForgotten(change.from) { change.from = nil }
            change.replaced.orders = change.replaced.orders.mapValues { $0.filter { !kinds.contains($0.kind) } }
            if !change.isEmpty { kept[ref] = change }
        }
        changes = kept
        return changes != before
    }

    /// When a change finished: when BriefBar saw the last of the pull requests it's about merge or close, once it saw every
    /// one of them do so; nil while any is open, or one BriefBar can't see.
    public static func finishedAt(_ change: OrderChange, evidence: OrderEvidence) -> Date? {
        var latest: Date?
        for ref in change.subjects {
            guard let record = evidence.records[ref] else { return nil }
            latest = max(latest ?? record.observedAt, record.observedAt)
        }
        return latest
    }

    /// Removes the changes that finished more than `finishedFor` ago, and says which. One about a pull request BriefBar
    /// can't see stays, however old, until you undo or forget it.
    @discardableResult
    public mutating func removeFinished(evidence: OrderEvidence, now: Date = Date()) -> [ItemRef] {
        let finished = changes.values.filter { change in
            Self.finishedAt(change, evidence: evidence).map { now.timeIntervalSince($0) > Self.finishedFor } ?? false
        }.map(\.ref).sorted()
        for ref in finished { changes[ref] = nil }
        return finished
    }

    // MARK: Chains

    /// Moves a chain's mission on to another of its open pull requests as the one it's named by merges or closes, for the
    /// changes that put pull requests in it or moved them out of it, while BriefBar still sees the chain: so that it's
    /// still that chain once the one it was named by is gone. True when that moved something.
    /// - Parameter missions: as By Mission shows them now.
    @discardableResult
    public mutating func moveAnchors(in missions: [OrderMission]) -> Bool {
        var moved: [ItemRef: ItemRef] = [:]
        func anchor(after ended: ItemRef) -> ItemRef? {
            if let known = moved[ended] { return known }
            guard let mission = missions.first(where: { $0.kind == .stack && $0.steps.contains { $0.ref == ended } }),
                  mission.steps.first(where: { $0.ref == ended })?.status.hasEnded == true,
                  let next = mission.steps.first(where: { $0.ref != ended && $0.status.isOpen })?.ref
            else { return nil }
            moved[ended] = next
            return next
        }
        var changed = false
        for (ref, change) in changes {
            var change = change
            if case .into(.chain(let ended))? = change.placement, let next = anchor(after: ended) {
                change.placement = .into(.chain(next))
            }
            if case .chain(let ended)? = change.from, let next = anchor(after: ended) {
                change.from = .chain(next)
            }
            if change != changes[ref] {
                changes[ref] = change
                changed = true
            }
        }
        return changed
    }

    // MARK: Saving

    /// The changes that were saved, without what can't be read, such as what another program wrote.
    public static func load(from defaults: some SettingsStorage) -> OrderChanges {
        guard let data = defaults.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([ChangeLossy].self, from: data)
        else { return OrderChanges() }
        return OrderChanges(records.compactMap { $0.value?.change })
    }

    /// Saves them, as references, codes and dates.
    public func save(to defaults: some SettingsStorage) {
        guard !changes.isEmpty else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(all.map(ChangeRecord.init)) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// A change as the preferences keep it.
private struct ChangeRecord: Codable {
    struct Replaced: Codable {
        var order: UUID
        var after: [ItemRef]
    }

    var pullRequest: ItemRef
    var first: Bool?
    var after: [ItemRef]?
    var notAfter: [ItemRef]?
    var placed: String?
    var from: String?
    var changedAt: Date
    var replaced: [Replaced]?

    private enum CodingKeys: String, CodingKey {
        case pullRequest, first, after, notAfter, placed, from, changedAt, replaced
    }

    init(_ change: OrderChange) {
        pullRequest = change.ref
        first = change.isFirst ? true : nil
        after = change.after.isEmpty ? nil : change.after
        notAfter = change.notAfter.isEmpty ? nil : change.notAfter
        placed = change.placement?.description
        from = change.from?.description
        changedAt = change.changedAt
        let orders = change.replaced.orders.sorted { $0.key.uuidString < $1.key.uuidString }
        replaced = orders.isEmpty ? nil : orders.map { Replaced(order: $0.key, after: $0.value.sorted()) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pullRequest = try container.decode(ItemRef.self, forKey: .pullRequest)
        changedAt = try container.decode(Date.self, forKey: .changedAt)
        first = try? container.decodeIfPresent(Bool.self, forKey: .first)
        after = Self.refs(container, .after)
        notAfter = Self.refs(container, .notAfter)
        placed = try? container.decodeIfPresent(String.self, forKey: .placed)
        from = try? container.decodeIfPresent(String.self, forKey: .from)
        replaced = (try? container.decodeIfPresent([ReplacedLossy].self, forKey: .replaced))?.compactMap(\.value)
    }

    private static func refs(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [ItemRef]? {
        (try? container.decodeIfPresent([RefLossy].self, forKey: key))?.compactMap(\.value)
    }

    /// The change it keeps, without what can't be in one, such as itself among what it merges after; nil when nothing's
    /// left of it.
    var change: OrderChange? {
        guard pullRequest.kind.isPullRequest else { return nil }
        func refs(_ refs: [ItemRef]?) -> [ItemRef] {
            var kept: [ItemRef] = []
            for ref in refs ?? [] where ref.kind.isPullRequest && ref != pullRequest && !kept.contains(ref) {
                kept.append(ref)
            }
            return kept
        }
        let after = refs(after)
        var orders: [UUID: Set<ItemRef>] = [:]
        for record in replaced ?? [] where orders[record.order] == nil {
            orders[record.order] = Set(record.after.filter { $0.kind.isPullRequest && $0 != pullRequest })
        }
        let change = OrderChange(
            ref: pullRequest, isFirst: first == true, after: after, notAfter: refs(notAfter).filter { !after.contains($0) },
            placement: placed.flatMap(OrderPlacement.init), from: from.flatMap(MissionKey.init), changedAt: changedAt,
            replaced: OrderPlace(orders: orders)
        )
        return change.isEmpty ? nil : change
    }
}

private struct ChangeLossy: Decodable {
    var value: ChangeRecord?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(ChangeRecord.self)
    }
}

private struct ReplacedLossy: Decodable {
    var value: ChangeRecord.Replaced?

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
              let order = try? container.decode(UUID.self, forKey: .order)
        else { return }
        let after = (try? container.decodeIfPresent([RefLossy].self, forKey: .after))?.compactMap(\.value) ?? []
        value = ChangeRecord.Replaced(order: order, after: after)
    }

    private enum CodingKeys: String, CodingKey {
        case order, after
    }
}

private struct RefLossy: Decodable {
    var value: ItemRef?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(ItemRef.self)
    }
}

// MARK: - Changing

/// What you ask of a pull request's Mission menu, or of a mission's.
public enum OrderEdit: Equatable, Sendable {
    /// Set as Next to Merge in that mission, or not anymore.
    case setNext(ItemRef, in: MissionKey, Bool)
    /// Merge After: it merges after the other one, in that mission, or not anymore.
    case mergeAfter(ItemRef, ItemRef, in: MissionKey, Bool)
    /// Move to Mission: these, from the mission they're in, if any, into another, a new one of your own, or none. Several
    /// at once, with one Undo.
    case move([ItemRef], to: OrderPlacement, from: MissionKey?)
    /// Undo Your Changes to It.
    case undo(ItemRef)
    /// Undo Your Changes to This Mission: to its pull requests, those you put in it and those you moved out of it.
    case undoMission(MissionKey)
    /// Put Yours Back: your change holds again, over the later one of its orders.
    case putBack(ItemRef)
}

extension OrderChanges {
    /// Makes a change, as you asked for it from a menu, and says what each change it touched was before, for Undo. It
    /// refuses what the menu doesn't offer: a cycle with a stacked branch or your own changes, Set as Next on one stacked on a
    /// pull request that hasn't merged, and one more change than `mostChanges`; refused, nothing changes.
    /// - Parameters:
    ///   - missions: as By Mission shows them now.
    ///   - orders: the orders sessions told.
    /// - Returns: each change it touched, by pull request, as it was: nil where there was none.
    @discardableResult
    public mutating func apply(
        _ edit: OrderEdit, missions: [OrderMission], orders: DeclaredOrders, now: Date = Date()
    ) throws -> [ItemRef: OrderChange?] {
        var edited = self
        var touched: [ItemRef: OrderChange?] = [:]
        func current(_ ref: ItemRef) -> OrderChange {
            // A change an order changed since starts again from where it shows now.
            if let change = edited.changes[ref], change.holds(in: orders) { return change }
            return OrderChange(ref: ref, changedAt: now)
        }
        func keep(_ change: OrderChange, stamped: Bool = true) throws {
            if touched[change.ref] == nil { touched[change.ref] = .some(changes[change.ref]) }
            var change = change
            if stamped {
                change.changedAt = now
                change.replaced = OrderPlace(of: change.ref, in: orders)
            }
            try edited.set(change)
        }
        func remove(_ ref: ItemRef) {
            guard let change = edited.changes[ref] else { return }
            if touched[ref] == nil { touched[ref] = .some(change) }
            edited.remove(ref)
        }

        switch edit {
        case .setNext(let ref, let key, let on):
            let (mission, step, isAttached) = try Self.find(ref, in: key, missions)
            var change = current(ref)
            if on {
                guard !step.status.hasEnded else { throw OrderChangeError.ended }
                if let stacked = Self.openStacked(under: step) { throw OrderChangeError.stacked(on: stacked) }
                change.isFirst = true
                change.after = []
                change.notAfter = []
                if isAttached { change.placement = .into(key) }
                // One for each mission.
                for other in mission.steps where other.ref != ref {
                    guard var first = edited.changes[other.ref], first.isFirst, first.holds(in: orders) else { continue }
                    first.isFirst = false
                    try keep(first)
                }
            } else {
                change.isFirst = false
            }
            try keep(change)

        case .mergeAfter(let ref, let other, let key, let on):
            let (_, step, isAttached) = try Self.find(ref, in: key, missions)
            guard other != ref else { throw OrderChangeError.waitsForIt(other) }
            var change = current(ref)
            if on {
                if Self.waits(other, for: ref, in: missions) { throw OrderChangeError.waitsForIt(other) }
                change.isFirst = false
                if !change.after.contains(other) { change.after.append(other) }
                change.notAfter.removeAll { $0 == other }
                if isAttached { change.placement = .into(key) }
            } else {
                let prerequisite = step.prerequisites.first { $0.ref == other }
                if prerequisite?.origins.contains(where: \.isStacked) == true { throw OrderChangeError.stacked(on: other) }
                if change.after.contains(other) {
                    change.after.removeAll { $0 == other }
                } else if prerequisite != nil, !change.notAfter.contains(other) {
                    change.notAfter.append(other)
                }
            }
            try keep(change)

        case .move(let refs, let placement, let from):
            for ref in refs {
                let source = from ?? missions.first { $0.contains(ref) }?.key
                if let source, placement == .into(source) { continue }
                var change = current(ref)
                change.isFirst = false
                change.after = []
                change.notAfter = []
                change.placement = placement
                change.from = source
                try keep(change)
            }

        case .undo(let ref):
            remove(ref)

        case .undoMission(let key):
            let mission = missions.first { $0.key == key }
            let refs = Set((mission?.steps ?? []).map(\.ref) + (mission?.attached ?? []).map(\.ref))
            for change in edited.all where refs.contains(change.ref) || change.placement == .into(key) || change.from == key {
                remove(change.ref)
            }

        case .putBack(let ref):
            guard let change = edited.changes[ref] else { break }
            try keep(change)
        }
        self = edited
        return touched
    }

    /// Puts back the changes an edit touched, as `apply` said they were.
    public mutating func restore(_ touched: [ItemRef: OrderChange?]) {
        for (ref, change) in touched {
            changes[ref] = change.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// A pull request in a mission: one of its steps, or one stacked with them that its order doesn't name.
    static func find(_ ref: ItemRef, in key: MissionKey, _ missions: [OrderMission]) throws -> (OrderMission, OrderStep, Bool) {
        guard let mission = missions.first(where: { $0.key == key }) else { throw OrderChangeError.notInAMission }
        if let step = mission.steps.first(where: { $0.ref == ref }) { return (mission, step, false) }
        if let step = mission.attached.first(where: { $0.ref == ref }) { return (mission, step, true) }
        throw OrderChangeError.notInAMission
    }

    /// What a pull request is stacked on that hasn't merged, or that BriefBar can't see merge: it can't merge first.
    static func openStacked(under step: OrderStep) -> ItemRef? {
        step.prerequisites.first { $0.origins.contains(where: \.isStacked) && !$0.status.hasEnded }?.ref
    }

    /// Whether one waits for another, directly or through others, by a stacked branch or a change of yours: what a menu
    /// can't undo by putting the other after it.
    static func waits(_ later: ItemRef, for earlier: ItemRef, in missions: [OrderMission]) -> Bool {
        var before: [ItemRef: Set<ItemRef>] = [:]
        for mission in missions {
            for step in mission.steps + mission.attached {
                for prerequisite in step.prerequisites where prerequisite.origins.contains(where: { $0.isStacked || $0 == .yours }) {
                    before[step.ref, default: []].insert(prerequisite.ref)
                }
            }
        }
        var pending = Array(before[later] ?? [])
        var seen: Set<ItemRef> = []
        while let ref = pending.popLast() {
            if ref == earlier { return true }
            guard seen.insert(ref).inserted else { continue }
            pending += before[ref] ?? []
        }
        return false
    }
}

// MARK: - A pull request's Mission menu

/// What a pull request's Mission menu offers, from where it is now.
public struct MissionChoices: Equatable, Sendable {
    /// Set as Next to Merge.
    public enum Next: Equatable, Sendable {
        case offered
        /// It's set as next: choosing it again takes that away.
        case isSet
        /// It's stacked on one that hasn't merged.
        case stacked(on: ItemRef)
        /// It merged or closed.
        case ended
    }

    /// One of the mission's other pull requests, in Merge After.
    public struct Prerequisite: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            case unchecked
            /// It merges after it: yours, its order's, or the one you set as next.
            case checked
            /// It's stacked on it: retarget it to change that.
            case stacked
            /// That one waits for it, through your changes or a stacked branch.
            case waitsForIt
        }

        public var ref: ItemRef
        public var state: State

        public init(ref: ItemRef, state: State) {
            self.ref = ref
            self.state = state
        }

        /// Whether choosing it changes anything.
        public var canChange: Bool { state == .unchecked || state == .checked }
    }

    public var ref: ItemRef
    /// The mission it's in, as the menu speaks for it; nil in none.
    public var mission: MissionKey?
    /// Nil in no mission.
    public var next: Next?
    /// Merge After: the mission's other pull requests that haven't merged or closed, in its order.
    public var prerequisites: [Prerequisite]
    /// Move to Mission: the missions it can go to, as By Mission lists them, its own among them.
    public var targets: [MissionKey]
    /// Undo Your Changes to It.
    public var canUndo: Bool
    /// Put Yours Back: an order changed its place after you did.
    public var canPutBack: Bool

    public init(
        ref: ItemRef, mission: MissionKey?, next: Next?, prerequisites: [Prerequisite], targets: [MissionKey], canUndo: Bool,
        canPutBack: Bool
    ) {
        self.ref = ref
        self.mission = mission
        self.next = next
        self.prerequisites = prerequisites
        self.targets = targets
        self.canUndo = canUndo
        self.canPutBack = canPutBack
    }

    /// What its menu offers.
    /// - Parameters:
    ///   - mission: the mission whose card it's in, where it's in two; nil for the first that has it.
    ///   - missions: as By Mission shows them now.
    public static func of(
        _ ref: ItemRef, in mission: MissionKey? = nil, missions: [OrderMission], changes: OrderChanges, orders: DeclaredOrders
    ) -> MissionChoices {
        let shown = mission.flatMap { key in missions.first { $0.key == key && $0.contains(ref) } }
            ?? missions.first { $0.contains(ref) }
        let targets = missions.filter { !$0.isFinished || $0.key == shown?.key }.map(\.key)
        let change = changes[ref]
        let canPutBack = change.map { !$0.holds(in: orders) && $0.changesAnything(in: orders) } ?? false
        guard let shown, let step = shown.steps.first(where: { $0.ref == ref }) ?? shown.attached.first(where: { $0.ref == ref })
        else {
            return MissionChoices(
                ref: ref, mission: nil, next: nil, prerequisites: [], targets: targets, canUndo: change != nil, canPutBack: canPutBack
            )
        }
        let isSet = change.map { $0.isFirst && $0.holds(in: orders) } ?? false
        let next: Next = if step.status.hasEnded {
            .ended
        } else if isSet {
            .isSet
        } else if let stacked = OrderChanges.openStacked(under: step) {
            .stacked(on: stacked)
        } else {
            .offered
        }
        let prerequisites = shown.steps.filter { $0.ref != ref && !$0.status.hasEnded }.map { other in
            let origins = step.prerequisites.first { $0.ref == other.ref }?.origins
            let state: Prerequisite.State = if origins?.contains(where: \.isStacked) == true {
                .stacked
            } else if origins != nil {
                .checked
            } else if OrderChanges.waits(other.ref, for: ref, in: missions) {
                .waitsForIt
            } else {
                .unchecked
            }
            return Prerequisite(ref: other.ref, state: state)
        }
        return MissionChoices(
            ref: ref, mission: shown.key, next: next, prerequisites: prerequisites, targets: targets, canUndo: change != nil,
            canPutBack: canPutBack
        )
    }
}
