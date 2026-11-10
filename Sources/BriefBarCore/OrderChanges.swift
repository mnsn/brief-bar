import Foundation

// Your changes to missions, as you make them By Mission: which pull request merges next, what one merges after, and which
// mission one is in. A layer over what BriefBar sees and what sessions tell it (`DeclaredOrders`), kept by pull request and
// never written into an order or to a source, so that sessions go on telling theirs. Each change keeps the place its orders
// gave the pull request when you made it: an order that goes against yours afterwards shows instead, as the latest change
// wins, until you put yours back; one that moves it toward yours, or changes what you didn't, leaves yours as it is. Kept in
// the preferences as references, codes and dates, never titles; for a pull request listed only because someone sent it in a
// chat, in memory only (`PullRequestOrder`).

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
    /// An order that changed the pull request's place after you had, as BriefBar saw it: which, and when; and, where it took
    /// back what a split moved, as it put a line across the split (`OrderChanges.splitsTakenBack`), what its note says.
    public struct Overridden: Equatable, Sendable {
        public var by: UUID
        public var at: Date
        /// The pull requests it put after this one across the split, where it put this one after none across it.
        public var before: [ItemRef]
        /// The one whose line across the split took this one back with it, where it put this one in no line across it.
        public var with: ItemRef?

        public init(by: UUID, at: Date, before: [ItemRef] = [], with: ItemRef? = nil) {
            self.by = by
            self.at = at
            self.before = before
            self.with = with
        }

        /// Without the pull requests it names that BriefBar forgets.
        func without(_ isForgotten: (ItemRef) -> Bool) -> Overridden {
            var kept = self
            kept.before.removeAll(where: isForgotten)
            if kept.with.map(isForgotten) == true { kept.with = nil }
            return kept
        }
    }

    public var ref: ItemRef
    /// Set as Next to Merge, in this mission: it merges first there, and what waits for nothing there waits for it.
    public var first: MissionKey?
    /// What you put it after, in the order you checked them.
    public var after: [ItemRef]
    /// What an order, or the one you set as next, put it after that you took away.
    public var notAfter: [ItemRef]
    /// Where you moved it; nil while it's where BriefBar or its order puts it.
    public var placement: OrderPlacement?
    /// The mission it was in when you changed it: the one you moved it from, for what it says, or the one you set it as next
    /// or put it after another in, for Put Yours Back to put it back in, should an order take it out. Where you set it as next
    /// in a mission BriefBar worked out that an order took in since, still that one, for your next to go back to
    /// (`unfollow`).
    public var from: MissionKey?
    /// When you last changed it, or put it back.
    public var changedAt: Date
    /// Where its orders put it then, or since, as they moved it toward yours: what an order's next change is told from.
    public var replaced: OrderPlace
    /// Where its orders put it when you changed it, or put it back, or before, as BriefBar saw it since: an order that puts
    /// it back there changed nothing, whatever it said between, as BriefBar can't tell that from a session telling again
    /// what it read before.
    public var found: OrderPlace
    /// The order that went against it since, as BriefBar saw it: yours doesn't hold from then on, though that order puts it
    /// back where it was, until you put yours back, or BriefBar forgets that order.
    public var overridden: Overridden?
    /// A split Apple Intelligence suggested, and you confirmed, moved it, from `from` (`OrderEdit.split`): a mission of your
    /// own it's in keeps the lines of the session's order it was split from among those split off it, and the mission it
    /// was split from asks it in as a mission split off before. Move to Mission moves it as yours alone again.
    public var bySplit: Bool
    /// For one a split moved from a session's order's mission: the pull requests that order put it after, or after it, when
    /// you last changed it, or before, as BriefBar saw it since; and those it put it after, or after it, since, where that
    /// line didn't cross the split as BriefBar first saw it: to one the split moved with it, to one you moved elsewhere
    /// yourself, or one you took away (`OrderChanges.noteOverrides`). Empty for any other change. A line between it and one
    /// of those never takes it back into that order's mission, however it comes to cross the split, as when that one leaves
    /// it, or you put it back over that line: only one that crosses as BriefBar first sees it does
    /// (`OrderChanges.splitsTakenBack`). Back where the split put it, as Undo brings it back, it knows only those it knew
    /// then and saw there since (`OrderChanges.restore`): one its order put it in while it was out is later than your
    /// change, as is one an order BriefBar forgot that had taken it was told meanwhile.
    public var linedWith: Set<ItemRef>
    /// For one a split moved from a session's order's mission that the order didn't name, as one stacked with its own: it
    /// goes back with what the split moved with it however that order names it since, where one the order named and no
    /// longer does stays (`OrderChanges.splitsTakenBack`).
    public var splitAttached: Bool
    /// When a split moved it, or you put it back where the split put it since (`OrderEdit.putBack`); nil for any other
    /// change, and for one saved without it. No other change of yours changes it: back where the split put it since its
    /// order took back what the split moved with it, it goes back with those its order took after that
    /// (`OrderChanges.takenBack(with:in:)`).
    public var splitAt: Date?

    public init(
        ref: ItemRef, first: MissionKey? = nil, after: [ItemRef] = [], notAfter: [ItemRef] = [], placement: OrderPlacement? = nil,
        from: MissionKey? = nil, changedAt: Date, replaced: OrderPlace = OrderPlace(), found: OrderPlace? = nil,
        overridden: Overridden? = nil, bySplit: Bool = false, linedWith: Set<ItemRef> = [], splitAttached: Bool = false,
        splitAt: Date? = nil
    ) {
        self.ref = ref
        self.first = first
        self.after = after
        self.notAfter = notAfter
        self.placement = placement
        self.from = from
        self.changedAt = changedAt
        self.replaced = replaced
        self.found = found ?? replaced
        self.overridden = overridden
        self.bySplit = bySplit
        self.linedWith = linedWith
        self.splitAttached = splitAttached
        self.splitAt = splitAt
    }

    /// The pull requests an order puts this one after, or after it.
    static func lines(of ref: ItemRef, in plan: OrderPlan) -> Set<ItemRef> {
        var lined = Set(plan.entry(for: ref)?.after ?? [])
        for entry in plan.entries where entry.after.contains(ref) { lined.insert(entry.ref) }
        lined.remove(ref)
        return lined
    }

    /// What `linedWith` is for these orders now.
    func lined(in orders: DeclaredOrders) -> Set<ItemRef> {
        guard case .plan(let id)? = splitFrom, let plan = orders.plan(id) else { return [] }
        return Self.lines(of: ref, in: plan)
    }

    /// The mission a split moved it from, while it's where the split put it: nil for any other change.
    public var splitFrom: MissionKey? {
        bySplit && placement != nil ? from : nil
    }

    /// Set as Next to Merge, in some mission.
    public var isFirst: Bool { first != nil }

    /// Whether it puts the pull request in the mission whose order doesn't name it but that it's stacked with, only for what
    /// you set it as next or put it after there: never a mission you moved it to, which is never the one it was in.
    public var isAttached: Bool {
        placement != nil && placement == from.map(OrderPlacement.into)
    }

    /// Puts it in the mission it's stacked with, for what you set there (`isAttached`).
    mutating func attach(to key: MissionKey) {
        guard placement == nil || isAttached else { return }
        placement = .into(key)
        from = key
    }

    /// Takes it out of the mission it's stacked with once nothing you set there is left of it (`isAttached`).
    mutating func detachIfDone() {
        guard isAttached, !isFirst, after.isEmpty, notAfter.isEmpty else { return }
        placement = nil
    }

    /// Nothing's left of it.
    public var isEmpty: Bool {
        !isFirst && after.isEmpty && notAfter.isEmpty && placement == nil
    }

    /// Whether it holds: no order BriefBar still keeps went against it since, as BriefBar saw it (`changedBy`). One that did
    /// changed its place after you did: it shows instead, until you put yours back. Telling the same order again, in another
    /// sequence or with other review advice, changes nothing, nor does telling it again as it was when you changed it,
    /// whatever it said between; nor does an order that moved it toward yours, or changed what you didn't, or a revision its
    /// session told before your change, which BriefBar saw only after; and an order forgotten since is no change, nor is its
    /// having gone against yours.
    public func holds(in orders: DeclaredOrders) -> Bool {
        !isOverridden(in: orders) && changedBy(in: orders).isEmpty
    }

    /// Whether an order that BriefBar still keeps changed its place since, as BriefBar saw it (`OrderChanges.noteOverrides`).
    func isOverridden(in orders: DeclaredOrders) -> Bool {
        overridden.map { orders.plan($0.by) != nil } ?? false
    }

    /// The orders that went against yours since you changed it, by what they say of it now and what they said then, the
    /// latest first (`goesAgainst`): only a revision told after your change, and not one that puts it back where it was then.
    public func changedBy(in orders: DeclaredOrders) -> [OrderPlan] {
        orders.plans.filter { plan in
            let then = replaced.orders[plan.id]
            let now = plan.entry(for: ref).map { Set($0.after) }
            return plan.updatedAt > changedAt && then != now && now != found.orders[plan.id]
                && goesAgainst(from: then, to: now, in: plan.id)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Whether an order changing what it says of the pull request, from what it put it after then to what it does now, nil
    /// where it doesn't name it, goes against yours: it names it in another mission than the one you moved it to; it takes
    /// it out of the order you moved it to, set it as next in or put it after another in; or it puts it after what you took
    /// away, or after anything in the order you set it as next in, or in the stack, chain or session's pull requests you
    /// set it as next in, which naming it takes it out of. One that moves it toward yours doesn't: taking it out of an order
    /// you moved it out of, naming it in the one you moved it to, or where you changed it in a stack, chain or session's pull
    /// requests, as you did, putting it after what you did, or no longer after what you took away or anything where you set
    /// it as next. Nor does one of what you didn't change.
    func goesAgainst(from then: Set<ItemRef>?, to now: Set<ItemRef>?, in id: UUID) -> Bool {
        let key = MissionKey.plan(id)
        guard let now else {
            if let placement { return placement == .into(key) }
            return (first ?? from) == key
        }
        // Where you set it as next, as this order has it: in a mission BriefBar worked out that its naming it takes it out
        // of, as for an order you moved it into.
        var isNextHere = first == key
        if then == nil {
            if let placement, placement != .into(key) { return true }
            if placement == nil, let changedIn = first ?? from, changedIn.isWorkedOut { isNextHere = isFirst }
        }
        let added = now.subtracting(then ?? [])
        return !added.isEmpty && (isNextHere || !added.isDisjoint(with: notAfter))
    }

    /// What you set in a mission BriefBar worked out, a stack, a chain or a session's pull requests, goes over to an order
    /// that names it since it was there, as it took it out of there: Set as Next to Merge and Merge After are that order's
    /// now, and Put Yours Back puts it back there. Your next stays where you set it while that order has another of yours,
    /// for one to go first there; and `from` keeps where you set it, for it to go back there once the order no longer names
    /// it (`unfollow`).
    /// - Parameter nexts: the orders where another you set as next holds.
    /// - Returns: the order your next went over to, if it did.
    @discardableResult
    mutating func follow(into orders: DeclaredOrders, besides nexts: Set<UUID> = []) -> UUID? {
        guard placement == nil, (first ?? from)?.isWorkedOut == true,
              let plan = orders.plans.first(where: { replaced.orders[$0.id] == nil && $0.entry(for: ref) != nil })
        else { return nil }
        if first?.isWorkedOut == true {
            guard !nexts.contains(plan.id) else { return nil }
            first = .plan(plan.id)
            return plan.id
        }
        if from?.isWorkedOut == true { from = .plan(plan.id) }
        return nil
    }

    /// Your next that went over to an order (`follow`) goes back to the mission BriefBar worked out that you set it in, once
    /// that order no longer names it, or is gone.
    mutating func unfollow(in orders: DeclaredOrders) {
        guard placement == nil, case .plan(let id)? = first, let from, from.isWorkedOut, orders.plan(id)?.entry(for: ref) == nil
        else { return }
        first = from
    }

    /// A revision of an order its session told before you changed it, which BriefBar sees only now, is what your change
    /// replaced: yours is later. So are its lines across a split that moved it (`linedWith`).
    mutating func rebase(on orders: DeclaredOrders) {
        for plan in orders.plans where plan.updatedAt <= changedAt {
            let place = plan.entry(for: ref).map { Set($0.after) }
            replaced.orders[plan.id] = place
            found.orders[plan.id] = place
            if splitFrom == .plan(plan.id) { linedWith = Self.lines(of: ref, in: plan) }
        }
    }

    /// Whether it would still change anything over where its orders put it now: not one that only took away what they no
    /// longer say.
    public func changesAnything(in orders: DeclaredOrders) -> Bool {
        if isFirst || !after.isEmpty || placement != nil { return true }
        return orders.plans(with: ref).contains { plan in
            plan.entry(for: ref)?.after.contains(where: notAfter.contains) == true
        }
    }

    /// The order that changed its place after you did, and how, while that would change anything (`changesAnything`); nil
    /// while it holds, or that order's gone. One that took it back as it put a line across a split says that line, or the
    /// one it went back with.
    public func overridden(in orders: DeclaredOrders) -> OrderOverride? {
        guard changesAnything(in: orders) else { return nil }
        guard let plan = overridden.flatMap({ orders.plan($0.by) }) ?? changedBy(in: orders).first else { return nil }
        let across = overridden.flatMap { $0.by == plan.id ? $0 : nil }
        let now: OrderOverride.Now = if let with = across?.with {
            .with(with)
        } else if let before = across?.before, !before.isEmpty {
            .before(before)
        } else if let entry = plan.entry(for: ref) {
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
        return OrderOverride(by: plan.declaredBy, at: overridden?.at ?? plan.updatedAt, now: now, yours: yours)
    }

    /// The pull requests it's about: it, and what it merges after or no longer does. It goes once every one of them ended
    /// a while ago (`OrderChanges.removeFinished`).
    public var subjects: Set<ItemRef> {
        Set([ref] + after + notAfter)
    }

    /// Every pull request it's about or names a mission by, a chain by one of its own: kept in memory when one was only sent
    /// to you in a chat. Not those its orders named when you changed it, which `order.plans` keeps already.
    public var named: Set<ItemRef> {
        var refs = subjects
        for key in [placement?.mission, from, first].compactMap({ $0 }) {
            if case .chain(let anchor) = key { refs.insert(anchor) }
        }
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
    /// What it was stacked on merged, and it still targets that one's branch: retarget it first, to this branch when known.
    case retarget(after: ItemRef, to: String?)
    /// It isn't in a mission, or not in that one.
    case notInAMission
    /// It merged or closed.
    case ended

    /// Without a full stop: the line that says it beside your last change's Undo ends it, as it does what you did. The
    /// Board's Waits onto Can merge says Set as Next to Merge's in the same words (`OrderMission.whyNotNext`).
    public var description: String {
        switch self {
        case .full:
            return "BriefBar keeps \(OrderChanges.mostChanges) of your changes: undo some first"
        case .waitsForIt(let other):
            return "\(other.shortOrderLabel) waits for it, so it can't merge after \(other.shortOrderLabel)"
        case .stacked(let other):
            let place = other.kind == .gitHubPullRequest ? "on GitHub" : "in Azure DevOps"
            return "Stacked on \(other.shortOrderLabel): retarget it \(place) first"
        case .retarget(let merged, let branch):
            let label = merged.shortOrderLabel
            return "\(label) merged: retarget it to \(branch ?? "the branch \(label) merged into")"
        case .notInAMission:
            return "It isn't in a mission: move it to one first"
        case .ended:
            return "It merged or closed"
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

    /// Those that hold once BriefBar notes what the orders did to them (`noteOverrides`), as it does once it sees them, with
    /// what they take back that a split moved: for what's told before it does.
    /// - Parameter status: where each pull request stands, as BriefBar sees it.
    public func holding(
        in orders: DeclaredOrders, now: Date = Date(), status: (ItemRef) -> OrderStatus
    ) -> [ItemRef: OrderChange] {
        var noted = self
        noted.noteOverrides(in: orders, now: now, status: status)
        return noted.holding(in: orders)
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
    /// requests, what others merge after of theirs, the lines across a split and an order's notes that name them, and
    /// placements in their missions: a GitHub stack, a chain of their pull requests, the pull requests opened under a
    /// Copilot session, or a story's, by its Azure DevOps work item. True when that forgot something.
    @discardableResult
    public mutating func forget(_ kinds: Set<ItemRef.Kind>) -> Bool {
        guard !kinds.isEmpty else { return false }
        let before = changes
        func isForgotten(_ key: MissionKey?) -> Bool {
            switch key {
            case .stack?: return kinds.contains(.gitHubPullRequest)
            case .chain(let anchor)?: return kinds.contains(anchor.kind)
            case .family(let session)?: return kinds.contains(session.kind)
            case .story(let story)?: return kinds.contains(story.kind)
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
            if isForgotten(change.first) { change.first = nil }
            change.replaced.orders = change.replaced.orders.mapValues { $0.filter { !kinds.contains($0.kind) } }
            change.found.orders = change.found.orders.mapValues { $0.filter { !kinds.contains($0.kind) } }
            change.linedWith = change.linedWith.filter { !kinds.contains($0.kind) }
            change.overridden = change.overridden?.without { kinds.contains($0.kind) }
            if !change.isEmpty { kept[ref] = change }
        }
        changes = kept
        return changes != before
    }

    /// Forgets what each change keeps of where orders put its pull request, of the orders BriefBar no longer keeps, which
    /// nothing reads again; and the pull requests sent to you only in a chat that no order BriefBar keeps names anymore, so
    /// that their references go as everything else BriefBar kept of them does. A session that tells an order again that
    /// names such a one where it did before then goes against your change, as BriefBar no longer knows it did. True when
    /// that forgot something.
    /// - Parameter chatOnly: the pull requests listed only because someone sent them in a chat.
    @discardableResult
    public mutating func forgetPlaces(besides orders: DeclaredOrders, chatOnly: Set<ItemRef>) -> Bool {
        let kept = Set(orders.plans.map(\.id))
        let named = Set(orders.plans.flatMap { plan in plan.entries.flatMap { [$0.ref] + $0.after } })
        let gone = chatOnly.subtracting(named)
        func tidied(_ place: OrderPlace) -> OrderPlace {
            OrderPlace(orders: place.orders.filter { kept.contains($0.key) }.mapValues { $0.subtracting(gone) })
        }
        var forgot = false
        for (ref, change) in changes {
            var tidy = change
            tidy.replaced = tidied(change.replaced)
            tidy.found = tidied(change.found)
            // What a split moved keeps the lines of an order BriefBar still keeps.
            let order: UUID? = if case .plan(let id)? = change.splitFrom { id } else { nil }
            tidy.linedWith = order.map(kept.contains) == true ? change.linedWith.subtracting(gone) : []
            tidy.overridden = change.overridden?.without(gone.contains)
            if tidy != change {
                changes[ref] = tidy
                forgot = true
            }
        }
        return forgot
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

    /// Moves a chain's mission on to another of its own open pull requests as the one it's named by merges or closes, for
    /// the changes that put pull requests in it, moved them out of it or set one as next in it, while BriefBar still sees
    /// the chain: so that it's still that chain once the one it was named by is gone. Never to one you put in it, which the
    /// chain doesn't have of its own.
    /// - Parameters:
    ///   - missions: as By Mission shows them now.
    ///   - orders: the orders, for which of your changes hold: one an order went against puts its pull request nowhere.
    ///   - pending: other changes whose chains to look for too, such as what Undo would put back, which it doesn't rename.
    /// - Returns: what each chain it moved, or would for `pending`, was named by, and is now: for those to follow
    ///   (`renameChains`).
    @discardableResult
    public mutating func moveAnchors(
        in missions: [OrderMission], orders: DeclaredOrders, alsoFor pending: OrderChanges = OrderChanges()
    ) -> [ItemRef: ItemRef] {
        var moved: [ItemRef: ItemRef] = [:]
        // Where your changes that hold put pull requests now, as By Mission shows them, not where Undo would: one Undo would
        // move out is the chain's own today, and so is one you moved out that an order took back.
        let placed = holding(in: orders)
        func anchor(after ended: ItemRef) -> ItemRef? {
            if let known = moved[ended] { return known }
            guard let mission = missions.first(where: { $0.kind == .stack && $0.steps.contains { $0.ref == ended } }),
                  mission.steps.first(where: { $0.ref == ended })?.status.hasEnded == true,
                  let next = Self.ownOpen(of: mission, besides: [ended], placed: placed)
            else { return nil }
            moved[ended] = next
            return next
        }
        rename { anchor(after: $0) }
        var others = pending
        others.rename { anchor(after: $0) }
        return moved
    }

    /// Names the chains these name as `moveAnchors` renamed them.
    public mutating func renameChains(_ renamed: [ItemRef: ItemRef]) {
        guard !renamed.isEmpty else { return }
        rename { renamed[$0] }
    }

    /// The first open pull request a stack has of its own, but these: not one you put in it, by a change that holds, as By
    /// Mission shows it.
    /// - Parameter changes: your changes that hold.
    static func ownOpen(of mission: OrderMission, besides refs: Set<ItemRef>, placed changes: [ItemRef: OrderChange]) -> ItemRef? {
        mission.steps.first { step in
            !refs.contains(step.ref) && step.status.isOpen && changes[step.ref]?.placement == nil
        }?.ref
    }

    /// Names the chains that changes name by another of their pull requests, where `anchor` gives one.
    mutating func rename(_ anchor: (ItemRef) -> ItemRef?) {
        func chain(_ key: MissionKey) -> MissionKey? {
            guard case .chain(let old) = key, let new = anchor(old) else { return nil }
            return .chain(new)
        }
        renameMissions(chain, nexts: chain, froms: { key, _ in chain(key) })
    }

    /// Names the missions your changes name as they went on, where `successor` gives where one went
    /// (`OrderBoard.successor`): the pull requests opened under a session, or a chain, to their story's, and back; a chain
    /// to another chain or a GitHub stack. Where each puts its pull request and the mission one you moved came from, by
    /// `successor`; where it's set as next, by `nexts`, which can leave it where it was, so that others where they went
    /// don't wait for it. The mission one you didn't move was in, as you set it as next or put it after another there, goes
    /// as where you set it as next does, or by `successor`, and only to a mission that has it (`holds`): Undo Your Changes
    /// to This Mission takes it back only where it is.
    /// - Returns: what each mission it renamed was named, and is now.
    @discardableResult
    public mutating func followMissions(
        _ successor: (MissionKey) -> MissionKey?, nexts: ((MissionKey) -> MissionKey?)? = nil,
        holds: ((MissionKey, ItemRef) -> Bool)? = nil
    ) -> [MissionKey: MissionKey] {
        var renamed: [MissionKey: MissionKey] = [:]
        func went(_ key: MissionKey, to next: MissionKey?) -> MissionKey? {
            if let next { renamed[key] = next }
            return next
        }
        func follow(_ key: MissionKey) -> MissionKey? { went(key, to: successor(key)) }
        func followNext(_ key: MissionKey) -> MissionKey? {
            guard let nexts else { return follow(key) }
            return went(key, to: nexts(key))
        }
        func followFrom(_ key: MissionKey, of change: OrderChange) -> MissionKey? {
            let next: MissionKey? = if change.first != nil, let nexts { nexts(key) } else { successor(key) }
            guard let next, holds?(next, change.ref) ?? true else { return nil }
            return went(key, to: next)
        }
        renameMissions(follow, nexts: followNext, froms: followFrom)
        return renamed
    }

    /// Names the missions changes name as `rename` gives, where it gives one; where each is set as next, as `nexts` gives;
    /// the mission one that doesn't move its pull request was in, as `froms` gives.
    private mutating func renameMissions(
        _ rename: (MissionKey) -> MissionKey?, nexts: (MissionKey) -> MissionKey?,
        froms: (MissionKey, OrderChange) -> MissionKey?
    ) {
        func renamed(_ key: MissionKey?, by rename: (MissionKey) -> MissionKey?) -> MissionKey? {
            key.map { rename($0) ?? $0 }
        }
        for (ref, change) in changes {
            var renaming = change
            if let placement = change.placement?.mission {
                renaming.placement = renamed(placement, by: rename).map(OrderPlacement.into)
            }
            if change.placement != nil {
                renaming.from = renamed(change.from, by: rename)
            } else if let from = change.from {
                renaming.from = froms(from, change) ?? from
            }
            renaming.first = renamed(change.first, by: nexts)
            if renaming != changes[ref] { changes[ref] = renaming }
        }
    }

    /// Notes what the orders did to each change since BriefBar last looked: one that went against it overrides it from then
    /// on, though that order puts it back where it was, until you put yours back (`OrderChange.overridden`); one that moved
    /// it toward yours, or changed what you didn't, becomes what yours replaced, for what it does next to be told from, and
    /// one that took it out of a stack, chain or session's pull requests you changed it in, agreeing, gets what you set
    /// there (`OrderChange.follow`), but your next while another of yours holds there, and gives your next back once it no
    /// longer names it (`OrderChange.unfollow`); a revision told before your change, which BriefBar sees only now, is what
    /// yours replaced; and an override by an order BriefBar forgot since is no more, so that yours holds again. Then what
    /// an order takes back that a split moved, as it put a line across the split, goes back as one (`splitsTakenBack`), and
    /// what a split moved knows the lines it sees that don't cross the split, which never take it back
    /// (`OrderChange.linedWith`). Telling the same order again notes nothing. True when that noted something.
    /// - Parameters:
    ///   - now: when BriefBar saw it, for an order whose last change it can't tell.
    ///   - status: where each pull request stands, as BriefBar sees it, for a line across a split that holds nothing up
    ///     anymore; open by default.
    @discardableResult
    public mutating func noteOverrides(
        in orders: DeclaredOrders, now: Date = Date(), status: (ItemRef) -> OrderStatus = { _ in .open }
    ) -> Bool {
        var noted = false
        // The orders where one you set as next holds, as it will once back where you set it: another doesn't go over to one
        // of those (`OrderChange.follow`).
        var nexts = Set(changes.values.compactMap { change -> UUID? in
            var change = change
            change.unfollow(in: orders)
            guard case .plan(let id)? = change.first, change.holds(in: orders) else { return nil }
            return id
        })
        // The latest first, for the one you set as next last to go over to an order before another you set earlier.
        for before in changes.values.sorted(by: { ($0.changedAt, $0.ref) > ($1.changedAt, $1.ref) }) {
            let ref = before.ref
            var change = before
            if let overridden = change.overridden {
                guard orders.plan(overridden.by) == nil else { continue }
                // It learns no line its order told meanwhile: one across a split takes it back, as it's later than your
                // change (`splitsTakenBack`).
                change.overridden = nil
            }
            change.unfollow(in: orders)
            change.rebase(on: orders)
            if let plan = change.changedBy(in: orders).first {
                change.overridden = OrderChange.Overridden(by: plan.id, at: min(plan.updatedAt, now))
            } else if orders.plans.contains(where: { change.replaced.orders[$0.id] != $0.entry(for: ref).map { Set($0.after) } }) {
                if let id = change.follow(into: orders, besides: nexts) { nexts.insert(id) }
                change.replaced = OrderPlace(of: ref, in: orders)
            }
            if change != before {
                changes[ref] = change
                noted = true
            }
        }
        let split = splitLines(in: orders, now: now, status: status)
        for (ref, overridden) in split.taken {
            guard var change = changes[ref] else { continue }
            change.overridden = overridden
            changes[ref] = change
            noted = true
        }
        for (ref, seen) in split.seen {
            guard var change = changes[ref], !seen.isSubset(of: change.linedWith) else { continue }
            change.linedWith.formUnion(seen)
            changes[ref] = change
            noted = true
        }
        return noted
    }

    /// What the orders take back now that a split moved (`OrderEdit.split`), as `noteOverrides` notes it: the pull requests a
    /// split moved together, from a session's order's mission to the same mission, or one out of missions, go back into
    /// that order's mission as one, overridden by it, once a revision of it told after the split puts a line, either way,
    /// between one of them and one of the order's that the split didn't put with them, in its mission or split off it to
    /// another: so that no split cuts the order's lines. Only a line that crosses the split as BriefBar first sees it: not
    /// one they had when you last changed them, nor one BriefBar saw since that didn't cross then (`OrderChange.linedWith`),
    /// so not one that comes to cross as a pull request leaves them or comes back to the order's mission, nor one you put
    /// yours back over (`OrderEdit.putBack`), so telling the same again takes nothing back. Not a line you took away, nor
    /// one to a pull request you moved elsewhere yourself, as Move to Mission did; nor one that holds nothing up anymore,
    /// from one that merged or to one that merged or closed, as `status` tells, until it does again. One the order named as
    /// the split moved it, and doesn't anymore, stays: it has nowhere to go back to. And one back where the split put it
    /// since its order took back what the split moved with it, as Undo, or an order BriefBar forgot that had taken it, brings
    /// it back, goes back with them, so that the order's lines among them aren't cut either; but not one the split moved
    /// there since (`takenBack(with:in:)`).
    /// - Parameter status: where each pull request stands, as BriefBar sees it; open by default.
    /// - Returns: each it takes back, with what its note says: the line its order put across, or the one it went back with.
    public func splitsTakenBack(
        in orders: DeclaredOrders, now: Date = Date(), status: (ItemRef) -> OrderStatus = { _ in .open }
    ) -> [ItemRef: OrderChange.Overridden] {
        splitLines(in: orders, now: now, status: status).taken
    }

    /// What `splitsTakenBack` takes back, and the lines across a split BriefBar sees now that never take back what it
    /// moved, by the pull request it moved, for `OrderChange.linedWith`.
    private func splitLines(
        in orders: DeclaredOrders, now: Date, status: (ItemRef) -> OrderStatus
    ) -> (taken: [ItemRef: OrderChange.Overridden], seen: [ItemRef: Set<ItemRef>]) {
        let holding = holding(in: orders)
        var groups: [SplitGroup: [OrderChange]] = [:]
        for change in changes.values {
            guard let group = SplitGroup(change), let plan = orders.plan(group.order), holding[change.ref] != nil,
                  change.splitAttached || plan.contains(change.ref)
            else { continue }
            groups[group, default: []].append(change)
        }
        var taken: [ItemRef: OrderChange.Overridden] = [:]
        var seen: [ItemRef: Set<ItemRef>] = [:]
        for (group, members) in groups {
            guard let plan = orders.plan(group.order) else { continue }
            let refs = Set(members.map(\.ref))
            let found = Self.lines(across: refs, of: plan, changes: changes, holding: holding, status: status)
            seen.merge(found.seen) { $0.union($1) }
            // Told after the split moved the one it's about: one told before is what the split moved them from.
            let lines = found.across.filter { line in
                let member = refs.contains(line.after) ? line.after : line.before
                return holding[member].map { plan.updatedAt > $0.changedAt } ?? false
            }
            if let first = lines.map({ refs.contains($0.after) ? $0.after : $0.before }).min() {
                let at = min(plan.updatedAt, now)
                for ref in refs {
                    let later = lines.filter { $0.before == ref }.map(\.after)
                    let overridden: OrderChange.Overridden = if lines.contains(where: { $0.after == ref }) {
                        // Its own place in the order says it.
                        OrderChange.Overridden(by: plan.id, at: at)
                    } else if !later.isEmpty {
                        OrderChange.Overridden(by: plan.id, at: at, before: later.sorted())
                    } else {
                        OrderChange.Overridden(by: plan.id, at: at, with: first)
                    }
                    taken[ref] = overridden
                }
                continue
            }
            // Back where the split put it since the order took back the others the split moved with it: it goes back with
            // them, with the one whose line took them, or by its own place in the order where that's it. Only one of those
            // it goes back with, as Put Yours Back puts them back: not one the order took before it went there, that one of
            // them went back with; else the first of them.
            for member in members {
                let others = takenBack(with: member, in: orders)
                guard let at = others.compactMap(\.overridden?.at).max() else { continue }
                let with = Set(others.map(\.ref)).union([member.ref])
                let leads = Set(others.compactMap { $0.overridden?.with }).union(others.filter { $0.overridden?.with == nil }.map(\.ref))
                    .intersection(with)
                taken[member.ref] = if leads.contains(member.ref) {
                    OrderChange.Overridden(by: plan.id, at: at)
                } else {
                    OrderChange.Overridden(by: plan.id, at: at, with: leads.min() ?? others.first?.ref)
                }
            }
        }
        return (taken, seen)
    }

    /// What its order took back of what a split moved with this one, that this one goes back with, back where the split put
    /// it (`splitsTakenBack`), and that Put Yours Back on it puts back with it: those it took back since the split moved this
    /// one there, or you put it back there, whoever took it since, so not one taken before; where its order took this one
    /// back too, those it took with it, or before, as it went back with them, not after. None for one its order doesn't
    /// name anymore that it didn't stack with its own, which stays.
    func takenBack(with change: OrderChange, in orders: DeclaredOrders) -> [OrderChange] {
        guard let group = SplitGroup(change), let plan = orders.plan(group.order),
              change.splitAttached || plan.contains(change.ref)
        else { return [] }
        let taken = changes.values.filter { $0.ref != change.ref && SplitGroup($0) == group && $0.overridden?.by == group.order }
        // Taken since the split moved this one there, or you put it back there.
        func since(_ other: OrderChange) -> Bool {
            guard let at = other.overridden?.at else { return false }
            return change.splitAt.map { $0 < at } ?? true
        }
        let with = if let own = change.overridden, own.by == group.order {
            // Those it took with this one, and those this one went back with, taken before it since it went there.
            taken.filter { other in
                other.overridden?.at == own.at || since(other) && other.overridden.map { $0.at <= own.at } == true
            }
        } else {
            taken.filter(since)
        }
        return with.sorted { $0.ref < $1.ref }
    }

    /// An order's lines between these pull requests a split moved together and the rest of its own. `across`: those across
    /// the split, to one of the order's the split didn't put with them, in its mission or split off it to another, but one
    /// either end knows (`OrderChange.linedWith`, of a split from this order's mission), one you took away, one to a pull
    /// request you moved elsewhere yourself, and one that holds nothing up anymore, as `status` tells. `seen`: by the one of
    /// these each is about, those it doesn't know that never take them back, however they come to cross: among these, to a
    /// pull request you moved elsewhere yourself, and one you took away, but not one that holds nothing up, which BriefBar
    /// sees once it holds something up again; and one the other end knows, so that it stays known whatever becomes of the
    /// other's change.
    /// - Parameters:
    ///   - changes: all your changes, for what each end knows.
    ///   - holding: your changes that hold.
    static func lines(
        across refs: Set<ItemRef>, of plan: OrderPlan, changes: [ItemRef: OrderChange], holding: [ItemRef: OrderChange],
        status: (ItemRef) -> OrderStatus
    ) -> (across: [OrderEdge], seen: [ItemRef: Set<ItemRef>]) {
        let key = MissionKey.plan(plan.id)
        func isOther(_ ref: ItemRef) -> Bool {
            guard !refs.contains(ref), plan.contains(ref) else { return false }
            guard let change = holding[ref], let placement = change.placement else { return true }
            return placement == .into(key) || change.splitFrom == key
        }
        func knows(_ ref: ItemRef, _ other: ItemRef) -> Bool {
            guard let change = changes[ref], change.splitFrom == key else { return false }
            return change.linedWith.contains(other)
        }
        var across: [OrderEdge] = []
        var seen: [ItemRef: Set<ItemRef>] = [:]
        for entry in plan.entries {
            let later = entry.ref
            for earlier in entry.after where earlier != later {
                let holdsUp = !status(later).hasEnded && status(earlier) != .merged
                if refs.contains(later), refs.contains(earlier) {
                    if holdsUp || knows(later, earlier) || knows(earlier, later) {
                        seen[later, default: []].insert(earlier)
                        seen[earlier, default: []].insert(later)
                    }
                    continue
                }
                let (own, other) = refs.contains(later) ? (later, earlier) : (earlier, later)
                guard refs.contains(own), !knows(own, other) else { continue }
                if knows(other, own) || holdsUp && (!isOther(other) || holding[later]?.notAfter.contains(earlier) == true) {
                    seen[own, default: []].insert(other)
                } else if holdsUp {
                    across.append(OrderEdge(earlier, later))
                }
            }
        }
        return (across, seen)
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

/// The pull requests a split moved together, as their changes say: from a session's order's mission to the same mission,
/// or each one out of missions on its own.
struct SplitGroup: Hashable {
    var order: UUID
    var placement: OrderPlacement
    /// The one it is, for one moved out of missions.
    var alone: ItemRef?

    /// Nil for a change no split made from an order's mission.
    init?(_ change: OrderChange) {
        guard case .plan(let order)? = change.splitFrom, let placement = change.placement else { return nil }
        self.order = order
        self.placement = placement
        alone = placement == .outside ? change.ref : nil
    }
}

/// A change as the preferences keep it.
private struct ChangeRecord: Codable {
    struct Replaced: Codable {
        var order: UUID
        var after: [ItemRef]
    }

    var pullRequest: ItemRef
    var first: String?
    var after: [ItemRef]?
    var notAfter: [ItemRef]?
    var placed: String?
    var from: String?
    var changedAt: Date
    var replaced: [Replaced]?
    /// Where its orders put it when you changed it, when that's not what it replaced since; nil when it is.
    var found: [Replaced]?
    var overriddenBy: UUID?
    var overriddenAt: Date?
    /// For one an order took back as it put a line across a split: what it put after it there, or the one it went back with.
    var overriddenBefore: [ItemRef]?
    var overriddenWith: ItemRef?
    /// A split moved it; nil for any other change.
    var split: Bool?
    /// What a split moved: the pull requests its order put it after, or after it, that it knows; nil for none.
    var linedWith: [ItemRef]?
    /// A split moved it as one stacked with its order's own that the order didn't name; nil for any other change.
    var splitAttached: Bool?
    /// When a split moved it, or you put it back there; nil for any other change.
    var splitAt: Date?

    private enum CodingKeys: String, CodingKey {
        case pullRequest, first, after, notAfter, placed, from, changedAt, replaced, found, overriddenBy, overriddenAt,
             overriddenBefore, overriddenWith, split, linedWith, splitAttached, splitAt
    }

    init(_ change: OrderChange) {
        pullRequest = change.ref
        first = change.first?.description
        after = change.after.isEmpty ? nil : change.after
        notAfter = change.notAfter.isEmpty ? nil : change.notAfter
        placed = change.placement?.description
        from = change.from?.description
        changedAt = change.changedAt
        replaced = Self.records(change.replaced)
        found = change.found == change.replaced ? nil : Self.records(change.found) ?? []
        overriddenBy = change.overridden?.by
        overriddenAt = change.overridden?.at
        overriddenBefore = change.overridden.flatMap { $0.before.isEmpty ? nil : $0.before }
        overriddenWith = change.overridden?.with
        split = change.bySplit ? true : nil
        linedWith = change.linedWith.isEmpty ? nil : change.linedWith.sorted()
        splitAttached = change.splitAttached ? true : nil
        splitAt = change.bySplit ? change.splitAt : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pullRequest = try container.decode(ItemRef.self, forKey: .pullRequest)
        changedAt = try container.decode(Date.self, forKey: .changedAt)
        first = try? container.decodeIfPresent(String.self, forKey: .first)
        after = Self.refs(container, .after)
        notAfter = Self.refs(container, .notAfter)
        placed = try? container.decodeIfPresent(String.self, forKey: .placed)
        from = try? container.decodeIfPresent(String.self, forKey: .from)
        replaced = (try? container.decodeIfPresent([ReplacedLossy].self, forKey: .replaced))?.compactMap(\.value)
        found = (try? container.decodeIfPresent([ReplacedLossy].self, forKey: .found))?.compactMap(\.value)
        overriddenBy = try? container.decodeIfPresent(UUID.self, forKey: .overriddenBy)
        overriddenAt = try? container.decodeIfPresent(Date.self, forKey: .overriddenAt)
        overriddenBefore = Self.refs(container, .overriddenBefore)
        overriddenWith = try? container.decodeIfPresent(ItemRef.self, forKey: .overriddenWith)
        split = try? container.decodeIfPresent(Bool.self, forKey: .split)
        linedWith = Self.refs(container, .linedWith)
        splitAttached = try? container.decodeIfPresent(Bool.self, forKey: .splitAttached)
        splitAt = try? container.decodeIfPresent(Date.self, forKey: .splitAt)
    }

    private static func records(_ place: OrderPlace) -> [Replaced]? {
        let orders = place.orders.sorted { $0.key.uuidString < $1.key.uuidString }
        return orders.isEmpty ? nil : orders.map { Replaced(order: $0.key, after: $0.value.sorted()) }
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
        func place(_ records: [Replaced]) -> OrderPlace {
            var orders: [UUID: Set<ItemRef>] = [:]
            for record in records where orders[record.order] == nil {
                orders[record.order] = Set(record.after.filter { $0.kind.isPullRequest && $0 != pullRequest })
            }
            return OrderPlace(orders: orders)
        }
        let overridden = overriddenBy.map { by in
            OrderChange.Overridden(
                by: by, at: overriddenAt ?? changedAt, before: refs(overriddenBefore),
                with: overriddenWith.flatMap { $0.kind.isPullRequest && $0 != pullRequest ? $0 : nil }
            )
        }
        let change = OrderChange(
            ref: pullRequest, first: first.flatMap(MissionKey.init), after: after,
            notAfter: refs(notAfter).filter { !after.contains($0) }, placement: placed.flatMap(OrderPlacement.init),
            from: from.flatMap(MissionKey.init), changedAt: changedAt, replaced: place(replaced ?? []), found: found.map(place),
            overridden: overridden, bySplit: split == true, linedWith: Set(refs(linedWith)),
            splitAttached: split == true && splitAttached == true, splitAt: split == true ? splitAt : nil
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

/// What a split does with one of its groups: its pull requests, and where they go, a mission of your own, new or split off
/// the same mission before, or none.
public struct OrderSplitMove: Hashable, Sendable {
    public var refs: [ItemRef]
    public var to: OrderPlacement

    public init(_ refs: [ItemRef], to: OrderPlacement) {
        self.refs = refs
        self.to = to
    }
}

/// What you ask of a pull request's Mission menu, or of a mission's.
public enum OrderEdit: Equatable, Sendable {
    /// Set as Next to Merge in that mission, or not anymore.
    case setNext(ItemRef, in: MissionKey, Bool)
    /// Merge After: it merges after the other one, in that mission, or not anymore.
    case mergeAfter(ItemRef, ItemRef, in: MissionKey, Bool)
    /// Move to Mission: these, from the mission they're in, if any, into another, a new one of your own, or none. Several
    /// at once, with one Undo.
    case move([ItemRef], to: OrderPlacement, from: MissionKey?)
    /// Split: the split Apple Intelligence suggested for a mission (`MissionSplit`), as you confirmed it, all at once, with
    /// one Undo: each group's pull requests from that mission to where it goes, each keeping which mission it was split from.
    case split(MissionKey, [OrderSplitMove])
    /// Undo Your Changes to It.
    case undo(ItemRef)
    /// Undo Your Changes to This Mission: to its pull requests, those you put in it and those you moved out of it.
    case undoMission(MissionKey)
    /// Put Yours Back: your change holds again, over the later one of its orders. A split's pull request goes back with what
    /// its order took back of what the split moved with it, where it would go back with them
    /// (`OrderChanges.takenBack(with:in:)`).
    case putBack(ItemRef)
}

extension OrderChanges {
    /// What Put Yours Back on this one put back, by what it touched (`apply`) and the orders it went by: with what a split
    /// moved that its order took back, that it put back with it, those too (`takenBack(with:in:)`); never another it's no
    /// longer next instead of.
    public static func putBack(_ ref: ItemRef, touched: [ItemRef: OrderChange?], orders: DeclaredOrders) -> [ItemRef] {
        guard let change = touched[ref] ?? nil else { return [ref] }
        return (OrderChanges(touched.values.compactMap { $0 }).takenBack(with: change, in: orders).map(\.ref) + [ref]).sorted()
    }

    /// Makes a change, as you asked for it from a menu, and says what each change it touched was before, for Undo. It
    /// refuses what the menu doesn't offer: a cycle with a stacked branch or your own changes, Set as Next on one stacked on a
    /// pull request that hasn't merged or that still targets one that merged, and one more change than `mostChanges`;
    /// refused, nothing changes.
    /// - Parameters:
    ///   - missions: as By Mission shows them now.
    ///   - orders: the orders sessions told.
    ///   - stacked: what BriefBar sees each pull request stacked on (`OrderBoard.stacked`), those in no mission included.
    /// - Returns: each change it touched, by pull request, as it was: nil where there was none.
    @discardableResult
    public mutating func apply(
        _ edit: OrderEdit, missions: [OrderMission], orders: DeclaredOrders, stacked: [ItemRef: Set<ItemRef>] = [:],
        now: Date = Date()
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
                change.found = change.replaced
                change.overridden = nil
                change.linedWith = change.lined(in: orders)
            }
            try edited.set(change)
        }
        func remove(_ ref: ItemRef) {
            guard let change = edited.changes[ref] else { return }
            if touched[ref] == nil { touched[ref] = .some(change) }
            edited.remove(ref)
        }
        // One for each mission: the others set as next there aren't anymore, and one beside its order that you set as next
        // only goes back beside it. Also one an order went against since that you changed more of, such as moved, which stays
        // as that order left it but for that: should BriefBar forget that order, it doesn't come back as a second next there.
        // One an order went against that's only set as next stays as it is, its note and Put Yours Back with it: should
        // BriefBar forget that order, it says you set this one as next there later (`nextSince`).
        func clearOtherFirsts(named key: MissionKey, in mission: OrderMission?, besides ref: ItemRef) throws {
            for other in edited.all where other.ref != ref {
                guard let first = other.first, mission.map({ Self.names($0, first) }) ?? (first == key) else { continue }
                let holds = other.holds(in: orders)
                var cleared = other
                cleared.first = nil
                cleared.detachIfDone()
                if cleared.isEmpty, !holds { continue }
                try keep(cleared, stamped: holds)
            }
        }

        switch edit {
        case .setNext(let ref, let key, let on):
            let (mission, step, isAttached) = try Self.find(ref, in: key, missions)
            var change = current(ref)
            if on {
                guard !step.status.hasEnded else { throw OrderChangeError.ended }
                if let notNext = mission.notNext(ref) { throw notNext }
                change.first = key
                change.after = []
                change.notAfter = []
                if isAttached { change.attach(to: key) }
                try clearOtherFirsts(named: key, in: mission, besides: ref)
            } else {
                change.first = nil
                change.detachIfDone()
            }
            if change.placement == nil { change.from = key }
            try keep(change)

        case .mergeAfter(let ref, let other, let key, let on):
            let (_, step, isAttached) = try Self.find(ref, in: key, missions)
            guard other != ref else { throw OrderChangeError.waitsForIt(other) }
            var change = current(ref)
            if on {
                if Self.waits(other, for: ref, in: missions, stacked: stacked) { throw OrderChangeError.waitsForIt(other) }
                change.first = nil
                if !change.after.contains(other) { change.after.append(other) }
                change.notAfter.removeAll { $0 == other }
                if isAttached { change.attach(to: key) }
            } else {
                let prerequisite = step.prerequisites.first { $0.ref == other }
                if prerequisite?.origins.contains(where: \.isStacked) == true { throw OrderChangeError.stacked(on: other) }
                change.after.removeAll { $0 == other }
                // What its order, or the one set as next, puts it after too: taken away.
                let byOthers = prerequisite?.origins.contains { origin in
                    if case .declared = origin { return true }
                    return origin == .yourNext
                } ?? false
                if byOthers, !change.notAfter.contains(other) { change.notAfter.append(other) }
                change.detachIfDone()
            }
            if change.placement == nil { change.from = key }
            try keep(change)

        case .move(let refs, let placement, let from):
            let moving = Set(refs)
            for ref in refs {
                // Not an order that lists it apart, for its story: it isn't in that one.
                let source = from ?? missions.first { mission in (mission.steps + mission.attached).contains { $0.ref == ref } }?.key
                if let source, placement == .into(source) { continue }
                var change = current(ref)
                change.first = nil
                change.after = []
                change.notAfter = []
                change.placement = placement
                change.from = source
                change.bySplit = false
                change.splitAttached = false
                change.splitAt = nil
                try keep(change)
            }
            // A chain named by one of these goes on by another of its own pull requests, as when that one ends.
            for ref in refs {
                guard let chain = missions.first(where: { $0.kind == .stack && $0.steps.contains { $0.ref == ref } }),
                      let next = Self.ownOpen(of: chain, besides: moving, placed: edited.holding(in: orders))
                else { continue }
                let before = edited.changes
                edited.rename { $0 == ref ? next : nil }
                for (other, change) in before where edited.changes[other] != change && touched[other] == nil {
                    touched[other] = .some(changes[other])
                }
            }

        case .undo(let ref):
            remove(ref)

        case .split(let source, let moves):
            // Only the mission's own, which no change of yours puts anywhere (`MissionSplitting`): none of them names a chain
            // or another mission that would need to go on by another.
            let order: OrderPlan? = if case .plan(let id) = source { orders.plan(id) } else { nil }
            for move in moves {
                for ref in move.refs {
                    var change = current(ref)
                    change.first = nil
                    change.after = []
                    change.notAfter = []
                    change.placement = move.to
                    change.from = source
                    change.bySplit = true
                    change.splitAttached = order.map { !$0.contains(ref) } ?? false
                    change.splitAt = now
                    try keep(change)
                }
            }

        case .undoMission(let key):
            for change in edited.undone(in: key, missions: missions) {
                remove(change.ref)
            }

        case .putBack(let ref):
            guard let change = edited.changes[ref] else { break }
            // A split's goes back with what its order took back of what the split moved with it, where it would go back with
            // them, as one change, each keeping the order's lines it has now, and back where the split put it from now on
            // (`OrderChanges.takenBack(with:in:)`); this one last.
            let others = edited.takenBack(with: change, in: orders).map(\.ref)
            for ref in others + [ref] {
                guard var change = edited.changes[ref] else { continue }
                if change.splitFrom != nil { change.splitAt = now }
                // What you set in a mission BriefBar worked out, which an order took it out of, is that order's; a next that
                // went over to an order that no longer names it is back where you set it.
                change.unfollow(in: orders)
                change.follow(into: orders)
                // Back in the mission you set it as next or put it after another in, where its order no longer has it, even
                // when nothing's left there to show it but this one.
                if change.placement == nil, let key = change.first ?? change.from {
                    let mission = missions.first { Self.names($0, key) }
                    if mission.map({ !$0.steps.contains { $0.ref == ref } }) ?? Self.lasts(key, in: orders) {
                        change.placement = .into(key)
                        change.from = nil
                    }
                }
                if let key = change.first {
                    try clearOtherFirsts(named: key, in: missions.first { Self.names($0, key) }, besides: ref)
                }
                try keep(change)
            }
        }
        self = edited
        return touched
    }

    /// Whether a mission a key names is there to put a pull request back in, though By Mission shows nothing of it now: an
    /// order BriefBar still keeps, or a mission of your own.
    static func lasts(_ key: MissionKey, in orders: DeclaredOrders) -> Bool {
        switch key {
        case .plan(let id): orders.plan(id) != nil
        case .mine: true
        case .stack, .chain, .family, .story: false
        }
    }

    /// Whether a mission is the one a key names: by its own key, or a chain by one of its own pull requests, as a story's
    /// mission can have a chain among its own.
    static func names(_ mission: OrderMission, _ key: MissionKey) -> Bool {
        if mission.key == key { return true }
        guard case .chain(let anchor) = key, mission.kind == .stack || mission.isStory else { return false }
        return mission.steps.contains { $0.ref == anchor }
    }

    /// The changes Undo Your Changes to This Mission takes back, as `apply` does and its ⋯ counts them: to the mission's pull
    /// requests, and those that put pull requests in it or moved them out of it, set one as next or put one after another
    /// in it, a chain by any of its own pull requests. A next that went over to an order (`OrderChange.follow`) is that
    /// order's mission's, not the one you set it in.
    /// - Parameter missions: as By Mission shows them now.
    public func undone(in key: MissionKey, missions: [OrderMission]) -> [OrderChange] {
        let mission = missions.first { $0.key == key }
        let refs = Set((mission?.steps ?? []).map(\.ref) + (mission?.attached ?? []).map(\.ref))
        func isThis(_ named: MissionKey?) -> Bool {
            guard let named else { return false }
            return mission.map { Self.names($0, named) } ?? (named == key)
        }
        return all.filter { change in
            refs.contains(change.ref) || isThis(change.placement?.mission)
                || isThis(change.placement == nil ? change.first ?? change.from : change.from)
        }
    }

    /// Puts back the changes an edit touched, as `apply` said they were: each as you'd made it, so a revision told since
    /// that goes against it shows instead, as for any change of yours. One a split moved, back where the split put it,
    /// knows the lines of its order it knew then, and those it saw there since, where it stayed (`OrderChange.linedWith`);
    /// not those its order told while it was out, moved, undone or taken by another order: one of those across the split is
    /// later than your change, so it takes what the split moved back (`splitsTakenBack`), as it would have had you never
    /// changed it. One limit: another the split moved from that order that saw one of those while this one was out, as
    /// you'd moved it in with them, still knows it, as BriefBar doesn't keep when it saw it, and a line either end knows
    /// takes nothing back. Where its order took it back since, it stays taken back, as its order took it.
    /// - Parameter orders: the orders sessions told.
    public mutating func restore(_ touched: [ItemRef: OrderChange?], orders: DeclaredOrders) {
        for (ref, was) in touched {
            guard var change = was, !change.isEmpty else {
                changes[ref] = nil
                continue
            }
            if let group = SplitGroup(change), change.holds(in: orders) {
                let now = changes[ref]
                if let now, SplitGroup(now) == group, now.holds(in: orders) {
                    change.linedWith.formUnion(now.linedWith)
                } else if let now, SplitGroup(now) == group, let taken = now.overridden, taken.by == group.order {
                    change.overridden = taken
                }
            }
            changes[ref] = change
        }
    }

    /// A pull request in a mission: one of its steps, or one stacked with them that its order doesn't name.
    static func find(_ ref: ItemRef, in key: MissionKey, _ missions: [OrderMission]) throws -> (OrderMission, OrderStep, Bool) {
        guard let mission = missions.first(where: { $0.key == key }) else { throw OrderChangeError.notInAMission }
        if let step = mission.steps.first(where: { $0.ref == ref }) { return (mission, step, false) }
        if let step = mission.attached.first(where: { $0.ref == ref }) { return (mission, step, true) }
        throw OrderChangeError.notInAMission
    }

    /// What a pull request was stacked on that merged, while it still targets that one's branch: retarget it first. Its
    /// standing says so, with the branch to retarget it to; else a branch it targets that merged says so, whatever its
    /// standing says first, such as one its order puts it after that closed, or none, for one its order doesn't name.
    static func retarget(of step: OrderStep) -> (after: ItemRef, to: String?)? {
        if case .retarget(let merged, let branch) = step.standing { return (merged, branch) }
        guard let merged = step.prerequisites.first(where: { $0.status == .merged && $0.origins.contains(.branch) })
        else { return nil }
        return (merged.ref, nil)
    }

    /// Whether one waits for another, directly or through others, by a stacked branch or a change of yours: what a menu
    /// can't undo by putting the other after it.
    /// - Parameter stacked: what BriefBar sees each pull request stacked on, through those in no mission too.
    static func waits(
        _ later: ItemRef, for earlier: ItemRef, in missions: [OrderMission], stacked: [ItemRef: Set<ItemRef>] = [:]
    ) -> Bool {
        waits(later, for: earlier, in: waitGraph(missions, stacked: stacked))
    }

    /// What each pull request waits for by a stacked branch or a change of yours, for `waits`: worked out once for a menu.
    static func waitGraph(_ missions: [OrderMission], stacked: [ItemRef: Set<ItemRef>]) -> [ItemRef: Set<ItemRef>] {
        var before = stacked
        for mission in missions {
            for step in mission.steps + mission.attached {
                for prerequisite in step.prerequisites where prerequisite.origins.contains(where: { $0.isStacked || $0 == .yours }) {
                    before[step.ref, default: []].insert(prerequisite.ref)
                }
            }
        }
        return before
    }

    /// Whether one waits for another, directly or through others, by `waitGraph`.
    static func waits(_ later: ItemRef, for earlier: ItemRef, in before: [ItemRef: Set<ItemRef>]) -> Bool {
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
        /// What it was stacked on merged, and it still targets that one's branch: retarget it first.
        case retarget(after: ItemRef, to: String?)
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
    /// Merge After: the mission's other pull requests that haven't merged or closed, and what it merges after that has, in
    /// its order, then those stacked with them that its order doesn't name, then what it merges after elsewhere, by your
    /// change or a stacked branch.
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
    ///   - stacked: what BriefBar sees each pull request stacked on (`OrderBoard.stacked`), those in no mission included.
    ///   - withPrerequisites: Merge After's, which only its menu needs; without them, such as for VoiceOver's actions, none.
    public static func of(
        _ ref: ItemRef, in mission: MissionKey? = nil, missions: [OrderMission], changes: OrderChanges, orders: DeclaredOrders,
        stacked: [ItemRef: Set<ItemRef>] = [:], withPrerequisites: Bool = true
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
        // The one you set as next there, by your change that holds, whether or not a stacked branch lets it be or BriefBar can
        // see it now; but not one you set before another there that's next instead (`nextSince`).
        let isSet = change.map { change in
            change.holds(in: orders) && change.first.map { OrderChanges.names(shown, $0) } == true
        } ?? false
        let isSince = step.notes.contains { if case .nextSince = $0 { true } else { false } }
        let next: Next = if step.status.hasEnded {
            .ended
        } else if isSet && !isSince {
            .isSet
        } else {
            switch shown.notNext(ref) {
            case .stacked(let open)?: .stacked(on: open)
            case .retarget(let merged, let branch)?: .retarget(after: merged, to: branch)
            default: .offered
            }
        }
        // What it can go after, and what it goes after now, whatever became of that, for you to take it away.
        guard withPrerequisites else {
            return MissionChoices(
                ref: ref, mission: shown.key, next: next, prerequisites: [], targets: targets, canUndo: change != nil, canPutBack: canPutBack
            )
        }
        let current = Set(step.prerequisites.map(\.ref))
        var others = (shown.steps + shown.attached).filter { other in
            other.ref != ref && (current.contains(other.ref) || !other.status.hasEnded)
        }.map(\.ref)
        for prerequisite in step.prerequisites where !others.contains(prerequisite.ref) {
            others.append(prerequisite.ref)
        }
        var waits: [ItemRef: Set<ItemRef>]?
        let prerequisites = others.map { other in
            let origins = step.prerequisites.first { $0.ref == other }?.origins
            let state: Prerequisite.State
            if origins?.contains(where: \.isStacked) == true {
                state = .stacked
            } else if origins != nil {
                state = .checked
            } else {
                let graph = waits ?? OrderChanges.waitGraph(missions, stacked: stacked)
                waits = graph
                state = OrderChanges.waits(other, for: ref, in: graph) ? .waitsForIt : .unchecked
            }
            return Prerequisite(ref: other, state: state)
        }
        return MissionChoices(
            ref: ref, mission: shown.key, next: next, prerequisites: prerequisites, targets: targets, canUndo: change != nil,
            canPutBack: canPutBack
        )
    }
}

// MARK: - What sessions are told

extension OrderText {
    /// What the session that told an order is told to do with the user's changes to it.
    public static let keepUserChanges = """
        Keep these in the order you tell, unless you and the user decided otherwise. A later change of yours that goes \
        against one of these shows instead of the user's, and the user can put theirs back.
        """

    /// Whether a change of the user's is about an order: its pull request is in it, or was when they changed it, or they
    /// set it as next there, or moved it there or out of it.
    public static func isAbout(_ change: OrderChange, _ plan: OrderPlan) -> Bool {
        let key = MissionKey.plan(plan.id)
        return plan.entry(for: change.ref) != nil || change.replaced.orders[plan.id] != nil || change.first == key
            || change.from == key || change.placement == .into(key)
    }

    /// The user's changes to an order that hold (`OrderChanges.holding`), as the session that told it is told them, a line
    /// each, by references and numbers, never titles: "!4079 in contoso merges first: the user set it as next to merge."
    /// One the user moved into this order's mission says so, then what they set there, such as next to merge; one they moved
    /// to another mission, or out of every one, says only that.
    public static func userChanges(to plan: OrderPlan, holding changes: [ItemRef: OrderChange]) -> [String] {
        let key = MissionKey.plan(plan.id)
        return changes.values.filter { isAbout($0, plan) }.sorted { $0.ref < $1.ref }.flatMap { change -> [String] in
            let ref = change.ref
            let label = ref.fullOrderLabel
            var lines: [String] = []
            if let placement = change.placement, !change.isAttached {
                switch placement {
                case .into(let mission) where mission == key: lines.append("\(label) is in this order's mission: the user moved it there.")
                case .into: return ["\(label) is in another mission: the user moved it."]
                case .outside: return ["\(label) is in no mission: the user moved it out."]
                }
            }
            if change.first == key { lines.append("\(label) merges first: the user set it as next to merge.") }
            if !change.after.isEmpty {
                lines.append("\(label) merges after \(list(change.after, near: ref)): the user put it there.")
            }
            if !change.notAfter.isEmpty {
                lines.append("\(label) doesn't merge after \(list(change.notAfter, near: ref)): the user took that away.")
            }
            return lines
        }
    }
}
