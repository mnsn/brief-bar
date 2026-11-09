import Foundation

// The orders Copilot sessions tell BriefBar, through its agents' tools: which pull requests go together, which merge after
// which, and when a session suggests reviewing one later. Each is a plan with an ID that BriefBar gives it, whoever told
// it, kept in the preferences as references, codes and dates only, never titles or anyone's words. Also what BriefBar saw
// become of their pull requests (`OrderEvidence`), and the mission you focus on (`OrderFocus`).

// MARK: - What a session tells BriefBar

/// Why a session suggests reviewing a pull request after others: one of a few reasons, kept as a code rather than in its
/// words, since plans go to the preferences.
public enum ReviewReason: String, CaseIterable, Codable, Sendable {
    /// It builds on their changes, which may still change.
    case buildsOnChanges = "builds_on_changes"
    /// It changes the same code.
    case sameCode = "same_code"
    /// Its changes include theirs until they merge.
    case stackedDiff = "stacked_diff"
    /// It depends on a decision in them.
    case needsDecision = "needs_decision"
}

/// When a session suggests reviewing a pull request: advice, which never says it's ready, and never changes where it
/// stands.
public enum ReviewTiming: Equatable, Sendable {
    /// The session says it can be reviewed now.
    case now
    /// The session suggests reviewing it after these, for this reason.
    case after([ItemRef], ReviewReason)
}

extension ReviewTiming: Codable {
    private enum CodingKeys: String, CodingKey {
        case when, pullRequests, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .when) {
        case "now":
            self = .now
        case "after":
            self = .after(
                try container.decode([ItemRef].self, forKey: .pullRequests), try container.decode(ReviewReason.self, forKey: .reason)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .when, in: container, debugDescription: "Not a review timing")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .now:
            try container.encode("now", forKey: .when)
        case .after(let refs, let reason):
            try container.encode("after", forKey: .when)
            try container.encode(refs, forKey: .pullRequests)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// An order a session told BriefBar: the pull requests that go together, which merge after which, and when it suggests
/// reviewing some. It's a mission of its own, with an ID BriefBar gave it, whoever told it, and a revision that goes up
/// each time it's replaced.
public struct OrderPlan: Identifiable, Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var ref: ItemRef
        /// What merges before it: pull requests of the same plan.
        public var after: [ItemRef]
        public var review: ReviewTiming?

        public init(ref: ItemRef, after: [ItemRef] = [], review: ReviewTiming? = nil) {
            self.ref = ref
            self.after = after
            self.review = review
        }
    }

    public var id: UUID
    /// 1 when it's told, and one more each time it's replaced, so that an agent that read an older one can't replace a
    /// newer one without seeing it.
    public var revision: Int
    public var createdAt: Date
    /// When a session last told it.
    public var updatedAt: Date
    /// The session that said it was its own. Any agent can name any session, so it says where the order came from,
    /// nothing more: it allows nothing.
    public var declaredBy: ItemRef?
    /// In the order the session listed them.
    public var entries: [Entry]

    public init(id: UUID, revision: Int = 1, createdAt: Date, updatedAt: Date, declaredBy: ItemRef? = nil, entries: [Entry]) {
        self.id = id
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.declaredBy = declaredBy
        self.entries = entries
    }

    public var refs: [ItemRef] { entries.map(\.ref) }

    public func contains(_ ref: ItemRef) -> Bool {
        entries.contains { $0.ref == ref }
    }

    public func entry(for ref: ItemRef) -> Entry? {
        entries.first { $0.ref == ref }
    }

    /// Whether it merges one before another, directly or through others.
    public func puts(_ earlier: ItemRef, before later: ItemRef) -> Bool {
        var pending = entry(for: later)?.after ?? []
        var seen: Set<ItemRef> = []
        while let ref = pending.popLast() {
            if ref == earlier { return true }
            guard seen.insert(ref).inserted else { continue }
            pending += entry(for: ref)?.after ?? []
        }
        return false
    }
}

/// What an agent asks BriefBar to keep, as it wrote it, before it's checked (`DeclaredOrders.apply`).
public struct OrderRequest: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        /// The pull request's link, in Azure DevOps or GitHub.
        public var link: String
        /// What merges before it: their links, or their numbers when only one in the list has that number.
        public var after: [String]
        public var review: Review?

        public init(link: String, after: [String] = [], review: Review? = nil) {
            self.link = link
            self.after = after
            self.review = review
        }
    }

    public enum Review: Equatable, Sendable {
        case now
        /// After these, by their links or numbers, for one of `ReviewReason`'s codes.
        case after([String], reason: String)
    }

    /// The ID BriefBar gave the plan it replaces; nil for a new one.
    public var plan: String?
    /// The revision of that plan the agent last read.
    public var revision: Int?
    /// The session that says it's its own, by its ID or link: for information only.
    public var session: String?
    public var entries: [Entry]

    public init(plan: String? = nil, revision: Int? = nil, session: String? = nil, entries: [Entry]) {
        self.plan = plan
        self.revision = revision
        self.session = session
        self.entries = entries
    }
}

/// Why BriefBar didn't keep an order an agent told it, in words for the agent. A refused order changes nothing.
public enum OrderPlanError: Error, Equatable, CustomStringConvertible {
    case empty
    case tooMany
    case notAPullRequest(String)
    case twice(ItemRef)
    /// A pull request names one that isn't in the list.
    case notInList(String, by: ItemRef)
    /// A number more than one pull request in the list has.
    case ambiguous(Int, [ItemRef])
    case itself(ItemRef)
    /// These merge after each other, so none can merge first.
    case cycle([ItemRef])
    /// These are each to be reviewed after another of them.
    case reviewCycle([ItemRef])
    case reviewAfterNothing(ItemRef)
    case notAReason(String)
    case notASession(String)
    case notAPlan(String)
    case noSuchPlan(UUID)
    /// A revision without the plan it's of.
    case planMissing
    case revisionMissing
    /// The plan was replaced since the revision the agent gave.
    case changed(since: Int, now: Int)
    /// BriefBar keeps as many orders as it can: it removes none to make room.
    case full
    /// A pull request whose source is off in BriefBar.
    case sourceOff(ItemRef)

    public var description: String {
        switch self {
        case .empty:
            return "Name the pull requests that go together, each by its link."
        case .tooMany:
            return "An order can have at most \(DeclaredOrders.mostPullRequests) pull requests."
        case .notAPullRequest(let text):
            return "‘\(Self.quote(text))’ isn't a link to a pull request in Azure DevOps or GitHub: name each one by its link."
        case .twice(let ref):
            return "\(ref.fullOrderLabel) is in the list twice."
        case .notInList(let text, let ref):
            return """
                \(ref.fullOrderLabel) names ‘\(Self.quote(text))’, which isn't in the list: name only pull requests in it, by \
                their links, or their numbers.
                """
        case .ambiguous(let number, let refs):
            return "\(number) could be \(refs.map(\.fullOrderLabel).joined(separator: " or ")): name it by its link."
        case .itself(let ref):
            return "\(ref.fullOrderLabel) can't come after itself."
        case .cycle(let refs):
            return "\(OrderText.join(refs.map(\.fullOrderLabel))) merge after each other, so none of them can merge first."
        case .reviewCycle(let refs):
            return "\(OrderText.join(refs.map(\.fullOrderLabel))) are each to be reviewed after another, so none can be first."
        case .reviewAfterNothing(let ref):
            return "Name the pull requests to review \(ref.fullOrderLabel) after."
        case .notAReason(let text):
            return """
                ‘\(Self.quote(text))’ isn't a reason BriefBar knows. Use one of \
                \(ReviewReason.allCases.map(\.rawValue).joined(separator: ", ")).
                """
        case .notASession(let text):
            return "‘\(Self.quote(text))’ isn't a Copilot session's ID or link."
        case .notAPlan(let text):
            return "‘\(Self.quote(text))’ isn't the ID of an order BriefBar gave."
        case .noSuchPlan(let id):
            return """
                BriefBar has no order \(id.uuidString.lowercased()): it may have been forgotten. Send the order without its \
                ID to start a new one.
                """
        case .planMissing:
            return "Give the order's ID with its revision to replace it, or neither to start a new one."
        case .revisionMissing:
            return "Give the revision you last read with the order's ID, to replace it."
        case .changed(let since, let now):
            return "The order changed since revision \(since), and is at revision \(now) now: read it again, then send it again."
        case .full:
            return "BriefBar keeps at most \(DeclaredOrders.mostPlans) orders, and removes none to make room: forget some first."
        case .sourceOff(let ref):
            let source = OrderText.source(of: ref)
            return """
                \(source) is off in BriefBar, so it keeps no order with \(ref.fullOrderLabel): the user can turn \(source) on \
                in BriefBar's Settings.
                """
        }
    }

    /// What an agent wrote, on one line and short.
    static func quote(_ text: String) -> String {
        let line = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.count > 100 ? String(line.prefix(99)) + "…" : line
    }
}

// MARK: - The orders BriefBar keeps

/// The orders sessions told BriefBar, each its own mission: BriefBar never merges them, whoever told them, and never
/// removes one to make room, or one that hasn't finished. You forget one, or an agent that names it does; one whose every
/// pull request BriefBar saw merge or close goes `finishedFor` after.
public struct DeclaredOrders: Equatable, Sendable {
    public static let defaultsKey = "order.plans"
    /// The most orders BriefBar keeps: it refuses more, rather than forget one.
    public static let mostPlans = 50
    public static let mostPullRequests = 50
    /// How long an order stays once BriefBar saw the last of its pull requests merge or close.
    public static let finishedFor: TimeInterval = 14 * 86_400
    /// How long an order that hasn't finished goes without its session telling it again before By Mission says so. It
    /// stays all the same.
    public static let staleAfter: TimeInterval = 30 * 86_400

    /// In the order they were first told.
    public private(set) var plans: [OrderPlan]

    public init(plans: [OrderPlan] = []) {
        self.plans = plans
    }

    public func plan(_ id: UUID) -> OrderPlan? {
        plans.first { $0.id == id }
    }

    /// The orders a pull request is in.
    public func plans(with ref: ItemRef) -> [OrderPlan] {
        plans.filter { $0.contains(ref) }
    }

    /// The orders a session said were its own.
    public func plans(declaredBy session: ItemRef) -> [OrderPlan] {
        plans.filter { $0.declaredBy == session }
    }

    /// Every pull request the orders name.
    public var refs: Set<ItemRef> {
        Set(plans.flatMap(\.refs))
    }

    // MARK: Telling

    /// Keeps a new order, or replaces one by its ID when the agent read its latest revision. Every pull request is named
    /// by its link; what one merges or is reviewed after, by a link or a number, from the same list. It refuses an order
    /// that goes round in a circle, a 51st, one with a pull request whose source is off, and anything it can't tell for
    /// sure, changing nothing. A new order that's the same as one it keeps, the same pull requests in the same order, each
    /// after the same ones and to be reviewed the same way, is that one: telling it again changes nothing.
    /// - Parameters:
    ///   - sourcesOn: the kinds of pull request whose source is on.
    ///   - newID: the ID of a new order, in tests.
    @discardableResult
    public mutating func apply(
        _ request: OrderRequest, sourcesOn: Set<ItemRef.Kind> = [.pullRequest, .gitHubPullRequest], now: Date = Date(),
        newID: UUID = UUID()
    ) throws -> OrderPlan {
        var replacing: Int?
        if let text = request.plan {
            let id = try Self.planID(text)
            guard let index = plans.firstIndex(where: { $0.id == id }) else { throw OrderPlanError.noSuchPlan(id) }
            guard let revision = request.revision else { throw OrderPlanError.revisionMissing }
            guard revision == plans[index].revision else {
                throw OrderPlanError.changed(since: revision, now: plans[index].revision)
            }
            replacing = index
        } else if request.revision != nil {
            throw OrderPlanError.planMissing
        }
        let declaredBy = try request.session.map(Self.session)
        let entries = try Self.entries(request.entries)
        if let off = entries.first(where: { !sourcesOn.contains($0.ref.kind) }) { throw OrderPlanError.sourceOff(off.ref) }
        if let index = replacing {
            plans[index].revision += 1
            plans[index].updatedAt = now
            plans[index].entries = entries
            if let declaredBy { plans[index].declaredBy = declaredBy }
            return plans[index]
        }
        if let same = plans.first(where: { $0.entries == entries }) { return same }
        guard plans.count < Self.mostPlans else { throw OrderPlanError.full }
        let plan = OrderPlan(
            id: plans.contains { $0.id == newID } ? UUID() : newID, createdAt: now, updatedAt: now, declaredBy: declaredBy,
            entries: entries
        )
        plans.append(plan)
        return plan
    }

    /// The entries an agent asked for, checked.
    static func entries(_ requested: [OrderRequest.Entry]) throws -> [OrderPlan.Entry] {
        guard !requested.isEmpty else { throw OrderPlanError.empty }
        guard requested.count <= mostPullRequests else { throw OrderPlanError.tooMany }
        var refs: [ItemRef] = []
        for entry in requested {
            guard let ref = ItemRef.from(link: entry.link), ref.kind.isPullRequest else {
                throw OrderPlanError.notAPullRequest(entry.link)
            }
            guard !refs.contains(ref) else { throw OrderPlanError.twice(ref) }
            refs.append(ref)
        }
        var entries: [OrderPlan.Entry] = []
        for (entry, ref) in zip(requested, refs) {
            let after = try targets(entry.after, among: refs, by: ref)
            var review: ReviewTiming?
            switch entry.review {
            case nil:
                review = nil
            case .now?:
                review = .now
            case .after(let texts, let text)?:
                guard let reason = ReviewReason(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                    throw OrderPlanError.notAReason(text)
                }
                let targets = try targets(texts, among: refs, by: ref)
                guard !targets.isEmpty else { throw OrderPlanError.reviewAfterNothing(ref) }
                review = .after(targets, reason)
            }
            entries.append(OrderPlan.Entry(ref: ref, after: after, review: review))
        }
        let merges = Dictionary(entries.map { ($0.ref, $0.after) }, uniquingKeysWith: { first, _ in first })
        if let cycle = OrderGraph.cycles(refs, before: merges).first { throw OrderPlanError.cycle(cycle) }
        var reviews: [ItemRef: [ItemRef]] = [:]
        for entry in entries {
            if case .after(let earlier, _) = entry.review { reviews[entry.ref] = earlier }
        }
        if let cycle = OrderGraph.cycles(refs, before: reviews).first { throw OrderPlanError.reviewCycle(cycle) }
        return entries
    }

    /// The pull requests these name, each once.
    static func targets(_ texts: [String], among refs: [ItemRef], by ref: ItemRef) throws -> [ItemRef] {
        var targets: [ItemRef] = []
        for text in texts {
            let target = try resolve(text, among: refs, by: ref)
            guard target != ref else { throw OrderPlanError.itself(ref) }
            if !targets.contains(target) { targets.append(target) }
        }
        return targets
    }

    /// A pull request in the list, by its link, or by its number, !4101 and #12 too, when only one in the list has it.
    static func resolve(_ text: String, among refs: [ItemRef], by ref: ItemRef) throws -> ItemRef {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let linked = ItemRef.from(link: trimmed) {
            guard linked.kind.isPullRequest, refs.contains(linked) else { throw OrderPlanError.notInList(text, by: ref) }
            return linked
        }
        var digits = Substring(trimmed)
        if digits.first == "!" || digits.first == "#" { digits = digits.dropFirst() }
        guard let number = ItemRef.number(String(digits)) else { throw OrderPlanError.notInList(text, by: ref) }
        let matches = refs.filter { $0.number == number }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw OrderPlanError.notInList(text, by: ref)
        default: throw OrderPlanError.ambiguous(number, matches)
        }
    }

    static func session(_ text: String) throws -> ItemRef {
        guard let ref = ItemRef.from(link: text), ref.kind == .session else { throw OrderPlanError.notASession(text) }
        return ref
    }

    static func planID(_ text: String) throws -> UUID {
        guard let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw OrderPlanError.notAPlan(text)
        }
        return id
    }

    // MARK: Forgetting

    /// Forgets an order an agent names, if it's at the revision the agent gives, when it gives one.
    @discardableResult
    public mutating func forget(plan text: String, revision: Int? = nil) throws -> OrderPlan {
        let id = try Self.planID(text)
        guard let index = plans.firstIndex(where: { $0.id == id }) else { throw OrderPlanError.noSuchPlan(id) }
        if let revision, revision != plans[index].revision {
            throw OrderPlanError.changed(since: revision, now: plans[index].revision)
        }
        return plans.remove(at: index)
    }

    /// Forget This Order.
    public mutating func forget(_ id: UUID) {
        plans.removeAll { $0.id == id }
    }

    /// Forgets the things of the sources you turned off, as each source forgets what it kept: their pull requests' places
    /// in every order, which goes up a revision, and the orders that are left with none; and Copilot's, which session told
    /// each order, which is only for information, so its revision stays.
    public mutating func forget(_ kinds: Set<ItemRef.Kind>) {
        plans = plans.compactMap { plan in
            var plan = plan
            if let session = plan.declaredBy, kinds.contains(session.kind) { plan.declaredBy = nil }
            guard plan.refs.contains(where: { kinds.contains($0.kind) }) else { return plan }
            plan.entries = plan.entries.filter { !kinds.contains($0.ref.kind) }.map { entry in
                var entry = entry
                entry.after.removeAll { kinds.contains($0.kind) }
                if case .after(let refs, let reason) = entry.review {
                    let left = refs.filter { !kinds.contains($0.kind) }
                    entry.review = left.isEmpty ? nil : .after(left, reason)
                }
                return entry
            }
            plan.revision += 1
            return plan.entries.isEmpty ? nil : plan
        }
    }

    /// When an order finished: when BriefBar saw the last of its pull requests merge or close, once it has seen every one
    /// of them do so; nil while any is open, or one BriefBar can't see.
    public static func finishedAt(_ plan: OrderPlan, evidence: OrderEvidence) -> Date? {
        var latest: Date?
        for ref in plan.refs {
            guard let record = evidence.records[ref] else { return nil }
            latest = max(latest ?? record.observedAt, record.observedAt)
        }
        return latest
    }

    /// Removes the orders that finished more than `finishedFor` ago, and says which. One that hasn't finished stays, however
    /// old: BriefBar never guesses that a pull request it can't see merged.
    @discardableResult
    public mutating func removeFinished(evidence: OrderEvidence, now: Date = Date()) -> [UUID] {
        let finished = plans.filter { plan in
            Self.finishedAt(plan, evidence: evidence).map { now.timeIntervalSince($0) > Self.finishedFor } ?? false
        }.map(\.id)
        plans.removeAll { finished.contains($0.id) }
        return finished
    }

    // MARK: Saving

    /// The orders that were saved, without what can't be read, such as what another program wrote.
    public static func load(from defaults: some SettingsStorage) -> DeclaredOrders {
        guard let data = defaults.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([OrderLossy<PlanRecord>].self, from: data)
        else { return DeclaredOrders() }
        var plans: [OrderPlan] = []
        for plan in records.compactMap({ $0.value?.plan }) where !plans.contains(where: { $0.id == plan.id }) {
            plans.append(plan)
        }
        return DeclaredOrders(plans: plans)
    }

    /// Saves them, as references, codes and dates. Two agents telling orders at the very same moment can lose one, as they
    /// can the pull requests they watch, since the preferences have no transactions; an order's revision keeps an agent
    /// from replacing a newer one than it read.
    public func save(to defaults: some SettingsStorage) {
        guard !plans.isEmpty else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(plans.map(PlanRecord.init)) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Forget All Orders: every order, what BriefBar saw become of their pull requests, the mission you focus on, your
    /// changes to missions, the names you gave missions, and the suggested splits you kept together.
    public static func forgetAll(in defaults: some SettingsStorage) {
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: OrderEvidence.defaultsKey)
        defaults.removeObject(forKey: OrderFocus.defaultsKey)
        defaults.removeObject(forKey: OrderChanges.defaultsKey)
        defaults.removeObject(forKey: MissionNames.defaultsKey)
        defaults.removeObject(forKey: KeptTogether.defaultsKey)
    }
}

/// An order as the preferences keep it.
private struct PlanRecord: Codable {
    var id: UUID
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
    var declaredBy: ItemRef?
    var entries: [EntryRecord]

    init(_ plan: OrderPlan) {
        id = plan.id
        revision = plan.revision
        createdAt = plan.createdAt
        updatedAt = plan.updatedAt
        declaredBy = plan.declaredBy
        entries = plan.entries.map { EntryRecord(pullRequest: $0.ref, after: $0.after, review: $0.review) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        revision = try container.decode(Int.self, forKey: .revision)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        declaredBy = try? container.decodeIfPresent(ItemRef.self, forKey: .declaredBy)
        entries = try container.decode([OrderLossy<EntryRecord>].self, forKey: .entries).compactMap(\.value)
    }

    /// The order it keeps, without what can't be in one, such as a pull request it names twice, or one it names that it
    /// doesn't list; nil when nothing's left, or when its order goes round in a circle, which only another program could
    /// have written.
    var plan: OrderPlan? {
        guard revision >= 1 else { return nil }
        var entries: [OrderPlan.Entry] = []
        for record in self.entries
        where record.pullRequest.kind.isPullRequest && !entries.contains(where: { $0.ref == record.pullRequest }) {
            entries.append(OrderPlan.Entry(ref: record.pullRequest, after: record.after, review: record.review))
        }
        let refs = Set(entries.map(\.ref))
        for index in entries.indices {
            let ref = entries[index].ref
            var after: [ItemRef] = []
            for earlier in entries[index].after where refs.contains(earlier) && earlier != ref && !after.contains(earlier) {
                after.append(earlier)
            }
            entries[index].after = after
            if case .after(let targets, let reason) = entries[index].review {
                let kept = targets.filter { refs.contains($0) && $0 != ref }
                entries[index].review = kept.isEmpty ? nil : .after(kept, reason)
            }
        }
        let before = Dictionary(entries.map { ($0.ref, $0.after) }, uniquingKeysWith: { first, _ in first })
        guard !entries.isEmpty, entries.count <= DeclaredOrders.mostPullRequests,
              OrderGraph.cycles(entries.map(\.ref), before: before).isEmpty
        else { return nil }
        return OrderPlan(
            id: id, revision: revision, createdAt: createdAt, updatedAt: updatedAt,
            declaredBy: declaredBy?.kind == .session ? declaredBy : nil, entries: entries
        )
    }
}

private struct EntryRecord: Codable {
    var pullRequest: ItemRef
    var after: [ItemRef]
    var review: ReviewTiming?

    init(pullRequest: ItemRef, after: [ItemRef], review: ReviewTiming?) {
        self.pullRequest = pullRequest
        self.after = after
        self.review = review
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pullRequest = try container.decode(ItemRef.self, forKey: .pullRequest)
        after = (try? container.decodeIfPresent([OrderLossy<ItemRef>].self, forKey: .after))?.compactMap(\.value) ?? []
        review = try? container.decodeIfPresent(ReviewTiming.self, forKey: .review)
    }
}

/// A value that decodes to nil instead of failing, so one odd record doesn't lose the rest.
private struct OrderLossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}

// MARK: - What BriefBar saw

/// What BriefBar saw become of pull requests: which merged, and which closed without merging, so that an order still knows
/// once no list shows them, as Azure DevOps' Done shows one for a day, and GitHub's list only open ones. Only what a source
/// showed counts: one that's gone from a list, an archived session or time passing says nothing of a pull request. Kept in
/// the preferences as references, outcomes and dates.
public struct OrderEvidence: Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case merged
        /// Closed without merging.
        case closed
    }

    /// Where BriefBar saw it.
    public enum Witness: String, Codable, Sendable {
        /// Its own source's list, such as Azure DevOps' Done.
        case list
        /// A GitHub stack it's in, as another of the stack's pull requests showed it.
        case gitHubStack
    }

    public struct Record: Equatable, Sendable {
        public var outcome: Outcome
        /// When BriefBar first saw it.
        public var observedAt: Date
        public var witness: Witness

        public init(outcome: Outcome, observedAt: Date, witness: Witness) {
            self.outcome = outcome
            self.observedAt = observedAt
            self.witness = witness
        }
    }

    public static let defaultsKey = "order.evidence"

    public private(set) var records: [ItemRef: Record]

    public init(records: [ItemRef: Record] = [:]) {
        self.records = records.filter { $0.key.kind.isPullRequest }
    }

    /// What a source shows of a pull request now: that it merged or closed is kept, from when BriefBar first saw it; open
    /// again, as an abandoned pull request that's reactivated, it's no longer closed. A merge is final. True when that
    /// changed what's kept.
    @discardableResult
    public mutating func observe(_ observation: OrderObservation, at date: Date = Date()) -> Bool {
        let ref = observation.ref
        guard ref.kind.isPullRequest else { return false }
        let kept = records[ref]?.outcome
        switch observation.state {
        case .merged:
            guard kept != .merged else { return false }
            records[ref] = Record(outcome: .merged, observedAt: date, witness: observation.witness)
        case .closed:
            guard kept == nil else { return false }
            records[ref] = Record(outcome: .closed, observedAt: date, witness: observation.witness)
        case .open, .draft:
            guard kept == .closed else { return false }
            records[ref] = nil
        }
        return true
    }

    /// Keeps only what it saw of these, such as the pull requests orders name. True when that forgot something.
    @discardableResult
    public mutating func keep(only refs: Set<ItemRef>) -> Bool {
        let count = records.count
        records = records.filter { refs.contains($0.key) }
        return records.count != count
    }

    /// Both, this one's record wherever both have one.
    public func merging(_ other: OrderEvidence) -> OrderEvidence {
        OrderEvidence(records: records.merging(other.records) { mine, _ in mine })
    }

    /// Forgets what it saw of the pull requests of the sources you turned off. True when that forgot something.
    @discardableResult
    public mutating func forget(_ kinds: Set<ItemRef.Kind>) -> Bool {
        let count = records.count
        records = records.filter { !kinds.contains($0.key.kind) }
        return records.count != count
    }

    private struct Saved: Codable {
        var pullRequest: ItemRef
        var outcome: Outcome
        var observedAt: Date
        var witness: Witness
    }

    /// What was saved, without what can't be read.
    public static func load(from defaults: some SettingsStorage) -> OrderEvidence {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode([OrderLossy<Saved>].self, from: data)
        else { return OrderEvidence() }
        var records: [ItemRef: Record] = [:]
        for record in saved.compactMap(\.value) where records[record.pullRequest] == nil {
            records[record.pullRequest] = Record(outcome: record.outcome, observedAt: record.observedAt, witness: record.witness)
        }
        return OrderEvidence(records: records)
    }

    public func save(to defaults: some SettingsStorage) {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        let saved = records.sorted { $0.key < $1.key }.map {
            Saved(pullRequest: $0.key, outcome: $0.value.outcome, observedAt: $0.value.observedAt, witness: $0.value.witness)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(saved) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - Focus

/// The mission you keep on top of the Pull Requests pages listed By Mission, kept in the preferences by its key.
public enum OrderFocus {
    public static let defaultsKey = "order.focus"

    public static func load(from defaults: some SettingsStorage) -> MissionKey? {
        defaults.string(forKey: defaultsKey).flatMap { MissionKey($0) }
    }

    public static func save(_ key: MissionKey?, to defaults: some SettingsStorage) {
        if let key {
            defaults.set(key.description, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    /// The pull request its key names, if any, for the evidence to keep while you focus on it: a chain's earliest.
    public static func ref(of key: MissionKey) -> ItemRef? {
        if case .chain(let ref) = key { return ref }
        return nil
    }

    /// The mission you focus on, while it can still be one: nil once it's a session's order that BriefBar no longer keeps, a
    /// mission of your own that no change of yours puts a pull request in anymore, or, with `kinds`, one of the things whose
    /// source you turned off: a GitHub stack, a chain of their pull requests, the pull requests opened under a Copilot
    /// session, or a story's.
    public static func kept(
        _ key: MissionKey?, in orders: DeclaredOrders, changes: OrderChanges = OrderChanges(), forgetting kinds: Set<ItemRef.Kind> = []
    ) -> MissionKey? {
        switch key {
        case nil: return nil
        case .plan(let id)?: return orders.plan(id) == nil ? nil : key
        case .mine(let id)?: return changes.ownMissions.contains(id) ? key : nil
        case let key?: return key.kinds.isDisjoint(with: kinds) ? key : nil
        }
    }
}

// MARK: - The setting

/// Pull Request Order, in Settings, which is off until you turn it on. Off, BriefBar reads and shows no order, and agents
/// don't get its tools; the orders sessions told it stay, until you forget them.
public enum PullRequestOrderSetting {
    public static let defaultsKey = "order.enabled"

    public static func isOn(in defaults: some SettingsStorage) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }
}

// MARK: - For agents

extension OrderText {
    /// An order as an agent told it, a line for each pull request, in the order they merge: what it merges after, or
    /// before, or that it can merge any time, and when to review it, as the agent said. Only what the agent said, with
    /// nothing from the sources, which an agent reads through their own tools.
    public static func lines(of plan: OrderPlan) -> [String] {
        let before = Dictionary(plan.entries.map { ($0.ref, $0.after) }, uniquingKeysWith: { first, _ in first })
        var dependents: [ItemRef: [ItemRef]] = [:]
        for entry in plan.entries {
            for earlier in entry.after { dependents[earlier, default: []].append(entry.ref) }
        }
        let place = Dictionary(plan.refs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let alone = Set(plan.refs.filter { before[$0, default: []].isEmpty && dependents[$0, default: []].isEmpty })
        let order = OrderGraph.ordered(plan.refs, before: before) { lhs, rhs in
            (alone.contains(lhs) ? 1 : 0, place[lhs] ?? 0) < (alone.contains(rhs) ? 1 : 0, place[rhs] ?? 0)
        }.order
        return order.compactMap { ref -> String? in
            guard let entry = plan.entry(for: ref) else { return nil }
            var line = "\(ref.fullOrderLabel): "
            if !entry.after.isEmpty {
                line += "merges after \(list(entry.after, near: ref))."
            } else if let later = dependents[ref], !later.isEmpty {
                line += "merges before \(list(later, near: ref))."
            } else {
                line += "any time."
            }
            switch entry.review {
            case nil: break
            case .now?: line += " Can be reviewed now."
            case let timing?: line += " \(review(timing, of: ref))."
            }
            return line
        }
    }
}
